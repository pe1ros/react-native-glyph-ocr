"""Runs a fused .pte (detect/recognize) through the ExecuTorch Python runtime and compares it with ONNX.

usage: python parity_pte.py <models dir> <model.pte> <photo> [<photo> ...]
"""
import sys
import time

import numpy as np
import onnxruntime as ort
import torch
from PIL import Image
from executorch.runtime import Runtime

MODELS, PTE, PHOTOS = sys.argv[1], sys.argv[2], sys.argv[3:]

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def det_inputs(img, side=960):
    w, h = img.size
    r = min(1, side / max(w, h))
    dw, dh = max(32, round(w * r / 32) * 32), max(32, round(h * r / 32) * 32)
    a = np.asarray(img.resize((dw, dh), Image.BILINEAR), np.float32) / 255.0
    rgb = (a - MEAN) / STD  # ExecuTorch contract: RGB, ImageNet
    bgr = (a[:, :, ::-1] - MEAN) / STD  # PaddleOCR: BGR with the RGB-order mean
    f = lambda x: np.ascontiguousarray(x.transpose(2, 0, 1)[None])
    return f(rgb), f(bgr)


def rec_inputs(img, n=8, seed=0):
    a = np.asarray(img, np.float32) / 255.0
    h, w, _ = a.shape
    rng = np.random.default_rng(seed)
    for _ in range(n):
        y = int(rng.integers(0, max(1, h - 60)))
        strip = Image.fromarray((a[y:y + 50] * 255).astype(np.uint8))
        W = int(rng.integers(40, 400)) * 8
        s = np.asarray(strip.resize((W, 48), Image.BILINEAR), np.float32) / 255.0
        s = (s - 0.5) / 0.5
        yield (np.ascontiguousarray(s.transpose(2, 0, 1)[None]),
               np.ascontiguousarray(s[:, :, ::-1].transpose(2, 0, 1)[None]))


det_onnx = ort.InferenceSession(f"{MODELS}/onnx/det.onnx")
rec_onnx = ort.InferenceSession(f"{MODELS}/onnx/rec.onnx")
rt = Runtime.get()
prog = rt.load_program(PTE)
print("methods:", sorted(prog.method_names))
detect = prog.load_method("detect")
recognize = prog.load_method("recognize")

t_det = {"pte": 0.0, "onnx": 0.0}
t_rec = {"pte": 0.0, "onnx": 0.0}
worst_det = worst_rec = 0.0
mism = agree = total = 0
for path in PHOTOS:
    img = Image.open(path).convert("RGB")
    x_rgb, x_bgr = det_inputs(img)
    t0 = time.perf_counter()
    got = detect.execute([torch.from_numpy(x_rgb)])[0].numpy()
    t1 = time.perf_counter()
    ref = det_onnx.run(None, {"x": x_bgr})[0]
    t2 = time.perf_counter()
    t_det["pte"] += t1 - t0
    t_det["onnx"] += t2 - t1
    worst_det = max(worst_det, float(np.abs(got - ref).max()))
    mism += int(((got > 0.3) != (ref > 0.3)).sum())
    for r_rgb, r_bgr in rec_inputs(img):
        t0 = time.perf_counter()
        got = recognize.execute([torch.from_numpy(r_rgb)])[0].numpy()
        t1 = time.perf_counter()
        ref = rec_onnx.run(None, {"x": r_bgr})[0]
        t2 = time.perf_counter()
        t_rec["pte"] += t1 - t0
        t_rec["onnx"] += t2 - t1
        assert got.shape == ref.shape, (got.shape, ref.shape)
        worst_rec = max(worst_rec, float(np.abs(got - ref).max()))
        agree += int((got.argmax(-1) == ref.argmax(-1)).sum())
        total += got.shape[1]
print(f"{len(PHOTOS)} photos. detect: max|d| {worst_det:.2e}, binarized pixels that differ {mism}; "
      f"time pte {t_det['pte'] * 1000:.0f} ms vs onnx {t_det['onnx'] * 1000:.0f} ms")
print(f"recognize: max|d| {worst_rec:.2e}, argmax agree {agree}/{total}; "
      f"time pte {t_rec['pte'] * 1000:.0f} ms vs onnx {t_rec['onnx'] * 1000:.0f} ms")
