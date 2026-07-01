#!/usr/bin/env python3
"""Convert speechbrain/sepformer-whamr16k (2-speaker, 16 kHz) to a CoreML
.mlpackage for on-device inference in LiveCaption.

Why a FIXED input length:
  SepFormer is a dual-path transformer. A 55 s clip can't go through it in one
  pass, and CoreML's flexible/enumerated shapes are fragile for transformers.
  So we trace at a single fixed window length T (default 64000 = 4.0 s @ 16 kHz)
  and the Swift side feeds the model overlapping T-length windows. T is BAKED
  INTO the traced graph -- the Swift windower must use the identical T (it reads
  it from the model's input shape, but keep them in sync if you change it here).

The wrapper module below mirrors SpeechBrain's `Separator.separate_batch`
(encoder -> masknet -> decoder) exactly, so verify_coreml.py can assert the
CoreML output matches the canonical PyTorch path.

Output: <repo>/LiveCaption/Models/SepFormer.mlpackage
  Input  "mix"     : float32 [1, T]      mono 16 kHz waveform
  Output "sources" : float32 [1, T, 2]   the 2 separated waveforms (arbitrary order)

Run:  python convert_sepformer.py            # defaults: T=64000, fp16
      python convert_sepformer.py --length 48000 --precision fp32
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# SpeechBrain moved the pretrained interfaces in 1.0; support both layouts.
try:
    from speechbrain.inference.separation import SepformerSeparation
except ImportError:  # speechbrain < 1.0
    from speechbrain.pretrained import SepformerSeparation


# Repo root = two levels up from tools/sepformer/.
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO_ROOT / "LiveCaption" / "Models" / "SepFormer.mlpackage"


class SepFormerWrapper(nn.Module):
    """A single traceable module reproducing `Separator.separate_batch`."""

    def __init__(self, mods, num_spks: int):
        super().__init__()
        self.encoder = mods.encoder
        self.masknet = mods.masknet
        self.decoder = mods.decoder
        self.num_spks = num_spks

    def forward(self, mix: torch.Tensor) -> torch.Tensor:  # mix: [1, T]
        mix_w = self.encoder(mix)                       # [B, N, L]
        est_mask = self.masknet(mix_w)                  # [num_spks, B, N, L]
        mix_w = torch.stack([mix_w] * self.num_spks)    # [num_spks, B, N, L]
        sep_h = mix_w * est_mask
        est_source = torch.cat(
            [self.decoder(sep_h[i]).unsqueeze(-1) for i in range(self.num_spks)],
            dim=-1,
        )                                               # [B, T_est, num_spks]
        # encoder/decoder conv strides can shift T by a few samples; match input.
        t_origin = mix.size(1)
        t_est = est_source.size(1)
        if t_origin > t_est:
            est_source = F.pad(est_source, (0, 0, 0, t_origin - t_est))
        else:
            est_source = est_source[:, :t_origin, :]
        return est_source                               # [1, T, num_spks]


def _patch_dual_path():
    """Monkey-patch SpeechBrain's Dual_Path_Model._padding to avoid the
    ``torch.Tensor(torch.zeros(...))`` pattern, which emits an ``alias`` op
    that coremltools cannot convert. Replacing it with plain ``torch.zeros``
    (with explicit dtype/device) produces identical numerics and traces cleanly.
    """
    from speechbrain.lobes.models.dual_path import Dual_Path_Model

    def _padding_patched(self, input, K):
        B, N, L = input.shape
        P = K // 2
        gap = K - (P + L % K) % K
        if gap > 0:
            pad = torch.zeros(B, N, gap, dtype=input.dtype, device=input.device)
            input = torch.cat([input, pad], dim=2)
        _pad = torch.zeros(B, N, P, dtype=input.dtype, device=input.device)
        input = torch.cat([_pad, input, _pad], dim=2)
        return input, gap

    Dual_Path_Model._padding = _padding_patched


def load_model(source: str):
    print(f"• Loading {source} (first run downloads the checkpoint)…")
    model = SepformerSeparation.from_hparams(
        source=source,
        savedir=str(Path.home() / ".cache" / "sepformer-whamr16k"),
        run_opts={"device": "cpu"},
    )
    model.eval()
    num_spks = int(model.hparams.num_spks)
    if num_spks != 2:
        print(f"  ! expected a 2-speaker model, got num_spks={num_spks}", file=sys.stderr)
    return model, num_spks


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default="speechbrain/sepformer-whamr16k",
                    help="HuggingFace model id (default: %(default)s)")
    ap.add_argument("--length", type=int, default=64000,
                    help="fixed window length T in samples @16kHz (default: %(default)s = 4.0s)")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16",
                    help="CoreML compute precision (default: %(default)s; fall back to fp32 "
                         "if verify_coreml.py shows poor parity)")
    ap.add_argument("--output", default=str(DEFAULT_OUT),
                    help="output .mlpackage path (default: <repo>/LiveCaption/Models/SepFormer.mlpackage)")
    args = ap.parse_args()

    import coremltools as ct  # imported late so --help works without it installed

    t = args.length
    if t % 8 != 0:
        ap.error(f"--length must be divisible by the encoder stride (8); {t} is not")

    model, num_spks = load_model(args.source)
    _patch_dual_path()
    wrapper = SepFormerWrapper(model.mods, num_spks).eval()

    print(f"• Tracing at fixed input [1, {t}] ({t/16000:.2f}s @ 16 kHz)…")
    example = torch.randn(1, t)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
        # Sanity-check the traced graph still produces the right shape.
        out = traced(example)
    assert out.shape == (1, t, num_spks), f"unexpected traced output shape {tuple(out.shape)}"
    print(f"  traced OK → output {tuple(out.shape)}")

    precision = ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
    print(f"• Converting to CoreML mlprogram ({args.precision}, compute_units=ALL)…")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=(1, t), dtype=np.float32)],
        outputs=[ct.TensorType(name="sources", dtype=np.float32)],
        compute_precision=precision,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = (
        "SepFormer (speechbrain/sepformer-whamr16k) 2-speaker separation, 16 kHz, "
        f"fixed {t}-sample window. mix[1,{t}] -> sources[1,{t},2]."
    )
    mlmodel.user_defined_metadata["window_length"] = str(t)
    mlmodel.user_defined_metadata["sample_rate"] = "16000"
    mlmodel.user_defined_metadata["num_speakers"] = str(num_spks)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    print(f"\n✓ Saved {out_path}")
    print(f"  window_length T = {t}  (the Swift windower MUST use this exact value)")
    print("  Next: python verify_coreml.py  to confirm CoreML matches PyTorch.")


if __name__ == "__main__":
    main()
