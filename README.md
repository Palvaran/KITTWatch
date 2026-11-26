# KITTWatch

KITT distills emergency guidance from the CDC and FEMA into a field guide you can query offline on an Apple Watch. Ask a question in your own words or browse by topic. The watch can read the guidance aloud even when your phone is out of reach.

**Project status.** Guide pack v7 passed all 67 core tests on macOS. Guide pack v8 adds 45 everyday phrasings. With the speech change, the offline-model download, blind-trial scoring and the water-notice question there are 97 core tests; on Linux 95 pass, one is skipped, and one fails on a known scoring case (a burn question gets topic buttons instead of "not covered"). An earlier development build answered questions aloud on a Series 5 running watchOS 10.6.2. The v7 executable links for the Series 5. The signed install, the speech changes (pauses, wrist tap, Read again, voice choice), the model download and the revised source screen still need an on-watch check. See the [evaluation results](Eval/RESULTS.md) and [development guide](DEVELOPMENT.md).

## A question on the watch

During a power outage, ask **“How long does food stay safe without power?”** KITT brings up its guide entry on refrigerated and frozen food. You can listen to the answer and see which CDC page it came from.

Other questions need clarification. Ask **“The city sent a water alert. Can the dog drink from the tap?”** and KITT asks what the notice says, because the answer is different for boil water, do not drink and do not use. Tell KITT **“The generator is in the garage”** and it shows a warning and asks whether the generator is running or you plan to run it there. Tap **This applies to us**, **Not in use**, or **Not sure**. Choosing **Not sure** keeps the question open and records the uncertainty for the next turn.

## Where answers come from

- **Field guide.** The development guide contains 20 entries, including heat-wave preparation, food during outages, water storage and treatment, generators, gas leaks, heat and cold exposure, dehydration, and insulin storage. Each entry identifies its source and review status. Sources include FEMA’s Ready.gov, CDC, FDA, PHMSA, MedlinePlus, and one *Scientific American* explainer.
- **Water calculator.** Swift code does the arithmetic using household size, plan length, and stored water. The same inputs give the same result on the watch and in the Mac command-line tool.
- **Optional language model.** **Ask the model anyway** runs a quantized SmolLM2-135M-Instruct model locally through llama.cpp. Generated replies are labeled **Unverified**. In project trials, the small model frequently missed important warnings, so the guide and calculator handle ordinary turns. The model is not part of the app: it is a separate 92 MB download under **More › Offline model**, checked against a pinned SHA-256 before KITT uses it. Until it is downloaded, the button doesn't appear and everything else works the same.

## What works today

The watch app supports tap-to-browse topics, follow-up questions, and offline read-aloud with a choice of the watch's voices. A companion iPhone app carries the development build to the paired watch. Conversation turns, household settings, and hazard confirmations are saved on the watch so a conversation can resume after the app closes.

The core also runs on macOS and Linux. Its evaluation suite checks which guide entry appears, what the reply says, and which hazards remain flagged after a follow-up. Live watch-to-Mac handoff is planned. The current implementation can reconstruct conversation state from a copy of the event log.

## Current limitations

All 20 entries are **pending human source review**. The watch answers and the passages supplied to the optional model have undergone a [machine-assisted source review](Eval/SOURCE-REVIEW.md). An unfamiliar question can still bring up the wrong topic, leave the relevant entry behind a button, or miss a warning. Each guide answer names its source, and each water calculation shows the household size and duration it used. For an active emergency, follow instructions from local emergency services.

Concrete examples help improve KITT. A useful issue includes the exact question, any preceding turn that changes its meaning, the reply KITT gave, and what you expected it to show or remember. Use fictional household details when sharing a transcript.
