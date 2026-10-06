# Context hypothesis gate

Offline gate for the Positronic semantic context compiler experiment (#426, GNO-CTX-006).
Every arm runs through the deterministic fixture seam. No provider is contacted.

## Decision

**SIMPLIFY**. Flat leaf carry reaches 100% recall at 543 characters and beats raw history 93%, but the hierarchical cover is identical (543 characters). Keep the flat carry; drop the hierarchy from the epic.

## Numbers

| Arm | Recall | Checks | Curator calls | Input tokens | Output tokens | Projection chars |
| --- | --- | --- | --- | --- | --- | --- |
| raw-history | 93% | 13/14 | 0 | 1117 | 0 | 4470 |
| pk-compression | 50% | 7/14 | 0 | 68 | 0 | 273 |
| one-shot-summary | 36% | 5/14 | 1 | 220 | 0 | 881 |
| incremental-flat | 100% | 14/14 | 43 | 135 | 0 | 543 |
| hierarchical-cover | 100% | 14/14 | 43 | 135 | 0 | 543 |

## Recall by obligation

| Obligation | raw-history | pk-compression | one-shot-summary | incremental-flat | hierarchical-cover |
| --- | --- | --- | --- | --- | --- |
| back-reference | 100% | 0% | 0% | 100% | 100% |
| concurrent-root | 100% | 0% | 0% | 100% | 100% |
| correction | 100% | 0% | 0% | 100% | 100% |
| exact-value | 100% | 100% | 50% | 100% | 100% |
| fact | 100% | 100% | 100% | 100% | 100% |
| malicious-tool-text | 50% | 50% | 50% | 100% | 100% |
| negative-constraint | 100% | 100% | 100% | 100% | 100% |
| open-item | 100% | 0% | 0% | 100% | 100% |
| self-maintenance | 100% | 0% | 0% | 100% | 100% |
| supersession | 100% | 100% | 0% | 100% | 100% |
| tool-evidence | 100% | 0% | 0% | 100% | 100% |
