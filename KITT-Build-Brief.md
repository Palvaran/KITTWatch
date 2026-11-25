# KITT build brief
## An offline preparedness assistant for Apple Watch and Mac

**Goal.** Ask KITT a practical preparedness question on a GPS-only Apple Watch Series 5, get a useful answer away from the phone, then pick up the same conversation on an M4 Max. Success means the Mac knows what was asked, which guidance the watch used, what the user decided, and what work is still open.

**First end-to-end demo.** At home, select a household of three. Walk out of range with the watch and ask, “How much water should we store for three days?” KITT shows **9 US gallons as a planning baseline**, the calculation, and the saved FEMA reference. Tell it, “We already have four gallons.” Back at the Mac, open the conversation and ask, “How much more do we need?” KITT answers **5 more gallons** without asking for the household size again. Change the plan to five days and the answer becomes **11 more gallons**. The app does the arithmetic and keeps the units. [FEMA emergency supply checklist](https://www.ready.gov/sites/default/files/documents/files/checklist3.pdf)

## 1. Prove the watch can do the job

| Target | Starting point |
| --- | --- |
| Watch | MWVF2LL/A, Series 5, 44 mm, GPS-only. S5 dual-core CPU, 1 GB shared RAM, 32 GB storage. Target watchOS 10. |
| Mac | M4 Max MacBook Pro with 36 GB unified memory. Use it for development, content preparation, evaluation, and a larger local model for longer conversations. |
| First model | SmolLM2-135M-Instruct, 4-bit GGUF, using a CPU build of llama.cpp for watchOS. Start with a 1,024-token context. Keep the full transcript on disk. |
| Installation | Build a minimal SwiftUI watch app on the Mac with Xcode and signing. Pin the engine revision and model file checksum. Verify that the toolchain can deploy to the physical watch before building the rest of the app. |

MicroPrompt reports **12.6 generated tokens/second** for SmolLM2 using a 92 MB weight file on a first-generation SE with the same S5 chip. One run took 5.6 seconds from starting inference to the first token. These are comparison points. Measure cold launch, first answer, sustained generation, memory pressure, and battery change on the actual Series 5. Test dictation separately with the phone unavailable and Wi-Fi off. Provide tappable questions and text input so the field guide remains usable if dictation needs connectivity. [Hardware specifications](https://support.apple.com/en-us/118453) · [Series 5 memory and model identification](https://everymac.com/systems/apple/apple-watch/index-apple-watch-specs.html) · [S5 prototype measurements](https://sabit-shaikholla.github.io/projects/microprompt/)

**Code ownership.** Write the KITT app in Swift. Upstream llama.cpp carries an MIT license and SmolLM2-135M-Instruct carries Apache 2.0. Preserve applicable notices when packaging them. The MicroPrompt repository and article document feasibility. A license granting reuse of its app code was not identified during planning. [llama.cpp license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) · [SmolLM2 model card](https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct) · [MicroPrompt repository](https://github.com/sabit-shaikholla/microprompt)

## 2. Give the watch an offline field guide

Start with a **three-day household power and water outage**. Write short, reviewed entries for water storage, interpreting water notices, preserving food during an outage, and finding the household’s saved supplies and contacts. Add hurricane preparation and hiking as later content packs. Keep personal inventory separate from published guidance so a household edit never changes the underlying reference.

- **On the Mac:** Create each entry with a stable ID, question variants, applicability, exceptions, short answer, source URL, source date if known, review date, and version. Package reviewed entries into a small searchable database. Install a complete pack before replacing the previous version.
- **On the watch:** Search locally using keywords and aliases. Include exception terms such as “smells like gasoline.” Present the reviewed action directly when wording or quantities matter. Feed only a short relevant passage and recent turns into the model for conversational follow-ups. Offer browseable topic buttons when no reliable match is found.
- **For live conditions:** Give saved guidance and current notices separate displays. Show the issuing authority, area, retrieval time, and expiration when available. If disconnected, say when the last check occurred. An empty cache cannot establish that an area is clear. [National Weather Service API](https://www.weather.gov/documentation/services-web-api)
- **For calculations:** Use ordinary functions with explicit units for people, days, and gallons. Let users correct inputs and see the revised result immediately.

**Content acceptance example.** “We’re under a boil-water notice” and “Our water smells like gasoline after a flood” must lead to different entries. For suspected fuel contamination, display the CDC guidance to use bottled water or another safe source and contact the health department. Boiling cannot make that water safe. Test the phrase “would boiling help?” as a follow-up to ensure KITT retains the contamination detail. [CDC emergency drinking-water guidance](https://www.cdc.gov/water-emergency/about/index.html)

## 3. Resume on the Mac without losing work

Use the Exchange analogy at **task level**. One device owns a task at a time. The watch can capture ideas while the Mac works on a different task. Replicate saved turns, decisions, and completed steps. Each device loads its own model and rebuilds the prompt from that record.

| Record | Minimum fields and purpose |
| --- | --- |
| Conversation event | Event ID, conversation ID, parent event ID, originating device, local sequence, timestamp, type, and payload. Preserve exact user wording. Parent links make divergent offline turns visible. |
| Task checkpoint | Task ID, goal, inputs, completed steps and results, pending step, owner device, ownership generation, and status. Save a checkpoint after each completed step. |
| Replica progress | Track confirmed receipt per device. Replay missing events after reconnect and deduplicate by event ID. A timestamp alone cannot establish ordering. |
| External action | Stable action ID, task generation, status, and any result or receipt. On an uncertain result, check the destination before retrying. |

**Proposed first transport.** Keep an on-device store on both watch and Mac. Use a paired iPhone companion as a store-and-forward relay via Watch Connectivity, then an authenticated local-network connection to the Mac. The relay can hold a batch until the Mac is reachable. Distinguish “saved on watch,” “delivered to phone,” and “accepted by Mac.” The watch must answer from its installed guide even when both peers are unavailable. [Apple Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity)

**Planned switchover.** When the user says “continue on my Mac,” the watch saves the latest checkpoint, records a handoff with a unique ID and target, and stops executing that task before sending the offer. The Mac persists the referenced events and checkpoint, accepts that handoff once, and records the next ownership generation before resuming. It acknowledges duplicate offers with the same result. If the acknowledgment is lost, the watch can retry the same offer while it waits. A missed heartbeat alone never transfers ownership. For the first build, a permanently lost owner requires explicit recovery from the last synced checkpoint.

**Offline changes.** If the watch and Mac both receive new conversation turns while apart, preserve both histories. Merge independent notes. If both changed the same household fact, show the two values and ask which to use before calculating from it. Keep research, file changes, and other long-running work on the Mac when practical. The watch should save progress before suspension.

## 4. Improve the model where evaluation shows a gap

1. **Create a baseline first.** Write scenario-based tests and expected answers from the reviewed pack. Include ambiguous language, irrelevant matches, corrections, missing quantities, stale alerts, and situations where one detail changes the appropriate action.
2. **Compare three builds.** Run the same held-out scenarios against stock SmolLM2, stock SmolLM2 with retrieval, and tuned SmolLM2 with the same retrieval. Keep whole scenario families in the test set so near-duplicate phrasings cannot inflate scores.
3. **Train on the M4 Max.** If a behavior fails repeatedly, create reviewed examples showing the desired response. Use LoRA supervised fine-tuning for behaviors such as retaining a critical exception, asking for one missing fact, or admitting the guide lacks an answer. Keep source updates in the content pack so they can ship independently. [LoRA guide](https://huggingface.co/docs/peft/main/en/conceptual_guides/lora)
4. **Evaluate the shipped artifact.** Merge the selected adapter, export and quantize the model, then rerun the tests on the actual watch. Record retrieval accuracy separately from answer accuracy, critical omissions, unsupported claims, time to first useful answer, and battery use. Keep the simpler build if tuning delivers no measurable improvement.

## 5. Build order and definition of done

| Milestone | Demonstration required |
| --- | --- |
| 1. Local inference | Install the independently written app on the Series 5, generate one reply offline, and record latency and memory behavior. Verify what happens when the wrist lowers or the app closes. |
| 2. Offline preparedness | Ship the first reviewed content pack, local search, and water calculator. The three-person demo works after a cold launch without a phone or network. Critical exception cases show the reviewed guidance. |
| 3. Conversation continuity | Complete the watch-to-Mac demo. Both original turns survive a restart. Five duplicate deliveries produce one logical event and one ownership transfer. Disconnect before and after Mac acceptance and recover without double execution. |
| 4. Model decision | Publish a side-by-side evaluation of baseline, retrieval, and optional tuning. Record which version earned deployment on the Series 5 and the failures that remain. |

**First implementation ticket.** Build the watchOS 10 SwiftUI screen with one bundled model, one reviewed water-planning entry, and a local transcript. On the physical watch, ask one free-form question, run the water calculation, close the app, reopen it, and verify that both turns and their inputs survived. That establishes the hardware, storage, and offline baseline for the handoff work.
