# CLAUDE.md — windows-tune

Written 2026-09-03 by Vera (forged-glass) at Sam's request. Gus retired after
building `forged-agents`, so this repo has no live desk. Every path below was
checked against a real listing while writing, then re-checked by script.

`handoff.md` is what is true right now. Read it before you change anything.

## Where to start — read this row, then that file

| If the ask is about | Start in |
|---|---|
| The menu a person actually sees, and what each option runs | `windows-tune.ps1` |
| Network throughput, NIC properties | `scripts/01-network-tune.ps1` |
| Power plan and CPU behaviour | `scripts/02-power-tune.ps1` |
| Disk and storage reporting | `scripts/03-storage-report.ps1` |
| The component store, DISM, cleanup | `scripts/04-component-cleanup.ps1` |
| Defender handover, antivirus status | `scripts/05-defender-handover.ps1` |
| Removing a third-party antivirus | `scripts/06-remove-third-party-av.ps1` |
| Installing, or the double-click entry point | `install.ps1`, `Run-WindowsTune.cmd` |
| **Whether a revert actually reverts** | `tests/revert-credibility.ps1` and `tests/revert-drift.ps1`, with shared helpers in `tests/revert-lib.ps1` |
| Running a change without touching this machine | `tests/sandbox-run.ps1` |
| Licence, security policy, attribution | `LICENSE`, `SECURITY.md`, `NOTICE.md` |
| What is true right now, and what is open | `handoff.md` |

Remote is `https://github.com/treforged/windows-tune.git`.

## Which gate to run

`tests\preflight.ps1` is the gate. Run it before every commit and read its
`FAIL` lines — it prints one per problem and exits non-zero.

It presses the real code paths rather than describing them. Two examples worth
knowing, because they set the standard for anything you add:

- Stage 9 asserts the MENU TABLE is found in `windows-tune.ps1`, and fails with
  "stage 9 checked nothing" when it is not. A stage that silently matches zero
  rows is a stage that stopped testing, and it says so out loud instead.
- The antivirus check (menu 2 → `05 -Diagnose`) needs no admin, and the menu
  catches a script's throw and exits 0 anyway. So the gate checks the OUTPUT,
  not the exit code. An exit code is not evidence here.

`tests/revert-credibility.ps1` and `tests/revert-drift.ps1` answer a different
question from preflight: not "does it run" but "if this claims to have reverted,
did it". Run those when you touch anything that writes to the machine.

## What to paste into a free local model

A local model cannot explore this repo. Paste the WHOLE file — a fragment makes
it invent the surrounding code.

| Slice shape | Paste this |
|---|---|
| Change one tuning step | the single `scripts/NN-*.ps1` file, alone |
| Change the menu or add an option | `windows-tune.ps1` |
| A revert, or proving one works | `tests/revert-lib.ps1` plus the one `scripts/NN-*.ps1` it reverts |
| Add or change a gate stage | `tests/preflight.ps1` |
| Installer or entry point | `install.ps1` and `Run-WindowsTune.cmd` |
| Anything touching Defender | `scripts/05-defender-handover.ps1` and `scripts/06-remove-third-party-av.ps1` together — they interact |

**Do not let a free model near a revert path or anything that writes to the
machine.** Measured in forged-glass on 2026-09-03: `groq/gpt-oss-120b` drafted a
PowerShell 5.1 function with correct STRUCTURE and four rule violations it had
been given explicitly, including smart quotes that PowerShell treats as string
terminators. All four survive a parse. Three survive a run. This repo changes a
real machine, so the cost of that class of error is higher here than there.
`ollama` local (qwen3) timed out at 120s on the same prompt and produced nothing.

## Two facts that will otherwise cost you an hour

**"Applied" is not "changed".** Steps 01 and 02 read their values back after
writing, because a command that returns success has not proved it altered
anything. See `handoff.md`, 2026-09-03.

**This machine's component store is damaged, and 04 now REFUSES to clean a
damaged store** rather than reporting success over the top of it. DISM has
contradicted itself here before. Do not "fix" that refusal — it is the feature.
