"""PP-OCRv5 mobile det + eslav rec in PyTorch (transformers), reparameterized for inference.

The safetensors checkpoints keep PP-LCNetV3's training-time branches (several kxk convs, a 1x1 conv
and an identity BN per RepLayer). The official ONNX exports have them fused; we fuse them the same
way so that the exported graph matches the ONNX one in size and compute.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F
from transformers import AutoModelForObjectDetection, AutoConfig
from transformers.models.pp_lcnet_v3 import modeling_pp_lcnet_v3 as lc
from transformers.models.pp_ocrv5_mobile_rec.modeling_pp_ocrv5_mobile_rec import (
    PPOCRV5MobileRecForTextRecognition,
)


def _bn_fold(bn: nn.BatchNorm2d):
    std = (bn.running_var + bn.eps).sqrt()
    t = bn.weight / std
    return t, bn.bias - bn.running_mean * t


def _conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d, k: int):
    """Kernel and bias of conv+bn, the kernel zero-padded to k x k."""
    t, b = _bn_fold(bn)
    w = conv.weight * t.reshape(-1, 1, 1, 1)
    if conv.bias is not None:
        b = b + conv.bias * t
    pad = (k - w.shape[-1]) // 2
    if pad:
        w = F.pad(w, [pad, pad, pad, pad])
    return w, b


class FusedRepLayer(nn.Module):
    def __init__(self, rep: "lc.PPLCNetV3LearnableRepLayer"):
        super().__init__()
        k = rep.kernel_size
        groups = rep.groups
        cin, cout = rep.in_channels, rep.out_channels
        w = torch.zeros(cout, cin // groups, k, k)
        b = torch.zeros(cout)
        for conv in rep.conv_symmetric:
            wi, bi = _conv_bn(conv.convolution, conv.normalization, k)
            w, b = w + wi, b + bi
        if rep.conv_small_symmetric is not None:
            wi, bi = _conv_bn(rep.conv_small_symmetric.convolution, rep.conv_small_symmetric.normalization, k)
            w, b = w + wi, b + bi
        if rep.identity is not None:
            ident = torch.zeros(cout, cin // groups, k, k)
            for i in range(cout):
                ident[i, i % (cin // groups), k // 2, k // 2] = 1.0
            t, bi = _bn_fold(rep.identity)
            w = w + ident * t.reshape(-1, 1, 1, 1)
            b = b + bi
        # Learnable affine block after the sum: scale * x + bias.
        s = rep.lab.scale.reshape(())
        w = w * s
        b = b * s + rep.lab.bias.reshape(())
        self.conv = nn.Conv2d(cin, cout, k, stride=rep.stride, padding=rep.padding, groups=groups, bias=True)
        with torch.no_grad():
            self.conv.weight.copy_(w)
            self.conv.bias.copy_(b)
        self.act = rep.act if rep.stride != 2 else None

    def forward(self, x):
        x = self.conv(x)
        return self.act(x) if self.act is not None else x


def _fold_conv_bn_pairs(model: nn.Module):
    """Folds every module that holds (conv, bn) attributes used as conv -> bn into one conv."""
    for mod in model.modules():
        for conv_name, bn_name in (("convolution", "normalization"), ("convolution", "norm")):
            conv = getattr(mod, conv_name, None)
            bn = getattr(mod, bn_name, None)
            if isinstance(conv, nn.Conv2d) and isinstance(bn, nn.BatchNorm2d):
                k = conv.weight.shape[-1]
                with torch.no_grad():
                    t, b = _bn_fold(bn)
                    conv.weight.mul_(t.reshape(-1, 1, 1, 1))
                    if conv.bias is None:
                        conv.bias = nn.Parameter(b.clone())
                    else:
                        conv.bias.copy_(conv.bias * t + b)
                setattr(mod, bn_name, nn.Identity())
            elif isinstance(conv, nn.ConvTranspose2d) and isinstance(bn, nn.BatchNorm2d):
                with torch.no_grad():
                    t, b = _bn_fold(bn)
                    # ConvTranspose2d weight: [in, out, kh, kw]
                    conv.weight.mul_(t.reshape(1, -1, 1, 1))
                    if conv.bias is None:
                        conv.bias = nn.Parameter(b.clone())
                    else:
                        conv.bias.copy_(conv.bias * t + b)
                setattr(mod, bn_name, nn.Identity())


def reparameterize(model: nn.Module) -> nn.Module:
    for name, mod in list(model.named_modules()):
        for child_name, child in list(mod.named_children()):
            if isinstance(child, lc.PPLCNetV3LearnableRepLayer):
                setattr(mod, child_name, FusedRepLayer(child))
    _fold_conv_bn_pairs(model)
    return model


def load_det(path: str, fuse: bool = True) -> nn.Module:
    m = AutoModelForObjectDetection.from_pretrained(path).eval()
    return reparameterize(m) if fuse else m


def load_rec(path: str, fuse: bool = True) -> nn.Module:
    m = PPOCRV5MobileRecForTextRecognition.from_pretrained(path, attn_implementation="eager").eval()
    return reparameterize(m) if fuse else m


class Det(nn.Module):
    """[1,3,H,W] normalized like PaddleOCR (BGR) -> [1,1,H,W] text probability."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        return self.m(x).last_hidden_state


class Rec(nn.Module):
    """[1,3,48,W] normalized like PaddleOCR (BGR) -> [1,T,C] softmax probabilities."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        return self.m(x).last_hidden_state


# --- Rewrites that keep the math but let XNNPACK take the whole graph -----------------------------
# ExecuTorch 1.4's XNNPACK partitioner leaves on the portable CPU kernels: nearest upsampling,
# layer_norm, avg_pool2d with count_include_pad=True, select_copy and reshapes with symbolic sizes.
# Every such op splits the graph into more delegate calls with layout copies in between.
import types


class NearestUp(nn.Module):
    """Nearest upsampling by an integer factor as a depthwise transposed conv with a ones kernel."""

    def __init__(self, channels: int, s: int):
        super().__init__()
        self.conv = nn.ConvTranspose2d(channels, channels, s, stride=s, groups=channels, bias=False)
        with torch.no_grad():
            self.conv.weight.fill_(1.0)

    def forward(self, x):
        return self.conv(x)


class RowLayerNorm(nn.Module):
    """LayerNorm over the last dim of [1, T, C] with means taken by a linear layer."""

    def __init__(self, ln: nn.LayerNorm):
        super().__init__()
        c = ln.normalized_shape[0]
        self.eps = ln.eps
        self.mean = nn.Linear(c, 1, bias=False)
        with torch.no_grad():
            self.mean.weight.fill_(1.0 / c)
        self.weight = nn.Parameter(ln.weight.detach().clone())
        self.bias = nn.Parameter(ln.bias.detach().clone())

    def forward(self, x):
        d = x - self.mean(x)
        var = self.mean(d * d)
        return d * torch.rsqrt(var + self.eps) * self.weight + self.bias


class SplitQkvAttention(nn.Module):
    def __init__(self, attn):
        super().__init__()
        e, h = attn.embed_dim, attn.num_heads
        self.h, self.d, self.scale = h, e // h, attn.scale
        self.q, self.k, self.v = (nn.Linear(e, e) for _ in range(3))
        with torch.no_grad():
            for i, lin in enumerate((self.q, self.k, self.v)):
                lin.weight.copy_(attn.qkv.weight[i * e:(i + 1) * e])
                lin.bias.copy_(attn.qkv.bias[i * e:(i + 1) * e])
        self.projection = attn.projection

    def forward(self, hidden_states, attention_mask=None, **kwargs):
        # [1, T, E] -> [H, T, D]; batch is always 1 here.
        def heads(x):
            return x.reshape(-1, self.h, self.d).permute(1, 0, 2)

        q, k, v = heads(self.q(hidden_states) * self.scale), heads(self.k(hidden_states)), heads(self.v(hidden_states))
        w = torch.softmax(torch.bmm(q, k.permute(0, 2, 1)), dim=-1)
        out = torch.bmm(w, v).permute(1, 0, 2).contiguous().view(1, -1, self.h * self.d)
        return self.projection(out), None


def _svtr_forward(self, hidden_states, **kwargs):
    from transformers.modeling_outputs import BaseModelOutputWithNoAttention
    residual = hidden_states
    hidden_states = self.conv_block[0](hidden_states)
    hidden_states = self.conv_block[1](hidden_states)
    channels = hidden_states.shape[1]
    # [1, C, 1, W] -> [1, W, C]
    hidden_states = hidden_states.reshape(1, channels, -1).permute(0, 2, 1)
    for block in self.svtr_block:
        hidden_states = block(hidden_states)
    hidden_states = self.norm(hidden_states)
    hidden_states = hidden_states.permute(0, 2, 1).reshape(1, channels, 1, -1)
    hidden_states = self.conv_block[2](hidden_states)
    hidden_states = self.conv_block[3](torch.cat((residual, hidden_states), dim=1))
    hidden_states = self.conv_block[4](hidden_states)
    hidden_states = hidden_states.reshape(1, hidden_states.shape[1], -1).permute(0, 2, 1)
    return BaseModelOutputWithNoAttention(last_hidden_state=hidden_states)


def _rec_model_forward(self, pixel_values, **kwargs):
    from transformers.modeling_outputs import BaseModelOutputWithNoAttention
    hidden_state = self.backbone(pixel_values).feature_maps[-1]
    # Same as F.avg_pool2d(x, (3, 2)): no padding, so count_include_pad does not change the result.
    hidden_state = F.avg_pool2d(hidden_state, (3, 2), stride=(3, 2), padding=0, count_include_pad=False)
    return BaseModelOutputWithNoAttention(last_hidden_state=hidden_state)


def _det_neck_forward(self, feature_maps):
    fused = [conv(f) for conv, f in zip(self.insert_conv, feature_maps)]
    for i in range(2, -1, -1):
        fused[i] = fused[i] + self.up_fused(fused[i + 1])
    features = [conv(f) for conv, f in zip(self.input_conv, fused)]
    processed = [features[0], self.up2(features[1]), self.up4(features[2]), self.up8(features[3])]
    return torch.cat(processed[::-1], dim=1)


def xnnpack_friendly_det(m):
    neck = m.model.neck
    c = m.config.neck_out_channels
    neck.up_fused = NearestUp(c, 2)
    neck.up2, neck.up4, neck.up8 = NearestUp(c // 4, 2), NearestUp(c // 4, 4), NearestUp(c // 4, 8)
    neck.forward = types.MethodType(_det_neck_forward, neck)
    return m


def xnnpack_friendly_rec(m):
    m.model.forward = types.MethodType(_rec_model_forward, m.model)
    enc = m.head.encoder
    enc.forward = types.MethodType(_svtr_forward, enc)
    enc.norm = RowLayerNorm(enc.norm)
    for block in enc.svtr_block:
        block.self_attn = SplitQkvAttention(block.self_attn)
        block.layer_norm1 = RowLayerNorm(block.layer_norm1)
        block.layer_norm2 = RowLayerNorm(block.layer_norm2)
    return m


def channel_remap(scale, shift, perm):
    """1x1 conv: out[c] = x[perm[c]] * scale[c] + shift[c]."""
    conv = nn.Conv2d(3, 3, 1, bias=True)
    with torch.no_grad():
        conv.weight.zero_()
        for c, src in enumerate(perm):
            conv.weight[c, src, 0, 0] = scale[c]
        conv.bias.copy_(torch.as_tensor(shift, dtype=torch.float32))
    return conv
