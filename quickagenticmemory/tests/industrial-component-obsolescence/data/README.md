# Data purpose

This directory contains the complete synthetic dataset for the industrial component-obsolescence proof. No customer, machine, supplier, or production data is used.

| Path | Contents |
| --- | --- |
| [`knowledge/`](knowledge/) | Linked `.md` knowledge record: components, machine families and variants, I/O mappings, PLC blocks, parameter sets, change/service records, and FAT/SAT specifications. |
| [`questions/questions.json`](questions/questions.json) | Eight versioned retrieval questions with query-derived terms, status filters, concept-level top-k budgets, and maximum hop counts. |
| [`gold/gold.json`](gold/gold.json) | Human-authored required concepts, exclusions, states, and bounded `LINKS_TO` paths used only for scoring after retrieval. |

Every retrieval term must occur in its question text. The first term identifies the focus entity;
the remaining terms express requested result types and scope without naming an answer UID. Both
arms receive the same terms, lifecycle filter, derived result-type scope, and concept budget.

The runner never uses gold concepts or paths to choose candidates. Gold truth is evaluated only after both retrieval arms have returned their evidence.

The similar `IOL-M8S` installation and deprecated `SB-2024-11` bulletin are intentional distractors. They make alias collision and lifecycle mistakes measurable instead of relying on a corpus where every near match is correct.
