"""Render KITT's voice comparison offline on macOS.

Install kokoro-onnx==0.6.1 and soundfile in a Python 3.11 environment.
Place kokoro-v1.0.int8.onnx and voices-v1.0.bin from
https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.1
in .build/kokoro-trial under the repository root.
Without options it renders a sample sentence in three voices, for comparing them.
For the watch's guide recordings, place the full-precision kokoro-v1.0.onnx alongside
the int8 model. From the repo root, run:
  swift run --package-path Packages/KITTCore guide-voice-lines > .build/guide-lines.json
  python scripts/try-kokoro-voice.py --guide-lines .build/guide-lines.json --output Voices/narration
  scripts/build-voice-packs.sh --update
"""
import argparse
import hashlib
import json
import resource
import time
from pathlib import Path

import numpy as np
import onnxruntime
import soundfile
from kokoro_onnx import Kokoro


TRIAL = Path(__file__).resolve().parents[1] / ".build" / "kokoro-trial"
SAMPLE = "Your household plan calls for nine gallons of water."


def remove_render_tones(audio, rate):
    """Reject the two narrow spectral lines measured in the 24 kHz renders."""
    # A windowed low-pass shifted to each tone isolates just that band. Subtract
    # both bands with a centered FIR so the clip keeps its original timing.
    offsets = np.arange(-800, 801)
    width = 45  # half-width of each rejected band in Hz
    band = np.sinc(2 * width * offsets / rate) * np.blackman(len(offsets))
    band /= band.sum()
    kernel = np.zeros_like(band)
    kernel[len(offsets) // 2] = 1
    for center in (4800, 9600):
        kernel -= 2 * band * np.cos(2 * np.pi * center * offsets / rate)
    padded = np.pad(audio, len(offsets) // 2)
    return np.convolve(padded, kernel, mode="valid")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--text", default=SAMPLE)
    inputs.add_argument("--guide-lines", type=Path, help="JSON exported by guide-voice-lines")
    parser.add_argument("--output", type=Path, default=TRIAL / "samples")
    args = parser.parse_args()
    if not args.text.strip():
        parser.error("Supply a sentence to read.")

    onnxruntime.disable_telemetry_events()
    weights = "kokoro-v1.0.onnx" if args.guide_lines else "kokoro-v1.0.int8.onnx"
    model = Kokoro(str(TRIAL / weights), str(TRIAL / "voices-v1.0.bin"))
    args.output.mkdir(parents=True, exist_ok=True)
    if args.guide_lines:
        replies = json.loads(args.guide_lines.read_text())
        replies[SAMPLE] = [{"text": SAMPLE, "pause": 0}]
        for name, voice in [("Heart", "af_heart"), ("Michael", "am_michael")]:
            for pace, speed in [("Normal", 1.0), ("Slower", 0.85)]:
                cache = {}
                for transcript, lines in replies.items():
                    parts = []
                    for line in lines:
                        text = line["text"]
                        if text not in cache:
                            audio, rate = model.create(text, voice=voice, lang="en-us", speed=speed)
                            cache[text] = (remove_render_tones(audio, rate), rate)
                        audio, rate = cache[text]
                        parts.extend([audio, np.zeros(round(line["pause"] * rate))])
                    digest = hashlib.sha256(transcript.encode("utf-8")).hexdigest()
                    path = args.output / f"Guide-{name}-{pace}-{digest}.mp3"
                    soundfile.write(path, np.concatenate(parts), rate,
                                    bitrate_mode="CONSTANT", compression_level=0.75)
                print(f"Rendered {len(replies)} replies for {name} at {pace}", flush=True)
        return
    for voice in ("am_michael", "am_fenrir", "af_heart"):
        start = time.perf_counter()
        audio, rate = model.create(args.text, voice=voice, lang="en-us", speed=1.0)
        elapsed = time.perf_counter() - start
        name = voice.split("_")[1].title()
        path = args.output / f"Kokoro-{name}.wav"
        soundfile.write(path, remove_render_tones(audio, rate), rate, subtype="PCM_16")
        print(f"{path.name}: {len(audio) / rate:.2f}s audio rendered in {elapsed:.2f}s")
    print(f"Peak Mac process memory: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20:.0f} MiB")


if __name__ == "__main__":
    main()
