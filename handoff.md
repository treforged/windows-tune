# Handoff: windows-tune

Newest first. Public repo - nothing machine-specific goes in this file.

Resume this desk on **Opus** (the manager default since 2026-09-02).
Earlier resume briefs said to start on Fable; they are out of date.

## 2026-09-01 - every menu option pressed unelevated; the skip path is proven

Queue 4 asked for a human to press 1-6 answering `n`. The half that needs no
admin is now done, against the REAL scripts, not stand-ins:

- **3, 4, 5 and 6 answering `n`:** each printed its own `changes:` line, then
  `Skipped.`, exit 0. Nothing ran.
- **1 (storage report) and 2 (antivirus status):** both ran to completion
  unelevated and produced real output. **R** printed `No revert files yet -
  nothing has been changed on this machine.` **Q** exits 0.
- **No side effects:** 0 revert files in `scripts\` afterwards, working tree
  clean. The skip path really does skip.

What is still NOT proven and still needs a person at the keyboard: the
ELEVATED run. Self-elevation goes through UAC, which no automated session can
click, so options 3-6 have never been pressed with `y` by a human since the
splat fix. That is the remainder of queue 4.

## 2026-09-01 - stage 9: the menu's argument names are checked against param()

Asked for (resume queue 5): a gate stage that catches a typo in the menu's
`args` hashtable statically, before a user presses the option. Shipped.

- `tests/preflight.ps1` stage 9 parses `windows-tune.ps1` with the PowerShell
  Parser (nothing is dot-sourced or run - the menu has a notice gate), finds
  the `$menu` assignment, and for each row asserts every `args` key is in the
  target script's `ParamBlock.Parameters`. **36 ok, exit 0, unelevated.**
- **Proven it can fail, three ways.** Planting `Diagnos = $true` on row 2 and
  `Floo = 50` on row 4 in a scratch copy: two FAILs naming the bad key AND the
  declared parameters (`declared: Diagnose, Repair, AddDevExclusions`),
  exit 1 - and no other stage noticed either typo, which is the whole point.
  Renaming `$menu` so the table is not found: `menu table not found in
  windows-tune.ps1 - stage 9 checked nothing`, exit 1. An empty scan cannot
  pass green.
- AST shape verified by RUNNING the parser, not by reading docs:
  `$assign.Right` is a `CommandExpressionAst` wrapping `[ordered]@{...}`, the
  table is the `HashtableAst` inside it, each row is
  `$pair.Item2.PipelineElements[0].Expression`. Two of three free-executor
  drafts got that nesting wrong; the first would have FALSE-GREENED (cast the
  PipelineAst as a HashtableAst -> null -> every row "takes no arguments").
- PowerShell trap worth keeping: `"menu $key: ..."` is a **parse error** -
  a colon after a variable name. `${key}` is the form. It would have taken the
  whole gate down, not just the stage.

Lesson worth keeping: **a static gate that finds nothing must fail, not pass.**
Every "assert all X" stage needs a counter and a Fail when the count is zero,
or a rename upstream silently turns it into a no-op that still prints green.

## 2026-09-01 - the menu never ran options 2 or 3; 05 -Diagnose needs no admin

Asked for (resume queue 3): a `-Diagnose` path in 05 that works unelevated so
the menu's read-only list can include it. Shipped, and it found a worse bug on
the way:

- **Menu options 2 and 3 had never worked.** `& $scriptPath @($item.args)` is
  an array expression, not a splat: the whole list landed as ONE positional
  `Object[]` and the script refused it before running. Options with an empty
  list happened to work, and the gate pressed only R and Q. An array splat is
  not the fix either - `'-Diagnose'` binds as a positional string, not the
  switch. The table now holds hashtables and the menu splats them by name.
- `05 -Diagnose` only reads, so the admin check is now `-Repair`-only (still
  thrown up front). Pressed from a normal prompt: `-Diagnose` reports fully,
  exit 0; `-Repair` refuses, exit 1, before touching anything. The menu,
  NOTICE and README now say 1, 2 and R work unelevated.
- 05 prints `REAL-TIME PROTECTION: UNKNOWN` when `Get-MpComputerStatus`
  returns nothing, instead of UNPROTECTED. No reading is not a reading.
- Gate: stand-in scripts in the scratch copy press the menu wiring for both
  argument shapes (`-Choice 1` -> `ARGS=0`, `-Choice 3 -Yes` -> `BOUNCE=True`),
  and stage 8 runs the real `-Choice 2` unelevated and says whether the gate
  itself was elevated. It is red on the splat bug, red on the array half-fix,
  and red on its own first regex (`elevated PowerShell` matched NOTICE.md,
  which the menu prints first) - all three seen this session. 30/30 green,
  exit 0, unelevated Windows PowerShell 5.1.

Lesson worth keeping: **a menu whose options are never pressed is a list of
labels.** The gate must call every option's wiring, with stand-ins where the
real script is slow or destructive.

## 2026-09-01 - gate verified against the published repo (d91c0c6, no code change)

Asked for: prove `tests/preflight.ps1` passes on a CLEAN CLONE of origin/main,
not the working tree, because strangers run what is published. Done, no code
changed:

- Fresh `git clone` of github.com/treforged/windows-tune into a temp folder,
  gate run there with Windows PowerShell 5.1: **27/27 ok, exit 0** at
  `d91c0c6` (the published head) and at `a81f62c`.
- `dcb722e` (SECURITY.md) was **red** when it went out - the pipe-to-iex grep
  hit the two Markdown files that describe the pattern - and `d91c0c6` fixed
  the grep to skip `.md` 25 seconds later. Nothing red is on origin/main now.
- The stranger path the gate cannot cover was walked by hand, exactly as the
  README says: `Invoke-WebRequest` of `install.ps1` from raw.githubusercontent
  (SHA-256 matches the clone's copy), run it with the LIVE zip download into a
  temp folder: exit 0, 15 files, 0 `Zone.Identifier` streams, 0 content
  differences against the clone, temp `windows-tune-*` folders 0 before / 0
  after, and the gate passes when run from inside the installed tree.
- The old "06 has no admin check" gap was stale: `06-remove-third-party-av.ps1`
  lines 57-59 carry the same `IsInRole(Administrator)` throw as 01/02/04/05,
  confirmed on origin/main with `git grep`. Removed from the gaps below.

- Follow-up the same session (`741e5b8`): `d91c0c6` had widened the pipe-to-iex
  gate to skip ALL Markdown, which is exactly where install instructions live.
  Back to an explicit allowlist (NOTICE, README, SECURITY, handoff); any new
  doc is scanned by default. Proven: a planted `INSTALL.md` fails the gate
  (exit 1, names the line), so does `docs/setup.md`, green once removed;
  fresh clone at `741e5b8` is 27/27 green.

Still only one machine has run any of this. A second box is the real next test.

## 2026-09-02 - installer, menu, notice (a81f62c)

Asked for: an easy install for other people's PCs plus a risk and privacy
notice. Shipped: `NOTICE.md`, `windows-tune.ps1` + `Run-WindowsTune.cmd`
(notice gate, I ACCEPT, self-elevation, y/N before every change, revert
list), `install.ps1` (zip download or `-FromZip`, unblocks, runs nothing),
README Install section, `tests/preflight.ps1` (all green - it presses the
gate and runs the installer offline into a temp folder).

Decision worth keeping: **no `irm <url> | iex` one-liner, ever.** It is the
ClickFix delivery pattern and Windows Defender flags the string itself
(Trojan:Win32/ClickFix.PM!MTB, severity 5) - it fired on the machine that
drafted this while the string was only inside a prompt. Download, read, run
is the documented path; NOTICE.md and README.md say why.

Known gaps, in order of what a user would hit:

- Only tested on the reference machine (Windows 11 Pro, desktop). No
  Windows 10 / Home / laptop / ARM run yet.
- `tests/preflight.ps1` cannot test elevation (UAC). The live download is
  not in the gate either, but it was walked by hand on 2026-09-01 (above).

## Resume queue

1. [ ] Run `tests\preflight.ps1` on a second machine (any Windows 10/11 box)
   and note what differs - the whole repo has one data point. (A clean clone
   on the reference machine is green, 2026-09-01; that is not a second
   machine.)
2. [x] Admin check in `06-remove-third-party-av.ps1` - already present at
   lines 57-59, same shape as 02. No change needed (2026-09-01).
3. [x] `-Diagnose` in 05 works unelevated and the menu lists it as read-only
   (2026-09-01, see the top section - it also exposed the menu splat bug).
4. [~] Run the menu end to end by hand once, ELEVATED. The unelevated half is
   done (2026-09-01, see above): all six options pressed against the real
   scripts, `n` skips 3-6 cleanly, 1/2/R/Q work, zero side effects. What is
   left needs a human to clear the UAC prompt - no automated session can.
5. [x] Gate stage: every key in a menu row's `args` hashtable is asserted to
   be a declared parameter of that row's script, by the Parser, nothing run.
   Shipped 2026-09-01 as preflight stage 9 - 36 ok exit 0 unelevated, and
   proven red three ways (two planted typos, and a renamed table). See the
   top section.

<!-- AUTO-SNAPSHOT:BEGIN - machine-written, replaced each compaction -->
## Auto-snapshot

_Written 2026-09-01 06:54 by handoff_hook. Everything below this heading is
machine-generated and replaced each time; put durable notes above it._

- **Branch:** `main`
- **vs upstream:** 0 ahead, 0 behind

- **Working tree:** clean

- **Recent commits:**

```
1287214 docs(handoff): queue 5 - static check that menu switch names exist in their target scripts
147ccdd docs(handoff): menu options 2 and 3 never ran (d82ca5d); 05 -Diagnose unelevated; queue 3 closed, 4 added
d82ca5d fix(menu): splat script arguments by name - options 2 and 3 never reached their scripts
a89170a docs(handoff): record the pipe-to-iex allowlist fix (741e5b8) and its failing-gate proof
741e5b8 test(preflight): pipe-to-iex gate back to an explicit allowlist, not a blanket .md exemption
deff4b2 docs(handoff): gate verified on a clean clone of origin/main; 06 admin-check gap was stale
d91c0c6 test(preflight): the pipe-to-iex grep skips Markdown - docs are allowed to name the pattern they warn about
dcb722e docs(security): SECURITY.md - how to report, what counts, what the repo does to protect itself
```

<!-- AUTO-SNAPSHOT:END -->
