"""Exports PP-OCRv5 mobile det + eslav rec to one fused ExecuTorch .pte (methods detect / recognize).

The contract follows react-native-executorch's createPaddleOcr (src/extensions/cv/tasks/paddleOcr.ts):
  detect:    f32[1,3,H,W]  RGB, ImageNet mean/std          -> f32[1,1,H,W] text probability
  recognize: f32[1,3,48,W] RGB, x/127.5 - 1, W = 8 * T      -> f32[1,T,C]  softmax, C = 1 + dict + space
plus a get_model_schema constant method with the dynamic ranges. PaddleOCR feeds BGR, and its
detector normalizes the B channel with the R mean (a known quirk), so the wrappers remap channels.

usage: python export_pte.py <models dir> <out dir> xnnpack|vulkan [--fp16] [--det-max 960] [--rec-max 3200]
  <models dir> as made by download-models.sh. Graph rewrites (ppocr_torch.py), --rewrite:
    on   both models; XNNPACK needs them to take the whole graph (default for xnnpack);
    rec  the recognizer only (default for vulkan): without it the Vulkan recognizer fails to load on
         Pixel 6a (executorch-android-vulkan 1.4.0), and with the rewritten detector Vulkan computes
         garbage. Even so Vulkan reads worse than the CPU there (fp32 loses up to 10 points, fp16 is garbage);
    off  the transformers graph as is.
  --rec-fixed W exports recognize with one static width (for debugging).
"""
import argparse
import json
import os
import time

import torch
from torch.export import Dim, export

from ppocr_torch import load_det, load_rec, channel_remap, xnnpack_friendly_det, xnnpack_friendly_rec

ap = argparse.ArgumentParser()
ap.add_argument("models")
ap.add_argument("out")
ap.add_argument("backend", choices=["xnnpack", "vulkan", "portable"])
ap.add_argument("--det-max", type=int, default=960)
ap.add_argument("--rec-min", type=int, default=320)
ap.add_argument("--rec-max", type=int, default=3200)
ap.add_argument("--fp16", action="store_true", help="Vulkan: run in fp16")
ap.add_argument("--name", default=None)
ap.add_argument("--rewrite", choices=["auto", "on", "rec", "off"], default="auto")
ap.add_argument("--rec-fixed", type=int, default=0, help="export recognize with this one static width (debugging)")
args = ap.parse_args()

IMNET_MEAN = torch.tensor([0.485, 0.456, 0.406])
IMNET_STD = torch.tensor([0.229, 0.224, 0.225])


class Detect(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        # RGB normalized as (c - mean[c]) / std[c]  ->  PaddleOCR input: BGR with mean/std in RGB order.
        # out channel c reads RGB channel 2 - c: raw = x * std[src] + mean[src]; out = (raw - mean[c]) / std[c]
        perm = (2, 1, 0)
        scale = [float(IMNET_STD[s] / IMNET_STD[c]) for c, s in enumerate(perm)]
        shift = [float((IMNET_MEAN[s] - IMNET_MEAN[c]) / IMNET_STD[c]) for c, s in enumerate(perm)]
        self.remap = channel_remap(scale, shift, perm)

    def forward(self, x):
        return self.m(self.remap(x)).last_hidden_state


class Recognize(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.remap = channel_remap([1.0, 1.0, 1.0], [0.0, 0.0, 0.0], (2, 1, 0))  # RGB -> BGR

    def forward(self, x):
        return self.m(self.remap(x)).last_hidden_state


det_m, rec_m = load_det(f"{args.models}/det"), load_rec(f"{args.models}/rec")
rewrite = args.rewrite if args.rewrite != "auto" else ("rec" if args.backend == "vulkan" else "on")
if rewrite == "on":
    det_m = xnnpack_friendly_det(det_m)
if rewrite != "off":
    rec_m = xnnpack_friendly_rec(rec_m)
print(f"graph rewrites: {rewrite}")
det = Detect(det_m).eval()
rec = Recognize(rec_m).eval()

dmax = args.det_max // 32
kh, kw = Dim("kh", min=1, max=dmax), Dim("kw", min=1, max=dmax)
kt = Dim("kt", min=args.rec_min // 8, max=args.rec_max // 8)

t0 = time.time()
with torch.no_grad():
    ep_det = export(det, (torch.randn(1, 3, 480, 640),), dynamic_shapes=({2: 32 * kh, 3: 32 * kw},), strict=False)
    if args.rec_fixed:
        ep_rec = export(rec, (torch.randn(1, 3, 48, args.rec_fixed),), strict=False)
    else:
        ep_rec = export(rec, (torch.randn(1, 3, 48, 800),), dynamic_shapes=({3: 8 * kt},), strict=False)
print(f"torch.export: {time.time() - t0:.1f} s")


def rng(lo, hi, step):
    return {"kind": "range", "range": {"min": lo, "max": hi, "step": step}}


def const(v):
    return {"kind": "constant", "value": v}


vocab = rec.m.config.head_out_channels
schema = {
    "detect": {
        "inputs": [{"kind": "Tensor", "dtype": "float32",
                    "shape": [const(1), const(3), rng(32, 32 * dmax, 32), rng(32, 32 * dmax, 32)]}],
        "outputs": [{"kind": "Tensor", "dtype": "float32",
                     "shape": [const(1), const(1), rng(32, 32 * dmax, 32), rng(32, 32 * dmax, 32)]}],
        # createPaddleOcr rejects constraints it does not declare itself.
        "runtimeConstraints": [],
    },
    "recognize": {
        "inputs": [{"kind": "Tensor", "dtype": "float32",
                    "shape": [const(1), const(3), const(48), rng(args.rec_min, args.rec_max, 8)]}],
        "outputs": [{"kind": "Tensor", "dtype": "float32",
                     "shape": [const(1), rng(args.rec_min // 8, args.rec_max // 8, 1), const(vocab)]}],
        "runtimeConstraints": [
            {"kind": "linear", "dimLhs": {"paramSide": "input", "tensorIdx": 0, "dimIdx": 3},
             "dimRhs": {"paramSide": "output", "tensorIdx": 0, "dimIdx": 1}, "coefficients": [8, 0]},
        ],
    },
}

from executorch.exir import to_edge_transform_and_lower, EdgeCompileConfig, ExecutorchBackendConfig

partitioners = []
if args.backend == "xnnpack":
    from executorch.backends.xnnpack.partition.xnnpack_partitioner import XnnpackPartitioner
    partitioners = [XnnpackPartitioner()]
elif args.backend == "vulkan":
    from executorch.backends.vulkan.partitioner.vulkan_partitioner import VulkanPartitioner
    partitioners = [VulkanPartitioner({"force_fp16": args.fp16})]

t0 = time.time()
edge = to_edge_transform_and_lower(
    {"detect": ep_det, "recognize": ep_rec},
    partitioner=partitioners,
    compile_config=EdgeCompileConfig(_check_ir_validity=False),
    constant_methods={"get_model_schema": json.dumps(schema)},
)
print(f"lowering: {time.time() - t0:.1f} s")

from executorch.devtools.backend_debug import get_delegation_info

for name in ("detect", "recognize"):
    info = get_delegation_info(edge.exported_program(name).graph_module)
    print(f"[{name}] delegated ops: {info.num_delegated_nodes}, not delegated: {info.num_non_delegated_nodes}, "
          f"delegate blobs: {info.num_delegated_subgraphs}")
    df = info.get_operator_delegation_dataframe()
    col = [c for c in df.columns if "non" in c.lower()][0]
    nd = df[df[col] > 0]
    if len(nd):
        print(nd.to_string(index=False))

prog = edge.to_executorch(ExecutorchBackendConfig(extract_delegate_segments=True))
os.makedirs(args.out, exist_ok=True)
name = args.name or f"ppocrv5_eslav_{args.backend}{'_fp16' if args.fp16 else ''}.pte"
path = os.path.join(args.out, name)
with open(path, "wb") as f:
    prog.write_to_file(f)
print(f"wrote {path}: {os.path.getsize(path) / 1e6:.2f} MB")

# createPaddleOcr's charset: charset[i] labels logit i + 1 (logit 0 is the CTC blank).
chars = json.load(open(f"{args.models}/rec/preprocessor_config.json", encoding="utf-8"))["character_list"][1:]
assert len(chars) + 1 == vocab, (len(chars), vocab)
with open(os.path.join(args.out, "charset_eslav.json"), "w", encoding="utf-8") as f:
    json.dump(chars, f, ensure_ascii=False)
