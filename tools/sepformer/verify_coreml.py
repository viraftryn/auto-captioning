#!/usr/bin/env python3
"""Verify the converted CoreML SepFormer matches the PyTorch model.

Two checks:

1. CONVERSION PARITY (always, self-contained): feed identical input to both the
   CoreML model and SpeechBrain's `separate_batch`, and compare outputs. This is
   THE test that conversion didn't break the model. fp16 introduces some error;
   we expect SI-SNR(pytorch, coreml) high (>~25 dB) and small max-abs diff. If it
   is poor, re-run convert_sepformer.py with --precision fp32.

2. SEPARATION QUALITY (optional, needs two clean speech wavs): pass --s1 a.wav
   --s2 b.wav. We mix them, separate, and report permutation-invariant SI-SNRi
   (improvement over the mixture). Confirms the model actually separates real
   speech, not just that the conversion is faithful.

Run:  python verify_coreml.py
      python verify_coreml.py --s1 spk1.wav --s2 spk2.wav
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import torch

try:
    from speechbrain.inference.separation import SepformerSeparation
except ImportError:
    from speechbrain.pretrained import SepformerSeparation

import coremltools as ct

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MODEL = REPO_ROOT / "LiveCaption" / "Models" / "SepFormer.mlpackage"
SR = 16000


def si_snr(est: np.ndarray, ref: np.ndarray, eps: float = 1e-8) -> float:
    """Scale-invariant SNR (dB) of estimate vs reference."""
    est = est - est.mean()
    ref = ref - ref.mean()
    alpha = (est * ref).sum() / ((ref ** 2).sum() + eps)
    target = alpha * ref
    noise = est - target
    return float(10 * np.log10(((target ** 2).sum() + eps) / ((noise ** 2).sum() + eps)))


def load_wav(path: str, length: int) -> np.ndarray:
    import soundfile as sf
    x, sr = sf.read(path, dtype="float32")
    if x.ndim > 1:
        x = x.mean(axis=1)
    if sr != SR:
        sys.exit(f"{path}: expected {SR} Hz, got {sr} Hz (resample it first)")
    if len(x) < length:
        x = np.pad(x, (0, length - len(x)))
    return x[:length]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=str(DEFAULT_MODEL))
    ap.add_argument("--source", default="speechbrain/sepformer-whamr16k")
    ap.add_argument("--s1", help="optional clean speaker-1 wav (16 kHz)")
    ap.add_argument("--s2", help="optional clean speaker-2 wav (16 kHz)")
    args = ap.parse_args()

    if not Path(args.model).exists():
        sys.exit(f"Model not found: {args.model}\nRun convert_sepformer.py first.")

    print(f"• Loading CoreML model {args.model}…")
    mlmodel = ct.models.MLModel(args.model)
    # Recover the baked-in window length from the input spec.
    spec_in = mlmodel.get_spec().description.input[0]
    t = int(spec_in.type.multiArrayType.shape[-1])
    out_name = mlmodel.get_spec().description.output[0].name
    print(f"  window_length T = {t}  output='{out_name}'")

    print(f"• Loading PyTorch reference {args.source}…")
    pt = SepformerSeparation.from_hparams(
        source=args.source,
        savedir=str(Path.home() / ".cache" / "sepformer-whamr16k"),
        run_opts={"device": "cpu"},
    )
    pt.eval()

    # Build the input mixture.
    if args.s1 and args.s2:
        s1 = load_wav(args.s1, t)
        s2 = load_wav(args.s2, t)
        mix = s1 + s2
        peak = np.max(np.abs(mix)) + 1e-8
        mix = (mix / peak).astype("float32")  # avoid clipping; sources scale too
        s1, s2 = s1 / peak, s2 / peak
        refs = [s1, s2]
    else:
        print("  (no --s1/--s2 given → parity check only, on a fixed synthetic mixture)")
        rng = np.random.default_rng(0)
        n = np.arange(t)
        # two pseudo-voices: AM-modulated harmonic stacks at distinct F0s + noise
        voice = lambda f0, am: (
            sum(np.sin(2 * np.pi * k * f0 * n / SR) / k for k in range(1, 8))
            * (0.6 + 0.4 * np.sin(2 * np.pi * am * n / SR))
        )
        mix = (0.5 * voice(130, 3.1) + 0.5 * voice(210, 2.3)
               + 0.01 * rng.standard_normal(t)).astype("float32")
        mix /= np.max(np.abs(mix)) + 1e-8
        refs = None

    x = mix[None, :].astype("float32")  # [1, T]

    # CoreML prediction.
    cm_out = mlmodel.predict({"mix": x})[out_name]
    cm = np.asarray(cm_out).reshape(t, -1)          # [T, 2]

    # PyTorch reference.
    with torch.no_grad():
        pt_out = pt.separate_batch(torch.from_numpy(x)).cpu().numpy()
    ptn = pt_out.reshape(t, -1)                      # [T, 2]

    # --- Check 1: conversion parity ---
    print("\n── Conversion parity (CoreML vs PyTorch, same input) ──")
    max_diff = float(np.max(np.abs(cm - ptn)))
    par = [si_snr(cm[:, i], ptn[:, i]) for i in range(cm.shape[1])]
    print(f"  max abs diff : {max_diff:.4e}")
    for i, p in enumerate(par):
        print(f"  source {i}    : SI-SNR(coreml vs pytorch) = {p:6.2f} dB")
    ok = min(par) > 25.0
    print(f"  → parity {'OK' if ok else 'POOR — try --precision fp32 in convert'} "
          f"(threshold 25 dB)")

    # --- Check 2: separation quality (optional) ---
    if refs is not None:
        print("\n── Separation quality (SI-SNRi vs clean references) ──")

        def best_si_snri(est2):  # permutation-invariant improvement over mixture
            base = [si_snr(mix, r) for r in refs]
            perms = [(0, 1), (1, 0)]
            scored = []
            for a, b in perms:
                imp = ((si_snr(est2[:, a], refs[0]) - base[0])
                       + (si_snr(est2[:, b], refs[1]) - base[1])) / 2
                scored.append(imp)
            return max(scored)

        print(f"  CoreML  SI-SNRi : {best_si_snri(cm):6.2f} dB")
        print(f"  PyTorch SI-SNRi : {best_si_snri(ptn):6.2f} dB")

    print()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
