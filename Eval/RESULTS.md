# Off-watch evaluation

## Current results for guide pack v7

The model-off pipeline ran on macOS across 229 conversations and 352 turns. The 67 core tests also passed. A routing check asks whether the first reply gave the expected answer. The button column counts turns where the expected entry required another tap.

| Suite split | Correct direct routing | Expected topic offered as a button | Answer text passed | Flag checks passed | Scored critical failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| Development | 234/234 | 0 | 252/252 | 199/199 | 0 |
| Historical held-out | 25/37 | 11 | 28/38 | — | 0 |

Of the 37 historical routing checks, one missed the expected topic entirely. The freezer-pen case now requires the frozen-insulin warning in the first sentence. Its wording was used to tune v7, so its pass is a regression result. The 14 stop-and-guide conversations also retained their expected plan lengths after event-log replay. [Source review and trial results](SOURCE-REVIEW.md)

The signed v7 install and physical Series 5 checks are pending. Earlier on-watch speech observations and the older model benchmarks are recorded below.

## Archived v5 evaluation and earlier trials

What was measured: 222 scenarios (345 turns, 283 with answer checks, 199 with flag checks, some of which also check the recorded answer to KITT's question) from `scenarios.json`, run on Linux x86-64 with llama.cpp `af5c583` (the pinned revision), CPU only, Q4_0 weights, greedy decoding. Guide pack `outage-3day@v5` (20 entries). Full transcripts for every model and build are in `results/`.

What was not measured: anything on the watch. KITT runs there, but speed, memory and battery on the Series 5 are still open.

## Correction to the first version of this file

The first version reported that the pipeline had **no critical failures**. That was wrong. It had two, both missed warnings on held-out phrasings:

- "Could we bring the charcoal grill into the living room for heat?" got "I'm not sure which guide entry fits" instead of the carbon monoxide entry.
- "What if I run it through the Brita?", after a chemical-smell report, got the same non-answer instead of the contamination warning.

The scorer passed both because the required phrase list included "not" and the reply contained "not sure". The critical-failure count then only looked at failed answer checks, so a warning that was never shown did not count. With the scorer fixed and nothing else changed, that pipeline scored 28 of 35 answer checks with 2 critical failures, not 30 of 35 with none.

What changed since:

- **Scorer.** Phrases match on word boundaries. Hedges such as "not sure" are removed before required phrases are looked for. A reply in which KITT says it has no answer cannot pass an answer check. A turn in a critical family is a critical failure if it fails a check **or** does not show the expected entry outright. Three unit tests pin this down.
- **Checks.** Hazard scenarios no longer accept any negation. They require the protective action itself, for example "will not make" plus "bottled water", or "never" plus "outside".
- **Pipeline.** Hazard triggers can list alternatives per word, so the carbon monoxide hazard now knows rooms and more devices. While a hazard is what the conversation is about, a follow-up that points back ("run *it* through...") gets the warning again, whatever words it uses. A "not covered" reply leads its buttons with any active hazard.
- **Scenarios.** The two missed scenarios are fixed, so they moved from held-out to dev. Five fresh held-out hazard scenarios were added and run once. They all passed, which the independent trial below shows was too kind.

## What an independent trial found (2026-11-24)

Six hazard turns were then written by someone who had not seen the trigger lists. KITT showed the warning in the first reply on 4 of 6. The two it missed:

| Question | Warning missing from the first reply |
| --- | --- |
| "Can I use the barbecue in the den if the power stays out?" | Carbon monoxide |
| "Water from the kitchen faucet smells like paint thinner." | Possible chemical contamination |

Both times KITT offered the right entry as a button, and the corrected scorer counted both as critical failures. The follow-up fix held: "Would a pitcher with a new cartridge change anything?" kept the gasoline warning.

The first held-out set, written before any tuning, also missed 2 of its 6 hazard turns.

What changed in response:

- **When unsure, show the warning.** If no entry matches reliably, but a hazard entry is among the candidates and the question names both its subject ("water", "barbecue") and one of its keywords, KITT now shows that entry and flags it, instead of offering it as a button. The reply ends with "(Shown because your question may involve this. Clear the flag if it doesn't.)"
- **An unexplained smell or taste is enough.** "Water smells like X" raises the contamination warning for any X, except chlorine, bleach and pool, which a trigger can now exclude.
- **More vocabulary**: rooms (den, cellar, sunroom...), devices (barbecue, hibachi, smoker, pressure washer...) and solvents (paint thinner, turpentine, acetone...).
- The two missed questions and the pitcher follow-up are now dev scenarios.

This buys recall with false alarms, on purpose. These now get a warning they may not need: "what does well water taste like", "the sink water smells like rotten eggs", "how do I light the charcoal?", "how do I keep the generator from getting stolen?". A new dev family, `not-a-hazard`, pins three cases that must stay quiet ("How much water and fuel should we store?", "My gas water heater smells", fuel for the generator not read as fuel in water).

These changes were then tested by the third trial below.

## Third independent trial (2026-11-24): recall up, but guesses left flags on

Twelve hazard questions and six routine ones, written before the tester read the revised trigger lists, run through the previous build and the "show the warning when unsure" build on the Mac with the model off:

| First-reply result | Previous build | "Show when unsure" build |
| --- | ---: | ---: |
| Carbon monoxide warning shown when expected | 3/6 | 5/6 |
| Water contamination warning shown when expected | 3/6 | 6/6 |
| Hazard warning raised on a routine question | 0/6 | 3/6 |

The one miss: "We've got briquettes still glowing in a metal pan. Can we bring them into the tent for warmth?" Caught: a pesticide spill, diesel in a cistern, and tap water smelling of both bleach and petrol.

The false alarms (a generator serial number, a barbecue assembly manual, why charcoal-cooked food tastes smoky) mattered less for the warning than for what it left behind. Each raised a flag that stayed on, so after the manual question, a correct "9 gallons for three people for three days" sat under an active carbon monoxide banner.

What changed in response:

- **A guess warns once; only the user flags.** A warning KITT shows because it is unsure is now a precaution for that reply only, with a "This applies to us" button. A flag is set when the user describes the hazard, taps that button, or follows up within the hazard's scope ("Can I set it up in the garage?" after the manual question). A pointer alone ("Is it still under warranty?") does not flag. Each flag records which of these three set it, so the Mac can tell them apart.
- **Briquettes, coals and embers** count as fuel-burning devices; **cistern** counts as a water source.
- The briquettes question (exact wording) and paraphrases of the other cases are now dev scenarios, and the evaluation checks flags: 14 turns state which hazards must be flagged afterwards, including three routine questions that must leave none.

Replayed on the Mac with the trial's exact prompts, this build showed all 12 expected warnings, left the flag list empty on all six routine questions (three still showed a one-reply precaution, as intended), and returned the 9-gallon calculation after the manual question with no carbon monoxide flag. Across the three independent sets, first-mention misses on untuned wording were 2 of 6, 2 of 6, then 1 of 12.

## Fourth independent trial (2026-11-24): what the user means to do

Seven fresh conversations, worded before the tester read the revised rules, found that a follow-up was read by its words rather than its intent:

| Fresh case | What KITT did |
| --- | --- |
| After a generator warranty question: "Can I run it in our basement while the street is dark?" | Uncertainty reply, no flag. Missed the proposed indoor use. |
| After a grill-handle question: "I keep the receipt in the garage. Does that help?" | Set a carbon monoxide flag. The user had located a receipt. |
| After a generator-manual question: "It will stay boxed in the garage until spring." | Set a carbon monoxide flag for a device packed away. |
| "We got weed killer in the water barrel we drink from." | Uncertainty reply. Missed the contamination warning. |

The replay also found a flag error the first-reply score hides: "The water out of the bathroom tap has a rainbow slick and reeks of kerosene" showed the right water warning and also set a carbon monoxide flag, because "kerosene" plus "bathroom" looked like a heater indoors. The Mac would have inherited both flags.

What changed in response:

- **A hazard now has use words and storage words.** Use words say the user means to do the risky thing (run, light, cook, heat, drink, boil...). Storage words say it is put away (stored, boxed, receipt, warranty, manual...). A message with storage words and no use word does not set a flag, so "the generator stays boxed in the garage" is not an exposure but "it's stored in the garage, can we run it there?" is.
- **A follow-up that refers back is read with the previous message.** "Can I run *it* in our basement?" after a generator question now flags, because together the two messages name the device, the place and the use. It needs a pointer word, so "Can I run the dishwasher in the basement?" does not borrow the generator.
- **A follow-up near a precaution without an exposure shows the precaution again, unflagged.** "Can I set it up in the garage?" (assembly as much as use) and "Can I run it on the patio?" now get the warning once more and no flag. The receipt and boxed cases get an ordinary answer.
- **Any hazard entry shown without being described is a precaution.** "Is there fuel in our water?" shows the contamination entry with a "This applies to us" button but no flag, and "would boiling help?" next repeats the warning.
- **Kerosene** now counts as a carbon monoxide source only next to a heater, stove, lamp or lantern. **"Got ... in"** (and dumped, poured, seeped...) now describes contamination, and **"killer"** (weed killer), insecticide, poison and fertilizer count as chemicals.
- The four cases above, the kerosene case with the exact flag set, and four contrast pairs (storing vs running, patio vs basement, asking vs describing) are dev scenarios. The evaluation now checks flags on 28 turns.

The follow-ups are quoted from the trial; the first turns of each conversation are paraphrases, because the trial archive was not reachable from here. None of these changes has been tested on new wording.

## Fifth trial (2026-11-24): actions under way, pronouns, negation

The exact archive from the fourth trial passed on the Mac (22/22 answers, 22/22 routing, 24/24 flags). Eleven fresh conversations, in `trials/KITT-Use-Trial.json`, then tested intent. Of six that called for a flag, five showed the warning on the final turn and three set the flag. Of five controls, three ended with a flag they should not have. The clearest finding came from one opening, "I found the manual for our generator.", and three follow-ups:

| Next message | What KITT did | Cause |
| --- | --- | --- |
| "It's running in the basement right now." | No warning, no flag | "It's" was not recognised as "it" |
| "The dryer is in the basement. Can I run it tonight?" | Carbon monoxide flag | "it" was taken from the previous message, though this message names the dryer first |
| "The generator is in the basement. I won't start it down there." | Carbon monoxide flag | No notion of negation |

The other misses: "Can we fire it up in the mudroom?" (no "mudroom" in the room list), "Rain carried lawn pesticide into the well we drink from." (no "carried"), and "The sealed weed killer bottle sits on a shelf next to unopened bottled water. Nothing leaked." (flagged, because "leaked" counted although negated).

What changed in response:

- **Negation.** In a statement, "not", "never", "nothing", "won't" and other negators cancel the use and evidence words in the next three words of the same clause: "I won't start it" no longer proposes starting it, and "nothing leaked" is not a leak. A negated use counts as ruling the use out. Negation never cancels a device, a place or a chemical ("Don't worry, the generator is running in the garage" still flags), and questions are never negated ("Can't I run it in the garage?" still flags).
- **Pointers.** "It's", "that's" and "they're" count as pointers. A message refers back to the previous one only if the pointer is in its first sentence, so "The dryer is in the basement. Can I run it tonight?" no longer borrows the generator. A precaution is shown again only if the follow-up refers back and proposes a use, or uses a scope word, so "Is it available in red?" gets an ordinary answer.
- **Words**: mudroom, laundry, workshop, utility, pantry and similar as places; carried, flowed, dripped, entered, soaked, ran as ways a chemical gets into water; unplugged and disconnected as storage words.
- Both trial files are now dev scenarios: the fourth trial's 28 conversations as `trial3-*` families and the eleven fresh ones as `trial4-use-*`. The basement trio is also a named unit test.

One choice stayed as it was here: a device in a room with nothing ruling out use ("The generator is in the basement.") still flagged. The sixth trial changed that to a warning and a question.

None of these changes has been tested on new wording.

## Sixth trial (2026-11-24): where a thing is is not what it is doing

Thirteen turns in ten conversations, in `trials/KITT-Location-Trial.json`, run through the fifth-trial build and the one before it. Negation fixed two flag errors ("No one has started the generator in the basement", "Nothing spilled into the drinking water..."). Three cases still went wrong:

| User's wording | What KITT did | Expected |
| --- | --- | --- |
| "The new generator is in our basement, still sealed in its shipping carton." | Carbon monoxide flag | No flag: the user described storage |
| After a generator-manual question: "Quick update. It's running downstairs in the basement." | Uncertainty reply, no flag | Warn and flag: "Quick update" introduces no new subject |
| After the same question: "Can I run the dryer in the basement if it is full?" | Carbon monoxide flag | No flag: the user named the dryer as what they would run |

The last two are the acceptance pair: a sentence break can keep the subject, and one sentence can introduce a new one, so "only the first sentence can point back" fails both ways.

The trial also settled the question the fifth trial left open. "The generator is in the basement" and "We brought the gas grill onto the screened porch because of the rain" say where the thing is, not that it is in use.

What changed in response:

- **Located, not described: warn and ask.** For the carbon monoxide hazard, a device in a place with no use word gets the warning and one question, "Is it running there, or are you planning to run it there?", and no flag. A yes, a description of use ("We moved it while the burgers were still cooking") or **This applies to us** sets the flag (recorded as `answered`, `followUp` or `confirmed`); "No, it's off" gets "OK. Nothing is flagged." (since the seventh trial, "OK. I haven't flagged the generator."). On the watch, a **Not in use** button answers no with a tap. The water hazard is unchanged: a smell, sheen or leak is already evidence of exposure.
- **Pronouns.** A pointer refers back unless a sentence *before* its own names something with "the/our/my X" ("The dryer is in the basement. Can I run it tonight?"). Within one sentence, a use word aimed at a named object ("run the dryer") does not count as using the hazard's device. Taking a same-sentence phrase as the referent was tried first and broke the held-out "Would a LifeStraw fix that?", which the held-out set caught.
- **Words**: sealed, carton, crate, packaging, wrapped, unopened as storage; humming, idling as use.
- Negating an action prevents a new flag but does not clear an existing one. After "The generator is running in the basement", "I won't start it again" keeps the flag, because it never says the generator has stopped.
- The ten conversations, plus answers to the new question, are dev scenarios.

None of these changes has been tested on new wording.

## Seventh trial (2026-11-24): answers to the question

Twenty-five turns in twelve conversations, in `trials/KITT-Clarification-Trial.json`. Warn-and-ask held up: every "Our generator is in the basement." got the warning, the question and no flag, and "we're taking it outdoors before we start it" was told apart from "we intend to run it right there after dark". Three kinds of answer went wrong:

| User's wording | What KITT did | Expected |
| --- | --- | --- |
| "I don't know. My brother set it up." and "No idea if it's running. How can I tell?" | "OK. Nothing is flagged." | Use still unknown: no flag, the precaution still on screen |
| "The sump pump is running. The generator is off." | Carbon monoxide flag ("running" taken as the generator's) | No flag: the pump is running, the generator is off |
| "No, it is off." with the water flag already set | "OK. Nothing is flagged." beside an active water flag | "OK. I haven't flagged the generator." |

What changed in response:

- **Three answers.** Under the question the watch now has **This applies to us**, **Not in use** and **Not sure**. Typed replies take the same three paths. "I don't know", "no idea", "not sure" and similar phrases are recorded as unknown: the reply starts "Not flagged while you're not sure." and repeats the warning and the question, and a later yes or no settles it. The phrase only covers its own clause, so "Not sure, but we plan to run it there tonight" still flags. At first, softer words ("probably", "I think", "maybe") made a reply unknown only if it said nothing else, so "It might be running." flagged; the eighth trial changed that.
- **Ruled out and unknown are saved apart.** Each answer is a `ConditionChange` event with the new state `ruledOut` or `unknown` (older logs decode unchanged), held in `ConversationState.hazardAnswers`. The watch transcript shows "Not in use: …" or "Not sure: …", and `kitt ask` prints them after the flags, so the Mac can tell "the user ruled it out" from "the user didn't know".
- **Each clause's action belongs to what that clause names.** "The sump pump is running" is about the pump. A pointer means the nearest thing named in an earlier clause of the message, so "When the washer finishes, can I run it again?" is about the washer and "We've got briquettes still glowing in a metal pan. Can we bring them into the tent?" is about the briquettes. The first version of this rule lost the briquettes case, and the dev suite caught it. "Glowing" and "smoldering" are now use words.
- **"OK. I haven't flagged the generator."** A no names the device it was about and says nothing about other flags.
- The scorer can now require answers (`hazardAnswers`) as well as flags, counted with the flags. The twelve conversations are dev scenarios (`trial6-clarification-*`), and the sump-pump sentence is its own unit test.

None of these changes has been tested on new wording.

## Eighth trial (2026-11-24): possible use is not committed use

Twenty-five turns in twelve conversations, in `trials/KITT-Uncertainty-Trial.json`, each starting from "Our generator is in the basement." Five conversations matched the proposed behaviour throughout. The trial also proposed a rule: a possibility ("it might be running") should be recorded as unknown, and only a definite plan or a description of use should set the flag. The misses:

| User's wording | What KITT did | Expected |
| --- | --- | --- |
| "I haven't checked yet.", then "I checked. It's running down there." | Dropped the question, offered topics, left the flag clear | Unknown, then flag |
| "It might be running." / "I can't see it from here. It could be running." / "Maybe we'll run it down there tonight." | Flag | Unknown, question kept open |
| "It may be on; the noise could be the freezer." | Offered topics | Unknown |
| "I thought it was running. Turns out it's the dehumidifier; the generator is off." | Flag | Ruled out |

The first was the worst: the question was gone, so the user's actual answer a turn later was not read as one.

What changed in response:

- **Every clause is a statement, a possibility or a dropped belief.** Saying you don't know ("not sure", "no idea", "haven't checked", "I'll ask", "can't see") or hedging a statement ("might", "may", "could", "maybe", "probably", "I think") makes a clause a possibility. "I thought", "I assumed" and "I figured" report a belief the user has dropped. Only statements and questions can describe use, so a possibility never sets a flag, and a possible use beside a plain no ("It's off, but we might run it there later") leaves the answer unknown rather than ruled out. In a question, "could" and "may" ask permission ("Could we run it down there tonight?" still flags). The same rule applies to a first message: "The generator might be running in the basement" now gets the warning and the question instead of a flag.
- **The question stays open.** "I haven't checked yet" is now an unknown answer, which asks the question again. A reply that answers nothing and matches nothing else gets "I didn't catch an answer." and the question, instead of the topic list, so the next message can still answer it. An unrelated guide question ("How long can milk stay in the fridge?") is answered normally and closes the question.
- The twelve conversations are dev scenarios (`trial7-uncertainty-*`), and the two-turn exchange is a unit test.

None of these changes has been tested on new wording.

## Ninth trial (2026-11-24): commas and questions

Fourteen conversations, 27 turns, in `trials/KITT-Modal-Questions-Trial.json`, with the expectations fixed before the run. Ten matched. Each turn was also replayed into a second event log on the Mac and rebuilt the same state, which checks the replay logic the Mac will use. In all four misses KITT showed the warning but set a flag the user had not earned:

| User's wording | What KITT did | Expected |
| --- | --- | --- |
| "The generator is idling, I think." | Flag ("The generator is idling I think." was unknown) | Unknown: a comma should not change what the Mac believes |
| "Could it already be running down there?" | Flag | Unknown: the user asks what is happening |
| "May I ask whether it's running?" | Flag | Unknown |
| First message: "Could the generator already be running in the basement?" | Flag | Warning and question |

"Could I start it down there after supper?" and "Could I run the generator in the basement after supper?" were right to flag: the user proposes a specific action.

What changed in response:

- **A hedge standing alone covers its neighbours.** A clause that is only a hedge ("I think", "probably", "I'm not sure") makes the other clauses of its sentence possibilities too, up to a "but". "I think the freezer stopped, but the generator is running." still flags.
- **Embedded questions.** "Whether ..." starts a clause of its own and is a possibility. So is "if ..." unless a person is its subject: "No idea if it's running" and "Can you tell me if it's running?" are possibilities, "Is it OK if we run it in the basement?" proposes use.
- **What-is-happening questions.** A yes/no question with the thing as subject that asks about now (a form of "be" first, "be ...ing", or "already", "still", "now") is a possibility: "Is it running?", "Could it already be running down there?". A question with a person as subject, with "to" before the action, or about whether the thing can be used is still a proposal: "Could I start it down there?", "Is it safe to run it in the garage?", "Can a camp cooker burning propane go in the sleeping tent?" (an earlier trial's case, which the dev suite caught when the first version of this rule lost it).
- The fourteen conversations are dev scenarios (`trial8-modal-*`), and the acceptance pairs are a unit test.

None of these changes has been tested on new wording.

## Tenth trial (2026-11-24): questions the user answers, and corrections

Fourteen conversations, 26 turns, in `trials/KITT-Question-And-Answer-Trial.json`, run on the previous build and the ninth-trial build with expectations fixed in advance. Both passed 7 of 14: the ninth-trial build fixed "Could it be running there right now?" and "Is it time to check whether the generator is running?", and broke two others. Still wrong on the ninth-trial build:

| User's wording, after "Our generator is in the basement." | What KITT did | Expected |
| --- | --- | --- |
| "It's running. Sorry, I meant the dryer. The generator is off." | Flag | Ruled out |
| "Is it idling? Yes, it is." | Unknown (regressed) | Flag |
| "Is it idling? No, it isn't." | Unknown | Ruled out |
| "Is it idling? I just looked. The generator is off." | Unknown | Ruled out |
| "Is it OK if my dad starts the generator down there?" | Unknown (regressed) | Flag: a proposed use |
| "Could I be hearing the generator running downstairs?" (and as a first message) | Flag | Unknown; warning and question |

What changed in response:

- **A question the user answers.** When a question is followed by a short answer ("Yes, it is.", "No, it isn't."), the question takes that answer: yes makes it a statement, no negates its use words. "Is the dryer running? Yes, it is. I haven't checked the generator." still leaves the generator unknown.
- **Corrections.** "I meant", "my mistake", "my bad", "I misspoke", "scratch that" or "wrong one", in a sentence that names something else ("the dryer"), retracts everything before it in the message. "Sorry" alone does not ("The generator is running in the basement. Sorry, the dryer is loud." still flags), and neither does "I mean" without another thing named.
- **Questions separated from possibilities.** A question about what is happening ("is it idling?", "whether it's running", "if it's running") no longer stops a plain no beside it from ruling use out, the way a possible plan does ("It's off, but we might run it later"). "Off" inside a question ("If it's running, should I turn it off?") does not say it is off.
- **"If" with someone else as subject** proposes an action ("if my dad starts the generator"); "if" before a pointer or a form of "be" ("if it's running", "if the generator is running") asks about a state. A question with "be ...ing" asks what is happening whoever the subject is ("Could I be hearing it?").
- The fourteen conversations are dev scenarios (`trial9-qa-*`), and the pairs are a unit test.

None of these changes has been tested on new wording.

## On the watch, and guide v3 (2026-11-24)

KITT now runs on the Series 5. Installing straight from Xcode never worked: the connection either timed out, failed with "Bluetooth connection to the device was invalidated before tunnel could be created", or dropped mid-install. An iPhone app that carries the watch app (`KITTPhone`) got it there through the Watch app's normal install. The first question asked on the watch, "how long does a person last without water?", showed two gaps: the guide had no entry for it, and the command-line check answered it with the fridge entry because both are "how long" questions.

What changed:

- **Guide v3, 17 entries.** New: how long a person can go without water (Scientific American), rationing drinking water (Ready.gov), smell of gas in the house (PHMSA), during a power outage (FEMA's power outage sheet), heat stroke and heat exhaustion (CDC), hypothermia and frostbite (CDC), and insulin without a fridge (FDA). All are `pending` review.
- Adding entries changes every word's weight. "My gas water heater smells" (previously "not covered") briefly matched the carbon monoxide entry; it now gets the gas leak entry, and that scenario's expectation was changed to say so. "How long can milk stay in the fridge?" briefly lost to the insulin entry, which was fixed with food keywords ("milk", "meat", "dairy").
- Pronouns and "think" are now stopwords for search, so "my son is shivering and his speech is slurred" weighs the symptoms.
- Twelve phrasings used while writing the entries are dev scenarios (`guide-v3`). Seven fresh phrasings, written before any tuning and not tuned on, are held out (`heldout-guide-v3`): one was answered outright, five got the right entry as a button, one ("Is it bad to drink nothing for two days?") was read as "plan for 2 days". None showed a wrong entry.
- Replies are read aloud on the watch.

## Guide and speech trial (2026-11-25)

Thirteen model-off sessions on the Mac and a household replay, in `trials/KITT-Guide-And-Speech-Trial.json`. Read-aloud worked on the watch. What was wrong:

| What the user said | What KITT did | Expected |
| --- | --- | --- |
| "Nobody has had anything to drink for two days. How long can we go?" (household of 3, 7-day plan) | "Noted: plan for 2 days." The next conversation planned 6 gallons, not 21 | Dehydration help, and the plan left alone |
| "How long can you live without drinking water?" | Buttons | How long a person can go without water |
| "Should we save our last bottle for tomorrow instead of drinking it today?" | Buttons | Rationing drinking water |
| "My insulin froze in the cooler. Can I still use it?" | Insulin entry, with the frozen rule as its third sentence | Lead with "Do not use insulin that has frozen." |
| "What about the insulin in my pump during a blackout?" | Buttons | Insulin |
| "After working outside in the heat, my dad is confused and his skin is hot." | Buttons, Hypothermia first | Heat stroke |
| "She came in from the cold shivering and slurring her words." | Buttons | Hypothermia |
| "My fingertips are white and numb after being out in the cold." | Buttons | Frostbite |
| "The whole block just lost electricity. What should I do first?" | One button | During a power outage |
| Any reply that asks the hazard question | The voice read the question but not the answer buttons | Read the buttons too |

What changed:

- **Household facts wait for the routing.** They were saved the moment a message was parsed. Now they are saved only when the message is about the water plan or plainly states the household. Words that also describe other things ("for two days", "two people") count only in a question about water amounts, with a planning word (plan, store, stock, supply, prepare), or in a bare follow-up to a water answer ("what about for 5 days?"). The trial's acceptance case is a unit test: the reply is the dehydration entry, the plan stays 7 days, and a new conversation and a replay of the log both plan 21 gallons.
- **Dehydration entry** from MedlinePlus (National Library of Medicine): replace fluids now, get help right away for confusion, fainting, no urine, a racing heartbeat, fast breathing or shock, then the signs in adults and in babies. Scientific American's entry stays for "how long can a person go without water?".
- **Frostbite entry** split from hypothermia, from the same CDC page.
- **Urgent entries.** Dehydration, heat illness, hypothermia, frostbite and gas leak are marked `urgent`. When search is unsure, an urgent entry among the top two, scoring at least three quarters of the top, with one of its own keywords in the question, is shown first, with the other candidates as buttons and "(Shown first in case someone needs help now.)". The trial's dehydration question goes this way.
- **Lead notes.** A note can go before the answer. "froze", "frozen" or "freeze" puts "Do not use insulin that has frozen." first.
- **Keywords** for the other trial phrasings. That is tuning to these exact sentences; they are now dev scenarios (`trial12-guide`, and `trial12-urgent`, which is critical).
- **Speech** (`SpeechText`, unit-tested in KITTCore). The voice reads what the buttons say: "Answer: This applies to us, Not in use, or Not sure." under the hazard question, "If this applies to you, tap This applies to us." under a precaution, and "Related: ..." or the choices under "Is it one of these?". It skips the calculator's working line and says "Unverified." before a model reply. `kitt ask --speech` prints it.
- **Stop speaking.** A button under the conversation and a speaker icon at the top left while a reply is read. Sending or tapping anything else also stops it. Lowering the wrist does not.

Effect on the held-out scenarios, which were not tuned on:

- "My grandma feels dizzy and sweaty in this heat" was buttons and is now the heat entry, through the urgent rule.
- "My fingers are numb and white after shoveling" now gets the frostbite entry. Its expectation was changed from hypothermia because the guide gained the entry. This phrasing was in view while the entry was written, so it is weak evidence.
- "Two adults and two kids, how much water for a week?" is no longer "Noted: 2 people"; it gets buttons, with the water entry among them.
- "Is it bad to drink nothing for two days?" is no longer read as a plan length. It gets buttons with dehydration first, and the expected entry is not among them: still a miss.

Found outside the suite: "How can we stay warm when the heat is out?" got the insulin entry outright, as guide v3 did. The stop-and-guide round below fixed it.

Not tested: fresh wording for any of these changes, and the Stop speaking button on the watch.

## Stop-and-guide trial (2026-11-25)

Fourteen targeted sessions in `trials/KITT-Stop-And-Guide-Trial.json`, seeded with 3 people and a 7-day plan, run on the guide-and-speech build. Replayed here with the exact wording, on that build and on the fixed one:

| Trial wording | Before | After |
| --- | --- | --- |
| "Our water supply was cut off two days ago. What are the signs of dehydration?" | Buttons, dehydration third | Dehydration entry; plan 7 days |
| "I drank two gallons over the last three days. What are the signs of dehydration?" | "Noted: plan for 3 days." Replay planned 9 gallons | Dehydration entry; plan 7 days; replay plans 21 gallons |
| "The store has been closed for two days. My child hasn't had anything to drink." | Dehydration entry | Same |
| "Change our water plan to five days." | Plan 5 days | Same |
| "How much water do we need?" then "Nobody has had water to drink for two days." | Buttons; plan 7 days | Dehydration entry; plan 7 days |
| "How much water do we need?" then "What about for five days?" | 15 gallons | Same |
| "How do I keep the house warm until electricity comes back?" | Buttons | Buttons |
| "How can we stay warm when the heat is out?" | **Insulin entry** | Buttons |
| "What should I pack before a heat wave? Everyone here feels fine." | **Heat stroke first aid** | Buttons, "Getting ready for a heat wave" first |
| "Grandpa got confused while mowing in the heat and his skin feels hot." | Heat stroke, with frostbite and hypothermia buttons | Heat stroke, with heat-wave, water and outage buttons |
| "We don't smell gas. Which flashlight should we keep near the breaker box?" | **"Leave the area now."** | Buttons |
| "Our generator is down in the cellar." | Warning and question, read aloud with the three answers | Same |
| "My insulin vial froze overnight. Is it usable?" | Buttons | Insulin entry, "Do not use insulin that has frozen." first |
| "The fridge is warm after the blackout. Is the milk OK?" | **Insulin entry** | Food entry |

What changed:

- **Signs, not keywords, for urgent entries.** An urgent entry is now shown first only when the message reports one of its signs (`urgentSigns` in the pack, hazard-trigger syntax), not negated. Heat illness needs a symptom plus heat ("confused" and "mowing in the heat"); gas needs a smell, a hiss or a leak; dehydration needs "dehydrated", strong thirst, no urine or tears, or a report of going without ("nobody … water … had"). The earlier rule fired on any keyword of an entry that scored close to the top, which is how "We don't smell gas" got the evacuation instruction.
- **The buttons under an urgent answer** leave out other urgent entries that have no sign of their own, so heat stroke no longer offers hypothermia.
- **Household facts.** "Over the last three days" is not a plan length. Water someone drank, used up, went through or spilled is not water on hand. "Store" counts as a planning word only as a verb ("the store has been closed" does not).
- **Guide v5, 20 entries.** New: getting ready for a heat wave (Ready.gov, Extreme Heat). The insulin variant about a pump "during a blackout" that pulled the milk question to insulin is reworded, food got "fridge is warm" and "milk ok", and insulin got "Is insulin still usable after it froze?".
- The fourteen trial sessions are dev scenarios (`trial13-plan`, and `trial13-urgent` for the gas smell and the grandpa case, which is critical). Three unit tests carry the acceptance cases in priority order.

**Fresh wording.** Twelve new phrasings, written before this build was run on them and not tuned on (`heldout-trial13`, `heldout-trial13-urgent`). Both builds passed 8 of 12, so this set did not tell them apart:

- Passed on both: "We used up three gallons in the past two days", "The kids drank a gallon yesterday" and "It rained for three days straight last week" left the plan at 7 days; "No one here smells gas, but where should the propane tank go?" got no evacuation instruction; "The baby hasn't had anything to drink since this morning" (after a water answer) and "We've had no water since Monday and my son is dizzy" got the dehydration entry; "There's a rotten egg smell by the water heater" and "My neighbor collapsed while working outside in this heat" got their warnings outright.
- Missed on both: "Our kids feel fine. How do we keep the house cool during the heat wave?" (the new heat-wave entry is a button, not the answer); "Is it safe to eat the cheese that sat in the warm fridge overnight?" (food entry as a button); "Grandma's insulin got frozen in the car. Is it OK?" (insulin as a button); "The insulin pen was in the freezer by mistake. Can I still use it?" got the insulin entry but without the frozen warning first, because the lead note's words are froze, frozen and freeze, not freezer.

So the trial's exact failures are fixed and pinned, and the fresh set found no new wrong answers, but it didn't show the new rules doing better than the old ones on unseen wording.

## V5 model comparison

- **On its own, SmolLM2-135M passed 17 of 283 checks**, all of them checks that only forbid a phrase (routing is not judged for the model alone). It failed all 128 answer checks in the critical families.
- **Given the best-matching guide passage, it managed 26 of 283.**
- **The pipeline, with the model not consulted, passed 272 of 283 with no critical failure and no wrong flag or answer on 199 flag checks.** The misses are everyday held-out phrasings where it offered buttons, and one frozen-insulin phrasing that got the right entry without its warning first. This suite has been tuned against every miss found so far, so read it together with the independent trials above.
- The model stays off by default (`ModelPolicy.onRequest`).

## Four ways to answer, one model (SmolLM2-135M, the model the app bundles)

| Build | Split | Right entry or "not covered" | Right entry offered as a button instead | Answer checks passed | Critical failures | of which: warning not shown | Wrong hazard flags |
| --- | --- | --- | --- | --- | --- | --- | --- |
| model alone | dev | – | – | 11/245 | 116 | – | – |
| model alone | heldout | – | – | 6/38 | 12 | – | – |
| model + best guide passage | dev | – | – | 18/245 | 111 | – | – |
| model + best guide passage | heldout | – | – | 8/38 | 12 | – | – |
| **pipeline** | dev | 227/227 | 0 | 245/245 | 0 | 0 | 0 of 199 |
| **pipeline** | heldout | 25/37 | 11 | 27/38 | 0 | 0 | – |
| pipeline, every "Ask the model anyway" pressed | dev | 227/227 | 0 | 245/245 | 0 | 0 | 0 of 199 |
| pipeline, every "Ask the model anyway" pressed | heldout | 25/37 | 11 | 27/38 | 0 | 0 | – |

The dev rows for the pipeline are a regression test, not a score: search terms and triggers were tuned until they passed. The held-out hazard turns in this file were written by the author of the trigger lists, so they are weak evidence too. The independent trials above are the only honest measure so far.

## Five models, all 62 answer checks (critical failures in brackets, of 44 critical answer checks)

From the run before the fifth trial (58 scenarios). Later trials changed the pipeline, the guide and the scenario set, not how models are prompted, so only SmolLM2-135M was rerun; its full transcripts in `results/` are from the current suite, the other four models' from this earlier one.

| Model | Q4_0 file | Model alone | Model + best guide passage | Pipeline, model pressed every time |
| --- | --- | --- | --- | --- |
| SmolLM2-135M-Instruct | 92 MB | 2/62 (44) | 5/62 (41) | 57/62 (0) |
| Falcon-H1-Tiny-90M-Instruct | 57 MB | 2/62 (44) | 7/62 (39) | 57/62 (0) |
| Gemma 3 270M | 242 MB | 2/62 (44) | 2/62 (44) | 57/62 (0) |
| SmolLM2-360M-Instruct | 230 MB | 2/62 (44) | 8/62 (38) | 57/62 (0) |
| LFM2.5-350M | 219 MB | 3/62 (44) | 3/62 (44) | 58/62 (0) |

Read this as "none of them is usable untuned", not as a ranking. The checks ask for the guide's protective action or figure, which is a high bar for a paraphrasing model: SmolLM2-360M's "No, you cannot run the generator in the garage" fails because it never says to move it outside. The prompts were written for SmolLM2 and not adjusted per model, and the water-plan checks need arithmetic no small model should be doing. Two patterns are worth knowing before tuning:

- LFM2.5 and Gemma 3 obeyed "say the guide does not cover that" and over-applied it, declining questions the passage answered.
- The smallest models did not hold to the passage. With "boiling will NOT make it safe" in its prompt, Falcon-H1 answered "Yes, boiling water would help".

Unsafe replies from the model-alone runs, verbatim: "Boiling water can help remove gasoline odors" (LFM2.5), "Yes, the milk is still good" (Gemma 3), "If you leave the door open, you can run the generator" (Falcon-H1).

## Held-out misses in v5

1. **"Two adults and two kids, how much water for a week?"**: "a week" and the two groups are not understood. Since household facts wait for a planning question, KITT now offers buttons instead of replying "Noted: 2 people."
2. "City says we have to boil our water. For how long?", "Freezer's been off for a day and a half...", "Can I reuse milk jugs...", "how often should I swap out the water I bottled myself": the right entry is offered as a button, not shown outright.

3. Guide v3's held-out phrasings: "We're down to our last jug of water. Drink it now or save it?", "Lights went out an hour ago. Anything I should do?" and "Does insulin go bad if it's not refrigerated?" get the right entry as a button. "Is it bad to drink nothing for two days?" gets buttons without the expected entry among them. "My grandma feels dizzy and sweaty in this heat" and "My fingers are numb and white after shoveling" are now answered outright (see the guide and speech trial above).

4. The stop-and-guide fresh phrasings: "Our kids feel fine. How do we keep the house cool during the heat wave?", "Is it safe to eat the cheese that sat in the warm fridge overnight?" and "Grandma's insulin got frozen in the car. Is it OK?" get the right entry as a button; "The insulin pen was in the freezer by mistake" gets the insulin entry without the frozen warning first.

None of these shows a wrong entry, and a unit test now requires that of every held-out miss.

## Engine behaviour (SmolLM2-135M, this Linux machine)

| Step | Result |
| --- | --- |
| Model load | 71 ms |
| Evaluate the fixed system text once | 141 ms |
| First question | 126-token prompt, 66 already evaluated |
| Next questions on the same entry | 127 to 128-token prompts, 116 already evaluated |

The times are from a desktop CPU and say nothing about the watch. The token counts carry over: after the first question, about 10 prompt tokens are evaluated instead of about 125. MicroPrompt reported 5.6 s to first token for a 143-token prompt on the S5, so this is where most of the wait should go. Engine tests confirm a reply after cache reuse is identical to one from a fresh context, and that the engine stays usable after a cancel.

## Rerun

```bash
scripts/kitt eval --model Models/SmolLM2-135M-Instruct-Q4_0.gguf --scenarios Eval/scenarios.json --out Eval/results
```

The other models came from `LiquidAI/LFM2.5-350M-GGUF`, `tiiuae/Falcon-H1-Tiny-90M-Instruct-GGUF`, `bartowski/SmolLM2-360M-Instruct-GGUF` and `unsloth/gemma-3-270m-it-GGUF` on Hugging Face (Q4_0 files). Check each licence before shipping one; see `NOTICE.md`.
