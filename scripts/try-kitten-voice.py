"""Audition KittenTTS Nano v0.8 INT8 on macOS with downloaded model files.

Run using the Python environment containing KittenML's kittentts 0.8.1 wheel.
From the repo root, set up the Mac trial once while online:
    python3.11 -m venv .build/kitten-trial/venv
    source .build/kitten-trial/venv/bin/activate
    pip install https://github.com/KittenML/KittenTTS/releases/download/0.8.1/kittentts-0.8.1-py3-none-any.whl
    hf download KittenML/kitten-tts-nano-0.8-int8 config.json voices.npz kitten_tts_nano_v0_8.onnx \
        --revision 84781d74e29ee25217551556398b42f80593a813 --local-dir .build/kitten-trial

Then run offline:
    .build/kitten-trial/venv/bin/python scripts/try-kitten-voice.py
"""
import argparse
import json
import resource
import time
from pathlib import Path

SAMPLE = "Your household plan calls for nine gallons of water."
TRIAL = Path(__file__).resolve().parents[1] / ".build" / "kitten-trial"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--text", default=SAMPLE)
    parser.add_argument("--voices", nargs="+", default=["Bella", "Jasper"])
    parser.add_argument("--model-dir", type=Path, default=TRIAL)
    parser.add_argument("--output", type=Path, default=TRIAL / "samples")
    args = parser.parse_args()
    config = json.loads((args.model_dir / "config.json").read_text())
    for voice in args.voices:
        if voice not in config["voice_aliases"]:
            parser.error(f"Unknown voice {voice!r}. Choose from {', '.join(config['voice_aliases'])}.")
    if not args.text.strip():
        parser.error("Supply a sentence to read.")

    import onnxruntime
    import soundfile as sf
    from kittentts.onnx_model import KittenTTS_1_Onnx

    onnxruntime.disable_telemetry_events()
    model = KittenTTS_1_Onnx(
        model_path=str(args.model_dir / config["model_file"]),
        voices_path=str(args.model_dir / config["voices"]),
        speed_priors=config["speed_priors"],
        voice_aliases=config["voice_aliases"],
    )
    args.output.mkdir(parents=True, exist_ok=True)
    for voice in args.voices:
        start = time.perf_counter()
        samples = model.generate(args.text, voice=voice)
        elapsed = time.perf_counter() - start
        path = args.output / f"Kitten-{voice}.wav"
        sf.write(path, samples, 24000)
        print(f"{path}: {len(samples) / 24000:.2f}s audio rendered in {elapsed:.2f}s")
    print(f"Peak Mac process memory: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20:.0f} MiB")


if __name__ == "__main__":
    main()
