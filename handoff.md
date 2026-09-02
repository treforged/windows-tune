# Handoff: windows-tune

Newest first. Public repo - nothing machine-specific goes in this file.

Resume this desk on **Opus** (the manager default since 2026-09-02).
Earlier resume briefs said to start on Fable; they are out of date.

## 2026-09-01 - the menu run ELEVATED at last (queue 4, the safe options)

Tre cleared the UAC prompt, so the half of queue 4 that no automated session
could reach is now measured rather than assumed. Options 2, 3, 4, R and 1 were
pressed with `-Yes` against the real scripts from an ELEVATED prompt
(`ELEVATED=True` recorded in the run log before anything ran):

- **3 (network tune): `already at target - nothing to change`**, exit 0,
  `11 NIC properties checked`, **adapter NOT bounced**. This is the whole point
  of the change committed an hour earlier: before it, this option spent ~5 s
  offline to change nothing.
- **4 (power tune): `already at target - nothing to change`**, exit 0, active
  plan read as `Khorvie's PowerPlan`, minimum processor state already 0%.
- **2 (antivirus status)**: real reading - Tamper Protection ON, signatures
  0 days old, `REAL-TIME PROTECTION: ON`.
- **R**: `No revert files yet`. **1 (storage report)**: full report, 18 Steam
  titles / 550.1 GB, exit 0.
- **Every option exited 0, and revert files were 0 before and 0 after.** The
  working tree was clean afterwards. Nothing on this machine was changed by a
  run whose entire purpose was to change things - because there was nothing to
  change, and now the tool says so.

**6 was then pressed elevated too** and refused exactly as designed:
`06-remove-third-party-av.ps1 failed: Pass -Name or -ProductCode.` The menu
passes no arguments, so the script lists the registered AV products and stops
before touching anything - exit 0, still 0 revert files, nothing uninstalled.

Still not pressed: **5 (component store cleanup)**, held back deliberately - it
is the irreversible one and takes several uninterruptible minutes, so it wants
an explicit yes rather than a session's judgement.

One wrinkle it exposed, the same class as queue 6's follow-up: the menu printed
`This will change: UNINSTALLS a product you name` and then nothing was
uninstalled, because the script refuses without a name. The refusal message is
clear, so a user is not misled for long - but it is another case of the MENU
promising what only the SCRIPT can actually determine. That is the `-Preview`
follow-up already noted below.

Machine note, CORRECTED the same day. Option 2 shows a Surfshark registration
in Security Center beside Windows Defender, and this desk first read that as
"Surfshark is still installed". It is not. Checked directly:
`C:\Program Files\Surfshark` **does not exist**, there is no uninstall entry in
any of the three Uninstall hives, no service, and no process. What survives is
**14 orphaned Security Center provider keys** under
`HKLM:\SOFTWARE\Microsoft\Security Center\Provider\Av`, every one pointing at a
`wsc_agent.exe` that is gone. Defender reads `AMRunningMode Normal`,
`RealTimeProtectionEnabled True`.

The correction matters for the tool: **`06` cannot help here.** It clears a
registration by uninstalling the product that owns it, and there is no product
left to uninstall - it would correctly print `No installed product matching
'Surfshark'` and stop. Dead WSC registrations are a different problem than the
one this repo solves, and the repo should not pretend otherwise. Deleting those
keys is registry surgery on Security Center, outside the scope 01's header
claims ("touches no firewall, antivirus, service or policy setting"), so it is
not being folded into a script on a hunch.

Worth keeping as a lesson: **a Security Center registration is not evidence the
product is installed.** The README already says a stale entry "may linger until
reboot"; this machine shows they can linger indefinitely, and in bulk.

## 2026-09-01 - already at target means nothing is changed (queue 6 closed)

The gap measured yesterday is closed: on a tuned machine the scripts now say
`already at target - nothing to change` and stop, instead of performing a no-op
and, for option 3, a pointless ~5 s NIC bounce.

- **01** now reads every targeted value first through a PURE
  `Get-PendingNetworkChanges` (compares a snapshot to the targets, touches
  nothing). Zero differences -> message, exit 0, **no revert file, no writes, no
  bounce**. Otherwise it prints a `WILL CHANGE` table and applies **only** the
  settings that differ; the adapter is bounced only if a Tier B NIC property
  actually changed. A property the NIC lacks is not a change; an unreadable
  value IS one - "could not read it" never becomes "already correct".
- **04** reads DISM's own `Component Store Cleanup Recommended` line before
  spending several uninterruptible minutes reclaiming nothing. `-Force`
  overrides. A missing or unparseable line still runs the cleanup.
- **02** already had this; only the wording was normalised. **03** and **05**
  (the menu's read-only options) have nothing to change. **06** already reports
  `No installed product matching` and msiexec 1605 `Product was already absent`.
  No change made to either - said here rather than silently skipped.
- **Gate: 48 ok, exit 0, unelevated.** Stage 10 lifts the pure function out of
  01 with the Parser and CALLS it with synthetic states (the script throws on
  its admin check at line 1, so it cannot be dot-sourced); stage 11 asserts each
  changing script carries the message, and fails at a count of zero.
- **Proven it can fail, three ways:** renaming the function ->
  `stage 10 checked nothing`; dropping the Int32 masking -> the already-tuned
  case goes red; removing 02's message -> stage 11 goes red. All exit 1.
- **Pressed on real hardware.** A read-only copy of 01 (admin gate bypassed,
  hard `exit` before the first write) run against this machine: `already at
  target - nothing to change`, `11 NIC properties checked`, exit 0, revert files
  0 before and 0 after. The elevated write path is still queue 4's remainder.

Two PowerShell traps worth keeping. **`return ,$array` is not the way to return
a list here** - it hands the caller ONE object that happens to be an array, so
`@(...)` around the call is a 1-element array forever and `.Count -eq 0` can
never be true. The gate caught it; 01 would otherwise have never once said
"nothing to change". And **a DWORD of `0xFFFFFFFF` comes back from
`Get-ItemProperty` as Int32 `-1`**; casting that to `[uint32]` THROWS, on
precisely the already-tuned machine the feature exists for. Mask with
`[int64]$v -band 0xFFFFFFFFL` first.

Follow-up, not built: the MENU still prints its static `changes:` line and asks
y/N before the script gets to say "nothing to change". A `-Preview` switch the
menu could call first would close that, but it needs an exit-code protocol, a
stage 9 extension, and elevation to read anything - larger than the ask.

## 2026-09-01 - the menu offers no-op changes on an already-tuned machine

Measured on the reference box, every value the scripts target was ALREADY at
target: min processor state 0%, autotuning normal, RSS/RSC enabled,
NetworkThrottlingIndex disabled, all NIC properties set. Choosing 3 or 4 there
bounces the NIC for ~5s and changes nothing.

That is a product honesty gap, not a bug: a user who picks an option is told
what it WILL change, runs it, and cannot tell "applied" from "was already
correct". The repo's own standard - never show something you cannot stand
behind, an empty state should be honest - says a script should read the
current value first and report `already at target, nothing to change` instead
of performing a no-op and a NIC bounce. Not built: it is new scope Tre has not
asked for, and it touches all six scripts. Queued as item 6 rather than
started.

## 2026-09-01 - published head re-verified end to end from a stranger's side

No code change. `8905097` (the head carrying the splat fix and stage 9) was
checked the way a stranger meets it, not the way we meet it:

- **Clean clone from github.com**, gate run inside it: 36 ok, exit 0.
- **Live install path**, not `-FromZip`: `install.ps1` fetched from
  `raw.githubusercontent` (SHA-256 matches the published copy), run with the
  real zip download. Exit 0, 15 files, 0 `Zone.Identifier` streams, 0 temp
  `windows-tune-*` folders left behind, **0 content differences** against the
  published clone across all 15 files.
- **The installed copy then works**: its own gate is green, `R` exits 0, and
  `2` (`05 -Diagnose`) runs read-only unelevated. Zero revert files created.

Worth keeping, because it nearly shipped a false green: the first run of that
content diff **passed while comparing nothing**. The `-notmatch '\\.git\\'`
filter was mangled to an illegal regex (a Bash heredoc collapses `\\` to `\`
before PowerShell sees it), so `Where-Object` threw once per file, no file
reached the loop, and the script cheerfully printed `content diffs: 0`. It was
rewritten to a `-notlike "*\.git\*"` match, to **refuse to run** if fewer than
10 files survive the filter, and to prove itself by tampering with an installed
`NOTICE.md` and confirming it is detected before restoring it. A check that
passes everything is worth nothing - the same lesson stage 3e and stage 9 were
built on.

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

## Open with Tre as of 2026-09-01 20:40 (two offers, neither answered)

Both were put to him in chat and neither has a yes or a no yet. They are
recorded here because the session that offered them is being closed as a
duplicate, and an unanswered offer that lives only in a terminal is lost.

1. **Menu option 5, the component-store cleanup.** The only menu option never
   pressed. Deliberately NOT run: it deletes the superseded component versions
   that are the rollback data for updates already installed, so afterwards those
   updates can no longer be uninstalled. Nothing in use is removed and Windows
   runs the same cleanup itself on a schedule, but it is a one-way door and
   wants his explicit yes, not a session's judgement to close a queue. `04` now
   asks DISM whether a cleanup is even recommended first, so on this box it may
   simply report nothing to reclaim.
2. **The 14 orphaned Surfshark WSC keys** (see the correction above). Offered:
   export them to a `.reg` first so it is reversible, then delete. Two caveats
   given with the offer - it is registry surgery on Security Center, outside
   what any script in this repo does, and the keys may be ACL'd to
   TrustedInstaller, in which case the answer is to say so rather than start
   taking ownership of system keys. A reboot sometimes clears them for free.

Also told him, and worth repeating to whoever picks this up: what he still sees
"running in chrome" is the Surfshark browser EXTENSION. It is independent of
the uninstalled Windows app and is removed from Chrome's extensions page, not
by anything in this repo.

## Resume queue

1. [ ] Run `tests\preflight.ps1` on a second machine (any Windows 10/11 box)
   and note what differs - the whole repo has one data point. (A clean clone
   on the reference machine is green, 2026-09-01; that is not a second
   machine.)
2. [x] Admin check in `06-remove-third-party-av.ps1` - already present at
   lines 57-59, same shape as 02. No change needed (2026-09-01).
3. [x] `-Diagnose` in 05 works unelevated and the menu lists it as read-only
   (2026-09-01, see the top section - it also exposed the menu splat bug).
4. [~] Run the menu end to end by hand once, ELEVATED. Unelevated: all six
   options, done 2026-09-01. Elevated: options 1, 2, 3, 4 and R pressed with
   `-Yes` the same day (see the top section) - all exit 0, 3 and 4 both report
   `already at target`, 0 revert files before and after. **Only option 5 is
   left**, held back on purpose because the component-store cleanup is
   irreversible and takes minutes; it needs Tre's explicit yes, not a
   session's judgement. Option 6 was pressed elevated and refused correctly
   (`Pass -Name or -ProductCode.`), so 1, 2, 3, 4, 6 and R are all done.
6. [x] Make each script read the current value BEFORE offering to change it,
   and say `already at target - nothing to change` instead of performing a
   no-op. Shipped 2026-09-01 - see the top section. 01 rewritten around a pure
   `Get-PendingNetworkChanges`, 04 asks DISM first, 02 already did it, 03 and 05
   are read-only, 06 already reports "No installed product matching". Gate
   stages 10 and 11, 48 ok exit 0, proven red three ways.
5. [x] Gate stage: every key in a menu row's `args` hashtable is asserted to
   be a declared parameter of that row's script, by the Parser, nothing run.
   Shipped 2026-09-01 as preflight stage 9 - 36 ok exit 0 unelevated, and
   proven red three ways (two planted typos, and a renamed table). See the
   top section.

<!-- AUTO-SNAPSHOT:BEGIN - machine-written, replaced each compaction -->
## Auto-snapshot

_Written 2026-09-01 19:16 by handoff_hook. Everything below this heading is
machine-generated and replaced each time; put durable notes above it._

- **Branch:** `main`
- **vs upstream:** 0 ahead, 0 behind

- **Working tree:** clean

- **Recent commits:**

```
f245e82 docs(handoff): the menu offers no-op changes on an already-tuned machine (queue 6)
8ab8c9d docs(handoff): published head re-verified from a stranger's side; a false green caught in the checker
8905097 docs(handoff): resume this desk on Opus, not Fable
511cf5d docs(handoff): every menu option pressed unelevated - the skip path is proven
ec2b9da test(preflight): stage 9 - every menu args key is a declared parameter of its script
1287214 docs(handoff): queue 5 - static check that menu switch names exist in their target scripts
147ccdd docs(handoff): menu options 2 and 3 never ran (d82ca5d); 05 -Diagnose unelevated; queue 3 closed, 4 added
d82ca5d fix(menu): splat script arguments by name - options 2 and 3 never reached their scripts
```

<!-- AUTO-SNAPSHOT:END -->
