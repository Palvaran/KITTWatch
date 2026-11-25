# KITT

An offline preparedness assistant for a GPS-only Apple Watch Series 5 (watchOS 10), with the Mac picking up later. `KITT-Build-Brief.md` has the goals and milestones.

This is the second pass at the brief's first implementation ticket. It keeps the first pass's event log, units and build approach, and changes who answers a question: the reviewed guide and the calculator answer first, and the model only speaks when you ask it to. `Eval/RESULTS.md` has the measurements behind that choice.

## Status

| Part | State |
| --- | --- |
| `KITTCore` (guide, search, calculator, event log, session) | All 67 core tests passed on macOS with guide pack v7 |
| `KITTEngine` (llama.cpp wrapper) and the `kitt` tool | Built and run on Linux against the pinned llama.cpp with five real models; 5 engine tests pass |
| watchOS llama.cpp build | **`scripts/build-llama.sh` runs end to end on the M4 Max** and passes its Series 5 instruction checks (NEON kernels present, nothing the S5 lacks). A built framework is in `Packages/KITTEngine/Frameworks/` |
| Watch app (`Apps/KITTWatch`) | **Builds in Xcode** for the Series 5 and the simulator. Installing it straight from Xcode failed repeatedly over the watch's network link; it installs through the iPhone (`KITTPhone` scheme, see below) |
| On the watch | An earlier build accepted dictation and spoke replies on the Series 5 (watchOS 10.6.2). The v7 executable links for arm64_32. Verify the signed install, stopping speech from Show calculation, and both dehydration sources on the watch. Speed, memory and battery remain unmeasured |
| Guide pack | 20 entries in v7, all pending human source review. See the [entry-by-entry review](Eval/SOURCE-REVIEW.md) |

## Layout

| Path | What it is |
| --- | --- |
| `Packages/KITTCore` | Pure Swift, no UI, no llama.cpp. Guide pack and search, hazards, water calculator, append-only event log, the session that routes each turn, prompt building, and the evaluation runner |
| `Packages/KITTEngine` | `LlamaEngine` (llama.cpp C API) and the `kitt` command-line tool. Same engine source on the watch, the Mac and Linux |
| `Apps/KITTWatch` | SwiftUI app: home, answer screen, guide browser, transcript, household, measurements |
| `Apps/Shared` | The four-segment red scanner mark, used in the watch header and the iPhone app. Both app icons are drawn from it (`Assets.xcassets`) |
| `Apps/KITTPhone` | Minimal iPhone app that carries the watch app to the watch (`KITTPhone` scheme). KITT itself does not need the phone |
| `Eval/` | `scenarios.json` (229 scenarios, 352 turns across development and historical held-out cases), `RESULTS.md`, full transcripts per model in `results/`, and the independent trial files in `trials/` |
| `scripts/` | Pinned versions, model download and checksum, llama.cpp builds for watchOS and for this machine |
| `project.yml` | XcodeGen spec that generates `KITT.xcodeproj` |

## How a turn is answered

The user's exact words are saved to `events.jsonl` (fsync) first. Then, in this order:

1. **A hazard described in the message** ("our water smells like gasoline", "the generator is running in the basement") shows that hazard's reviewed entry and flags it for the conversation, with a banner the user can clear. A device that is only *located* ("the generator is in the basement") gets the warning and one question, "Is it running there, or are you planning to run it there?", with three answers under it. **This applies to us**, a yes or a description of use flags it. **Not in use**, "it's off" or "we're taking it outdoors" records it as ruled out ("OK. I haven't flagged the generator."). **Not sure**, "I don't know", "I haven't checked yet" or a possibility ("it might be running", "maybe we'll run it there tonight") records it as unknown: no flag, and the warning and question stay on screen. A reply that answers nothing gets "I didn't catch an answer." and the question again, so the next message can still answer it.
2. **A hazard still active** answers follow-ups with the same entry: anything in its scope ("would boiling help?"), and anything that points back at it ("what if I run it through the Brita?"). It also blocks entries it overrides (boiling steps).
3. **Arithmetic** goes to the water calculator.
4. **A reliable guide match** shows the entry's text verbatim, with buttons for related entries. A note that changes what to do first leads the answer ("Do not use insulin that has frozen."). With no reliable match, a hazard entry that is among the candidates is shown anyway if the question names its subject and one of its keywords. That is a precaution for that reply only, with a **This applies to us** button. With no reliable match, an urgent entry (dehydration, heat illness, hypothermia, frostbite, gas leak) is shown first when the message reports one of its signs and doesn't negate it: "nobody has had water to drink", "confused while mowing in the heat", "smells like rotten eggs". The other candidates become buttons, and the reply ends "(Shown first in case someone needs help now.)". A topic word alone is not a sign: "We don't smell gas. Which flashlight…?" and "What should I pack before a heat wave?" don't get first aid.
5. **Anything else** gets "the guide doesn't cover that" plus buttons for near matches, and an **Ask the model anyway** button. A model reply is labelled unverified, and any number in it that is not in the guide text it was given is flagged.

`KITTSession.modelPolicy` can instead send follow-ups about the entry on screen straight to the model (`.groundedFollowUps`). It is off because no stock model tested does that reliably.

Household facts (people, stored water, plan length) are read from every message but saved only when the message is about the water plan (step 3, including a bare follow-up such as "what about for 5 days?" after a water answer) or plainly states the household ("we're a family of four", "plan for 7 days"). Words that also describe other things ("for two days", "two people") count only in a question about water amounts or with a planning word (plan, store as a verb, stock, supply, prepare). "Over the last three days" is never a plan length, and water someone drank or used up is never water on hand. So "Nobody has had anything to drink for two days. How long can we go?" and "I drank two gallons over the last three days" leave a 7-day plan, and the water on hand, alone.

## On the watch

- **Home** has the scanner mark, **Ask KITT** (dictation, Scribble or keyboard), **Browse guide** (topics, then entries), **Resume** when there is a conversation, and any flagged hazard with Show and Clear. **More** (top right) has the household, New conversation, Read replies aloud and the measurements.
- **Answer** opens at the top of the newest reply. A guide reply's first sentence is in bold and the rest follows in full. Under KITT's hazard question come **This applies to us**, **Not in use** and **Not sure**. When KITT shows an entry as a precaution ("Shown first in case someone needs help now", "Shown in case your question involves this"), the other topics it considered are buttons directly under the answer; otherwise related topics are behind **Related topics**. Model replies are labelled **Unverified**. Sources, **Ask a follow-up** and **Transcript** are at the bottom.
- **Water answers** show the total, the household size and plan length, whether the plan length is the 3-day default, and guide notes such as "In very hot weather, water needs can double." **Show calculation** has the arithmetic and the baseline it comes from.
- **Speech.** While a reply is read aloud, a stop square sits at the top of every screen. Opening Show calculation, the source or the transcript doesn't stop it, and going back returns to the same answer.

Hazards, facts and calculations are saved as their own events, so the Mac can rebuild the same state from the record. An answer to a hazard's question is saved too, as `ruledOut` or `unknown`, so a helper reading the handoff can tell "the user said it isn't in use" from "the user didn't know". The transcript shows them as "Not in use: …" and "Not sure: …".

## Build and install (on the M4 Max)

The model (checksum verified) and the llama.cpp framework are already in place from the build on 2026-11-23, so the remaining steps are:

```bash
cd ~/Dev/KITT
xcodegen generate && open KITT.xcodeproj
```

In Xcode, set your team (or fill in `DEVELOPMENT_TEAM` in `project.yml`, which survives `xcodegen generate`), then select the Series 5 as the run destination and run the **KITTWatch** scheme. It runs **Release**; Debug Swift is much slower, so don't measure with it.

Getting the watch to show up as a destination:

- Connect the iPhone it is paired with to the Mac by cable and trust the Mac. The watch then appears under the iPhone's **Paired Watches** in **Window › Devices and Simulators**.
- A Series 5 only appears when the Mac and the watch are on the same Wi-Fi network.
- Turn on **Developer Mode** on the iPhone and on the watch (**Settings › Privacy & Security › Developer Mode**; the watch restarts and asks you to confirm). On the watch the switch often appears only after Xcode has tried to run on it once.
- The first run prepares the watch for development and copies the 92 MB model, which takes a while. Keep the watch unlocked and on its charger.
- With a free Apple ID the install expires after 7 days; run from Xcode again to renew it.

**If Xcode can't reach the watch** (repeated "A connection to this device could not be established", "Bluetooth connection to the device was invalidated before tunnel could be created", or "Connection interrupted" during the install), install through the iPhone instead. That is what worked for the Series 5 here:

1. Choose the **KITTPhone** scheme and the iPhone (connected by cable) as the destination, and press Run. Xcode installs a small iPhone app with KITT embedded in it. Run it again after pulling changes to update the watch; run `xcodegen generate` first only when `project.yml` changed.
2. On the iPhone, open the **Watch** app. If KITT isn't installing on its own, go to **My Watch**, scroll to **Available Apps**, and tap **Install** next to KITT. The iPhone sends it to the watch the way it sends App Store watch apps, so keep Bluetooth on.
3. KITT runs on the watch without the phone. The iPhone app only carries it there (and will host the phone relay in milestone 3).

To rebuild from nothing (new llama.cpp pin, new model, another Mac):

```bash
brew install xcodegen cmake
(cd Packages/KITTCore && swift test)        # core logic, a few seconds
scripts/fetch-model.sh                       # 92 MB SmolLM2 Q4_0, SHA-256 checked
scripts/build-llama.sh                       # llama.cpp → Packages/KITTEngine/Frameworks/llama.xcframework
```

`build-llama.sh` uses CMake's Makefile generator, one architecture per build, and has run end to end on this Mac. It stops on purpose if the `arm64_32` patch no longer applies, or if the S5 slice lacks NEON code or contains instructions the S5 can't run. Logs are in `.build-llama/`.

## Try it without the watch

`scripts/kitt` runs the same session and engine on the Mac. The first call builds llama.cpp for the Mac (CPU only, to match the watch).

```bash
M=Models/SmolLM2-135M-Instruct-Q4_0.gguf
scripts/kitt ask --people 3 "How much water should we store for three days?" "We already have four gallons." "Change the plan to five days"
scripts/kitt ask "Our water smells like gasoline after a flood" "would boiling help?"
scripts/kitt ask --people 3 --days 7 --speech "The generator is in the garage."  # --speech: what the watch reads aloud
scripts/kitt ask --model $M --auto-model "What are the best hiking boots?"   # presses "Ask the model anyway"
scripts/kitt search "city says boil our water"                               # how search ranks a question
scripts/kitt bench --model $M                                                # load, prefill, generation speed
scripts/kitt eval --model $M --scenarios Eval/scenarios.json --out Eval/results
KITT_MODEL=$M scripts/kitt test                                              # engine tests with the real model
```

## Milestone 1 checklist (on the physical watch)

Measurements go to `metrics.jsonl`. View them under **More › Measurements**, or pull the file with Xcode › Devices and Simulators › KITT › Download Container.

- [ ] Phone off or out of range, Wi-Fi off. Cold launch, then **More › Benchmark**. Record `model_load.ms`, `prewarm_ms`, `ttft_ms`, `tokens_per_second`, `prefill_tokens_per_second` and `peak_footprint_mb`. MicroPrompt measured 5.6 s to first token for a 143-token prompt and 12.6 tok/s on the same S5 chip.
- [ ] Run the benchmark five times in a row. Later runs should show `reused_tokens` close to `prompt_tokens` and a much shorter wait. Note battery start and end and `thermal_state`.
- [ ] Type or Scribble a question the guide doesn't cover, then tap **Ask the model anyway**. That is the ticket's free-form reply.
- [ ] Lower your wrist during generation, and separately press the crown. Check the `scene_*` entries, and whether the reply finished or saved as "stopped".
- [ ] Set a household of 3, tap "How much water should we store?" and expect 9 US gallons. Scribble "We already have four gallons." and expect 5 more.
- [ ] With read-aloud on, ask a water question. While it is speaking, open **Show calculation**, tap the stop square there, and go back: it should be the same answer, scrolled where you left it, and silent.
- [ ] Tap "What if our water may have fuel or chemicals in it?"; then Scribble "our water smells like gasoline" in a new conversation and check the banner appears and "would boiling help?" repeats the warning.
- [ ] Force-quit, reopen, and confirm every turn, fact, calculation and the banner are still there.
- [ ] Try dictation with the phone unavailable. Whatever happens, the topic buttons and Scribble must still work.

## Changing the guide

`Packages/KITTCore/Sources/KITTCore/Resources/guide-pack.json` is the pack. Its sources are short public pages from US government agencies (Ready.gov/FEMA, CDC, FDA, PHMSA, and MedlinePlus from the National Library of Medicine), which are free to reuse, plus one Scientific American explainer for how long a person lasts without water. That one answers curiosity; someone who has already gone without gets the MedlinePlus dehydration entry, which leads with what to do and when to get help. Each entry cites one page. The pack covers water (storage, rationing, treatment, notices, contamination, going without), dehydration, food in an outage, power outages, generators and carbon monoxide, gas leaks, getting ready for a heat wave, heat illness, hypothermia, frostbite, and insulin without a fridge. Good next sources in the same style: Ready.gov's hazard pages (winter weather, floods, wildfire smoke) and the CDC's natural disaster pages.

To add an entry, keep the answer under 420 characters and the model passage under 80 words, give several ways people ask the question, and add its phrasings as dev scenarios plus a few fresh ones as held-out. If someone may need help now, give it `urgentSigns`: what a person reports when it applies, in the hazard-trigger syntax (slots separated by spaces, alternatives by `|`, `!` for words that cancel). A sign is ignored when negated ("we don't smell gas"), unless one of its slots lists negators, as in dehydration's "nobody|hasn't … had|since". A note with `"lead": true` is shown before the answer when one of its terms is in the question. A multi-word keyword whose other words are all stopwords ("in the heat") becomes a single-word keyword ("heat"), which counts for more. A new entry changes how strongly every search word counts, so run the whole suite: adding the water entries pushed "My gas water heater smells" toward the carbon monoxide entry until the gas leak entry existed.

After editing, run `swift test` in `Packages/KITTCore`: it checks the pack's structure, that every tappable question finds its own entry, and that the dev scenarios still pass. Then `scripts/kitt eval` for the held-out scenarios. When you have checked an entry against its source, set its `review.status` to `reviewed` with your name and the date; the watch shows unreviewed entries in orange on the source screen.

## Known limits

- **Speed, memory and battery on the watch are unmeasured.** KITT runs on the Series 5, but the model's load time, memory and battery use there are not known yet.
- **Hazards described in unfamiliar words are still sometimes missed.** Three independent sets of hazard questions missed 2 of 6, 2 of 6, then 1 of 12 (glowing briquettes brought into a tent). Each miss was fixed once found, so the project suite's zero is tuning to known phrasings. `Eval/RESULTS.md` has the history. Run fresh phrasings of your own before trusting it.
- **KITT errs toward warning, but only the user sets a flag.** When unsure, it shows a hazard warning as a one-reply precaution, so "how do I light the charcoal?" or a generator serial-number question gets a warning it may not need. A flag, which changes every later turn and shows the banner, is only set when the user describes the hazard, taps **This applies to us**, answers yes to KITT's question, or follows up proposing the risky use ("can I run it in the basement?"). Storage words ("boxed", "receipt") keep a message from setting a flag unless it also proposes using the thing. Which smells to exclude from the water warning (now chlorine, bleach and pool), and the use and storage word lists, are calls for the guide review.
- **Unfamiliar everyday phrasings often get buttons instead of an answer.** On the historical held-out split, KITT answered 25 of 37 routing checks directly and offered the expected topic on 11 more. One missed the expected topic entirely. The freezer-pen wording has since been used for tuning. Loosening `GuideSearch.Tuning` trades that safety for fewer taps.
- **Negation and pronouns are handled by rules, not parsing.** A negator cancels use and evidence words within three words of the same clause; this prevents a new flag but never clears an existing one. A pointer means the nearest thing named in an earlier clause of the same message, whether the hazard's device or something else ("When the washer finishes, can I run it again?"), and the previous message only if no earlier clause names anything. Each clause's action belongs to the device that clause names ("The sump pump is running. The generator is off."), and a use word aimed at a named object ("run the dryer") is not taken as using the hazard's device. A clause that says the user doesn't know ("not sure", "no idea", "haven't checked") or hedges a statement ("might", "could", "maybe", "probably", "I think") is a possibility: it never sets a flag, and it keeps a plain no beside it from ruling use out. A hedge standing alone ("I think", "probably", "I'm not sure") covers the clauses beside it up to a "but", so "The generator is idling, I think." reads the same as without the comma. "Whether ..." and "if it ..." are possibilities ("May I ask whether it's running?"); "if we ..." is not. A clause reporting a dropped belief ("I thought it was running") is ignored. A plain statement after a "but" still counts ("Not sure yet, but we've decided to start it there tonight" flags). A yes/no question about what the thing is doing now ("Is it running?", "Could it already be running down there?", "Could I be hearing it?") is a question, not a description; one with a person as subject or about using the thing proposes it ("Could I start it down there after supper?", "Can a camp cooker go in the tent?", "Is it OK if my dad starts the generator down there?" flag). A question the user answers in the next sentence takes that answer ("Is it idling? Yes, it is." flags, "No, it isn't." rules it out). A correction that names another device ("It's running. Sorry, I meant the dryer.") retracts what came before it in the message; "sorry" alone does not. These are word rules, and the trials in `Eval/trials/` are the test of them. A referent named in the same clause as the pointer is not recognised. The trials in `Eval/trials/` are the test of these rules.
- **Hazard triggers are word lists.** They read intent from words, not grammar: "the grill is in the garage, can we light it there?" flags, but a sentence that names the use only with a word missing from the list ("keep it going") relies on having no storage word. "Is there fuel in our water?" shows the contamination entry as a precaution and sets no flag, because it asks rather than describes.
- **Replies are read aloud** with the watch's built-in voice (More › Read replies aloud turns it off). It uses the playback audio setting so the silent switch doesn't mute it. The voice reads what the buttons say ("Answer: This applies to us, Not in use, or Not sure."), skips the calculator's working line, and says "Unverified." before a model reply. The stop square at the top of the screen stops it; so does asking or tapping anything else, starting a new conversation, or turning read-aloud off. Lowering the wrist or moving between screens does not stop it, so a reply can be heard without looking.
- **The parser does not understand "two adults and two kids" or "a week".** Since household facts are saved only for planning, "Two adults and two kids, how much water for a week?" now gets buttons instead of "Noted: 2 people". The working line under every water answer shows the inputs used, and the Household screen corrects them.
- **Saved supplies and contacts** (brief, section 2) are not built. Household facts are limited to people, stored water and plan length.
- **App Store size.** Watch apps are capped at 75 MB uncompressed and the model is 92 MB. Bundling works for development installs. The app already prefers a model file in `Application Support/KITT/Models/`, which is where a phone relay would put it.
- **Xcode.** Xcode 27 still installs and debugs on watchOS 10, the newest version a Series 5 runs. Keep it for this project; a later release may drop it.
- **Milestone 3** (phone relay, Mac app, handoff, ownership) is not started. The event record it needs is in place.
# KITTWatch
