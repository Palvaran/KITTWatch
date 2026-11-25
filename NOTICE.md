# Third-party notices

KITT's own code (everything under `Apps/`, `Packages/`, and `scripts/`) is written for this project. It does not reuse code from MicroPrompt, which was used only as a feasibility reference.

KITT ships with these components. Keep these notices with any build you distribute.

## llama.cpp / ggml

- Source: https://github.com/ggml-org/llama.cpp
- Revision: see `scripts/versions.env` (`LLAMA_CPP_REV`)
- License: MIT. The full text is copied to `Packages/KITTEngine/Frameworks/llama.cpp-LICENSE` by `scripts/build-llama.sh`.
- Local change: `ggml/cmake/common.cmake` treats any `arm64*` architecture as ARM (so `arm64_32` gets the NEON kernels). Applied at build time to a clean checkout.

## SmolLM2-135M-Instruct

- Model: https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct (Hugging Face)
- GGUF quantization: https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF, file and revision pinned in `scripts/versions.env`
- License: Apache License 2.0. https://www.apache.org/licenses/LICENSE-2.0

## Other models used in evaluation only

`Eval/RESULTS.md` compares models that are **not** shipped: LFM2.5-350M (LFM Open License v1.0), SmolLM2-360M-Instruct (Apache 2.0), Gemma 3 270M (Gemma Terms of Use) and Falcon-H1-Tiny-90M-Instruct (Falcon LLM License). Read the licence before putting any of them on the watch.

## Guide content

Guide entries paraphrase public US government guidance (Ready.gov/FEMA and CDC) and link to the source. Each entry records its source URL, the date printed on the source where there is one, the date the wording was checked, and its review status. All entries are `pending` until a person has checked them against the source.
