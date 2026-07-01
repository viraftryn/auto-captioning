# Models

This folder is bundled into the app as a **folder reference** (its contents are
copied verbatim into `LiveCaption.app/Contents/Resources/Models/`).

`SepFormer.mlpackage` goes here — produced by **`tools/sepformer/convert_sepformer.py`**.
It is **gitignored** (tens of MB), so each machine generates it once:

```bash
cd tools/sepformer
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python convert_sepformer.py     # writes ../../LiveCaption/Models/SepFormer.mlpackage
python verify_coreml.py         # confirm CoreML matches PyTorch
```

`SepFormerSeparator.swift` compiles the `.mlpackage` at runtime (cached in
Application Support), so the app builds and runs without it — it just shows a
"model isn't bundled yet" notice in the Analyze-File separated panel until you
run the script above.

If you'd rather commit the model so teammates don't each regenerate it, install
git-lfs (`brew install git-lfs && git lfs install`), then
`git lfs track "LiveCaption/Models/SepFormer.mlpackage/**"` and remove the
gitignore entry.
