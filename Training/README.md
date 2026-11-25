# Grounded answer training examples

These are draft supervised examples for KITT's optional language model. Each JSONL row contains the system prompt, a user message with a v7 guide passage and a question, and the desired assistant reply. The message format matches KITTCore's grounded prompt. The files can be read by a chat-format supervised fine-tuning loader. No weights or adapter accompany them.

| File | Examples | Behaviors |
| --- | ---: | --- |
| `train.jsonl` | 12 | Give the first action, keep the condition attached to a number, distinguish sanitation from drinking-water treatment, or decline when the passage lacks the answer |
| `valid.jsonl` | 6 | Test the same behaviors using different guide entries. Includes three questions the provided passage cannot answer |

The validation topics are hypothermia, gas leaks and do-not-drink notices. None appears as a training passage. Score both the action and the exception. A fluent answer that changes which water is safe, what kind of insulin a limit applies to, or when to call for help fails. An unsupported question should receive the app's existing fallback sentence.

These examples were written during a machine-assisted source review. A person should compare the passage and target against the cited entry before using the set for a release candidate. Keep these tiny sets for development, run any candidate against the unchanged base model on identical prompts, and use independently authored scenarios for a release decision. Changing a guide passage also calls for reviewing its training examples. The deterministic watch guide can use content updates without training an LLM.
