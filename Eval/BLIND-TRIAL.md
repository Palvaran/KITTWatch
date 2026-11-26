# Blind trial: hurricane and three-day outage

A fixed set of questions from someone who hasn't read the guide, scored on the build before
a change and the build after it. It answers one question: did the change help with wording
nobody tuned against?

## Rules

- **The writer hasn't read the guide** (the pack, `scenarios.json`, the trial files, or this
  project's transcripts). Ask them for 30–40 questions they'd actually ask during a hurricane
  or a three-day power outage, in their own words, including follow-ups. Situations described
  without their official names are the point: "the lights went out overnight and the milk
  feels warm", not "food safety during a power outage".
- **The questions stay away from whoever edits the guide's phrasings** until both builds
  are scored. Keep them outside this repository, in `~/KITT-blind/`. Don't paste them into a
  chat with the editor.
- **The baseline is frozen.** `Eval/baselines/guide-pack-v7.json` is the guide as it was
  before the phrasing change (SHA-256 `b6c7b891…e680e7dc`). Comparisons that change only the
  pack use it with the current `kitt`. Run the baseline before any change to KITT's code
  lands (the water-advisory question is the next one), so the baseline is the code as it was too.
- **Asking the needed question counts as success.** If the answer depends on something the
  user didn't say (which kind of water notice), a reply that asks for it is right, and one
  that answers outright is a guess.
- **A question the guide can't answer goes on the expansion list.** Don't add its words to a
  neighbouring entry: that only makes the wrong answer easier to find.
- **Once a trial question is used to fix KITT, it becomes a regression test** (a dev family
  in `scenarios.json`). The next comparison needs new questions from someone new.

## Steps

1. **Write.** The writer puts the questions in `~/KITT-blind/questions.txt`: one per line,
   a blank line between conversations (lines together are follow-ups), `#` for comments.

   ```text
   The lights went out overnight. Is the milk okay?
   What about the cheese?

   The city sent a water alert. Can the dog drink from the tap?
   ```

2. **Make the scenario file and freeze the baseline replies.**

   ```bash
   scripts/kitt trial ~/KITT-blind/questions.txt --out ~/KITT-blind/trial.json --name blind-hurricane-1
   scripts/kitt eval --pack Eval/baselines/guide-pack-v7.json --scenarios ~/KITT-blind/trial.json --out ~/KITT-blind/baseline
   ```

   `~/KITT-blind/baseline/no-model.md` is the record of what the old build said, with the
   buttons it offered.

3. **Label.** Someone who knows the guide (not the phrasing editor) adds an `expect` to each
   question in `trial.json`, answering the three questions:

   | Did the guide contain the answer? | Did it need one more fact first? | Label |
   | --- | --- | --- |
   | Yes, entry X | No | `"expect": {"entries": ["X"]}` |
   | Yes, entry X | Yes: which notice, whether it's running, how many people | `"expect": {"entries": ["X"], "asks": true, "asksFor": "notice"}` |
   | No | – | `"expect": {"notCovered": true}` |

   `entries` can list more than one entry when either would answer it. Leave a follow-up
   unlabelled if it only sets up the next question.

   `asksFor` names the fact: `notice` (which water notice), `hazardUse` (whether the
   generator or grill is running there), `people`, `planDays` or `storedWater`. Only a
   question about that fact earns credit; asking for the household size when the notice is
   missing does not. `asks: true` stays beside it so the frozen pre-clarification evaluator
   in `KITT-Blind-Trial-Freeze.zip` still reads the labels. For a water question where the
   notice is unknown, list every notice entry: `water.advisory.boil`,
   `water.advisory.do-not-drink`, `water.advisory.types`.

4. **Score both builds** on the labelled file:

   ```bash
   scripts/kitt eval --pack Eval/baselines/guide-pack-v7.json --scenarios ~/KITT-blind/trial.json --out ~/KITT-blind/before
   scripts/kitt eval --scenarios ~/KITT-blind/trial.json --out ~/KITT-blind/after
   ```

   Each prints an outcome table:

   | Outcome | Meaning |
   | --- | --- |
   | Answered | the expected entry, outright |
   | Asked the needed question | the expected entry, and it asked for the missing fact |
   | Answered without asking | the expected entry, but it should have asked first: a guess |
   | Asked about something else | it asked for a fact, but not the one the answer depends on |
   | Offered as a button | not answered outright; the expected entry was one tap away |
   | Said "not covered", as expected | the guide has no answer and KITT said so, without offering topics |
   | Warning shown instead | a hazard warning as a precaution; the expected entry not shown or offered |
   | Wrong answer | a different entry outright, or an answer where the guide has none |
   | Missed | nothing useful: no entry, and the expected one not among the buttons (or topic buttons where the guide has no answer) |

   The report's **Not in the guide** section is the expansion list.

5. **Record** the two tables in `Eval/RESULTS.md`, then move the questions that were fixed
   into `scenarios.json` as a dev family.
