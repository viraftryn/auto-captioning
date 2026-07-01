# SepFormer → CoreML conversion

Converts the pretrained **`speechbrain/sepformer-whamr16k`** (2-speaker, 16 kHz,
noise + reverberation robust) into a CoreML `.mlpackage` that the LiveCaption app
loads for on-device speaker separation, replacing the old harmonic comb mask.

This runs **once on your machine** (the macOS app just consumes the artifact).
It needs a heavy Python stack (torch + speechbrain + coremltools) that is *not*
part of the app, so keep it in a throwaway venv.

## Setup

```bash
cd tools/sepformer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 1. Convert

```bash
python convert_sepformer.py
```

- Downloads the checkpoint on first run (cached in `~/.cache/sepformer-whamr16k`).
- Traces at a **fixed** `T = 64000`-sample (4.0 s) window and converts to an
  fp16 CoreML mlprogram.
- Writes **`../../LiveCaption/Models/SepFormer.mlpackage`** (the app bundles this).

Model I/O contract (must stay in sync with `SepFormerSeparator.swift`):

| name      | shape        | dtype   | meaning                          |
|-----------|--------------|---------|----------------------------------|
| `mix`     | `[1, 64000]` | float32 | mono 16 kHz waveform window      |
| `sources` | `[1, 64000, 2]` | float32 | 2 separated waveforms (arbitrary order) |

Options: `--length` (window samples, ÷8), `--precision fp16|fp32`, `--source`,
`--output`.

## 2. Verify

```bash
python verify_coreml.py                      # conversion parity (self-contained)
python verify_coreml.py --s1 a.wav --s2 b.wav  # + separation quality (16 kHz wavs)
```

- **Parity** feeds identical input to CoreML and PyTorch `separate_batch` and
  reports SI-SNR between them. Expect **> 25 dB** (fp16). If it's poor, re-run
  the convert step with `--precision fp32`.
- **Quality** (optional) mixes two clean speaker wavs and reports
  permutation-invariant **SI-SNRi**; confirms it actually separates real speech.

## Troubleshooting the conversion

`coremltools.convert` can choke on specific ops in a transformer. In rough order
of what to try:

1. **torch version** — coremltools lags the newest torch. If you see
   "Torch version X not supported", pin torch/torchaudio to a version the
   installed coremltools supports (see `requirements.txt`) and reinstall.
2. **fp32 first** — `--precision fp32` isolates *op-support* failures from
   *numeric* (fp16) failures.
3. **Dual-path reshape** — if an `unfold`/segmentation op fails to convert, the
   fix is to reimplement the masknet's chunk/overlap-add with static
   `reshape`/`permute` in `SepFormerWrapper` (shapes are constant at fixed `T`).
4. **Split the graph** — worst case, convert encoder / masknet / decoder as three
   separate `.mlpackage`s and chain them in Swift.

The Swift side (`SepFormerSeparator.swift`) loads the `.mlpackage` by compiling
it at runtime, so the app builds and runs (with a "model missing" notice) even
before you've produced the artifact here.
