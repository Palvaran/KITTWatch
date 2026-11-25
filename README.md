# KITTWatch

KITT is an offline preparedness assistant for Apple Watch. It was built for a GPS-only Series 5 so someone in a power outage can look up a question, calculate household water supplies, and hear the answer aloud even when their phone is out of reach.

**Project status.** The development build has run on a Series 5 with watchOS 10.6.2, including spoken replies. This repository currently contains the project overview. The app source and an installable build have yet to be published here.

## A question on the watch

With a household of three and a seven-day plan, ask **“How much water should we store?”** KITT calculates **21 US gallons** and shows the calculation (3 people × 7 days × 1 gallon per person per day). You can check the household size and duration, change either one, or enter the water already on hand to see how much more to store.

Other questions need clarification. Tell KITT **“The generator is in the garage”** and it shows a warning and asks whether the generator is running or you plan to run it there. Tap **This applies to us**, **Not in use**, or **Not sure**. Choosing **Not sure** keeps the question open and records the uncertainty for the next turn.

## Where answers come from

- **Field guide.** Nineteen entries cover water storage and treatment, food during outages, generators, gas leaks, heat and cold exposure, dehydration, and insulin storage. Each entry identifies its source and review status. Sources include FEMA’s Ready.gov, CDC, FDA, PHMSA, MedlinePlus, and one *Scientific American* explainer.
- **Water calculator.** Swift code does the arithmetic using household size, plan length, and stored water. The same inputs give the same result on the watch and in the Mac command-line tool.
- **Optional language model.** **Ask the model anyway** runs a quantized SmolLM2-135M-Instruct model locally through llama.cpp. Generated replies are labeled **Unverified**. In project trials, the small model frequently missed important warnings, so the guide and calculator handle ordinary turns.

## What works today

The watch app supports tap-to-browse topics, follow-up questions, and offline read-aloud. A companion iPhone app carries the development build to the paired watch. Conversation turns, household settings, and hazard confirmations are saved on the watch so a conversation can resume after the app closes.

The core also runs on macOS and Linux. Its evaluation suite checks which guide entry appears, what the reply says, and which hazards remain flagged after a follow-up. Live watch-to-Mac handoff is planned. The current implementation can reconstruct conversation state from a copy of the event log.

## Current limitations

All 19 guide entries are **pending human source review**. Unfamiliar wording can trigger the wrong topic or miss a warning, and a duration mentioned in conversation can be mistaken for a change to the water plan. Check the source behind a guide answer and the inputs shown for a calculation. For an active emergency, follow instructions from local emergency services.

Concrete examples help improve KITT. A useful issue includes the exact question, any preceding turn that changes its meaning, the reply KITT gave, and what you expected it to show or remember. Use fictional household details when sharing a transcript.
