# Handoff: windows-tune

Newest first. Public repo - nothing machine-specific goes in this file.

Resume this desk on **Opus** (the manager default since 2026-09-02).
Earlier resume briefs said to start on Fable; they are out of date.

## 2026-09-02 - queue 1 dropped; the second-machine class tested WITHOUT one

Tre: *"remove that from to do list. im not going back to that pc any time soon.
just find a way to test on my pc if anything."* Queue 1 is closed as won't-do,
not done. What replaced it found a real user-facing bug the same hour.

**What a second machine would actually have caught, and now does not need to.**
Every parser in this repo reads the ENGLISH labels of `netsh`, `powercfg` and
`DISM` output - all of which Windows localizes. That is the largest
machine-to-machine difference this code has, and it is testable synthetically:

- `01`'s `Get-TcpGlobal` on German netsh text did not return empty, it THREW
  `[System.Object[]] does not contain a method named 'Trim'`.
- `02`'s `Get-MinState` fell through to `[Convert]::ToInt32('')` and threw
  `Index was out of range`.

Both aborted BEFORE changing anything, so they were fail-safe - but a stranger
on a German or Spanish Windows got a .NET error naming nothing they could act
on. Both now throw a message that says the scripts need an English-language
Windows and that nothing was changed.

- `tests/preflight.ps1` stage 13: `Get-TcpGlobal` is lifted and **CALLED** with
  synthetic German netsh output and must throw naming the cause; `Get-MinState`
  is checked **statically** for the same guard ahead of its `ToInt32`, because it
  shells out to powercfg and calling it here would only re-test this English
  machine. That limit is stated in the stage rather than papered over.
- Gate: **55 ok, exit 0**, unelevated.
- Proven red on purpose: weakening 01's message to not name the cause gives
  `Get-TcpGlobal threw on localized netsh but the message names no cause`,
  exit 1. And `Get-MinState` still returns 0% on this machine, so the English
  path is intact.

**How to test 'another machine' from this one, in order of fidelity:**
1. **Windows Sandbox** - a disposable clean Windows, built into Win 11 Pro.
   This box supports it (`HypervisorPresent=True`, virtualization on) but the
   feature is NOT installed; enabling it needs elevation and a reboot. Highest
   fidelity available without hardware: a stranger's default Windows.
2. **Synthetic parser tests** (stages 10, 12, 13) - lift a pure function out
   with the Parser and call it with the states another machine would produce.
   Free, instant, and it is what found the locale bug.
3. A non-admin account, and PowerShell 7 alongside 5.1.

## 2026-09-02 - 04 now checks the OUTCOME, not DISM's success line

Asked for after option 5 ran, succeeded, and freed nothing. `04` printed the GB
delta honestly but never compared DISM's post-analysis with its pre-analysis,
so `The operation completed successfully.` stood as the last word on a run that
reclaimed 0.03 GB and left the same 2 packages reclaimable.

- New `Get-StoreFacts` parses DISM's own verdict - reclaimable-package count and
  the Cleanup Recommended value - out of the text. After the cleanup, `04`
  compares before against after and says one of three things: the packages went
  down, **nothing was actually freed** (naming the unchanged count and pointing
  at a RESTART), or the output could not be read at all so the result is
  **UNKNOWN**. An unparseable read is never reported as success.
- `tests/preflight.ps1` stage 12 lifts `Get-StoreFacts` out with the Parser and
  CALLS it on four synthetic DISM outputs - real, nothing-to-reclaim, wide
  spacing, and unreadable. No DISM run, nothing on the machine touched.
- Gate: **52 ok, exit 0**, unelevated.

**The stage caught a bug in itself before it caught anything else, which is the
point of the rule.** Written through a bash heredoc, Python read the path
`scripts\04-...` as an OCTAL ESCAPE and wrote a literal 0x04 control character
into the filename, so `ParseFile` silently found nothing. Because the stage
fails when it finds no function rather than passing an empty check, it went red
immediately instead of printing green over a test that examined nothing. Build
check scripts with the Write tool, not heredocs - this is the second time this
exact shell behaviour has produced a false green in this repo.

Also worth recording: **Tre reports the installer ran on a SECOND PC and worked
well.** That is the first evidence from any machine but this one. It is the
install path, not the gate, so queue 1 stays open - but the repo is no longer
at literally one data point.

## 2026-09-02 - option 5 pressed: queue 4 is CLOSED, and DISM contradicted itself

The last unpressed option ran elevated in a time-boxed window. **All six menu
options have now been pressed against the real scripts from an elevated
prompt.** Queue 4 is done.

What option 5 actually did, which is not what "success" suggests:

- DISM BEFORE: component store 14.88 GB, 7.75 GB shared with Windows,
  **2 reclaimable packages, `Component Store Cleanup Recommended : Yes`**.
- `StartComponentCleanup` ran for ~115 s and reported
  `The operation completed successfully.`
- DISM AFTER: component store **still 14.88 GB**, **still 2 reclaimable
  packages**, **still `Cleanup Recommended : Yes`**. C: free went
  141.12 -> 141.15 GB, i.e. 0.03 GB, which is noise on a 141 GB volume.
- Exit 0, 0 revert files before and after, tree clean.

So the operation succeeded and changed nothing. The likely cause is that those
two packages cannot be removed without a restart, or at all without
`/ResetBase` - which the menu deliberately cannot pass. Not investigated
further; a reboot then a re-run would settle it.

**Follow-up worth doing (not done):** `04` prints the GB reclaimed honestly,
but it does not notice that DISM's own post-analysis is IDENTICAL to the
pre-analysis. It should compare the two and say "DISM still reports 2
reclaimable packages - the cleanup freed nothing; a restart may be required"
rather than leaving `The operation completed successfully.` as the last word.
This is the same family as the no-op gap already fixed for 01/02/04: a script
that reports the ACTION rather than the OUTCOME. Here the outcome check exists
(the GB delta) but is not compared against DISM's own verdict.

## 2026-09-02 - option 5's warning described a flag the menu cannot pass

The menu told users option 5 was `NOT reversible`. It is not, as written.

- Row 5 passes `args = @{}`, so `-ResetBase` is never set, and DISM's
  `/ResetBase` line in `04` is unreachable from ANY menu option. What the
  button actually runs is plain `StartComponentCleanup` - the same cleanup
  Windows schedules for itself, after which recent updates remain
  uninstallable. `04` also asks DISM whether a cleanup is recommended and
  skips when it is not.
- So the old label overstated the consequence of the button by describing a
  mode the button cannot reach. Corrected to say what it runs. Option 6's
  `NOT reversible` is left alone - uninstalling a product really is.
- Gate after the edit: **48 ok, exit 0**, unelevated.

Lesson worth keeping: **a warning that overstates is still a wrong warning.**
An exaggerated one teaches users to discount the accurate ones next to it, and
here it sat one line above a genuinely irreversible option.

Option 5 is STILL unpressed. Milder than advertised is not the same as
harmless, and it remains Tre's call.

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

**For the Desktop folder migration (checked 2026-09-02, so it is not
rediscovered): this desk is SAFE TO MOVE, but NOT safe to RENAME.**

- The repo hard-codes NO absolute paths. Every path is derived at runtime from
  `$PSScriptRoot` / `Split-Path -Parent` - in the scripts, the menu, the
  installer and `tests/preflight.ps1`. Verified by grepping all `.ps1`, `.cmd`
  and `.json` for `C:\Users` - zero hits outside this handoff file.
- **No scheduled task references windows-tune** (`schtasks /query /fo csv /v`
  filtered: 0 hits). Nothing to repoint there.
- Only three files outside the repo mention it, and all three are PROSE, not
  paths: a `--reason` example in `~/.claude/bin/automode_window.py:8`, a comment
  in `dispatch.py:140`, and `FREE-LLM-EXECUTORS.md`. None break on a move.
- **The one real hazard is a RENAME.** `claudecontext/execs.json` keys this desk
  by the folder NAME (`"windows-tune": {"name": "Gus", ...}`) with no path in
  it, and the SessionStart hook resolves the desk by the deepest folder segment
  of the cwd. Move the folder anywhere and Gus still resolves; rename it and the
  desk silently falls through to Sam. If the folder name changes, change the
  `execs.json` key and the `Desktop/CLAUDE.md` roster row in the same commit.


1. [-] Run `tests\preflight.ps1` on a second machine. **DROPPED 2026-09-02**
   at Tre's call - he is not returning to that PC. He does report the
   INSTALLER ran well there, which is the only evidence from another box.
   Replaced by testing the second-machine CLASS from this one: stage 13 now
   covers the locale fragility that was the largest real difference between
   machines, and it found two genuine bugs. Windows Sandbox is the higher-
   fidelity option if it is ever wanted - supported here, not installed,
   needs elevation and a reboot.
2. [x] Admin check in `06-remove-third-party-av.ps1` - already present at
   lines 57-59, same shape as 02. No change needed (2026-09-01).
3. [x] `-Diagnose` in 05 works unelevated and the menu lists it as read-only
   (2026-09-01, see the top section - it also exposed the menu splat bug).
4. [x] Run the menu end to end by hand once, ELEVATED. **CLOSED 2026-09-02 -
   all six options plus R have now been pressed elevated against the real
   scripts.** Unelevated pass: 2026-09-01. Elevated: 1, 2, 3, 4, 6 and R on
   2026-09-01 (3 and 4 both `already at target`, 6 refused correctly with
   `Pass -Name or -ProductCode.`); option 5 on 2026-09-02 with Tre's explicit
   yes, in a time-boxed auto-mode window - exit 0, 0 revert files before and
   after, and it reclaimed nothing (see the top section: DISM still reports
   the same 2 packages afterwards).
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

_Written 2026-09-02 11:34 by handoff_hook. Everything below this heading is
machine-generated and replaced each time; put durable notes above it._

- **Branch:** `main`
- **vs upstream:** 0 ahead, 0 behind

- **Uncommitted (4 file(s)):**

```
M handoff.md
 M scripts/01-network-tune.ps1
 M scripts/02-power-tune.ps1
 M tests/preflight.ps1
```

- **Recent commits:**

```
c0ca3d4 feat(04): compare DISM's own before/after verdict instead of trusting its success line
74370b2 docs(handoff): option 5 pressed - queue 4 closed, and DISM contradicted its own success
6cf7bbb fix(menu): option 5's warning described /ResetBase, which the menu cannot pass
bd94ab6 docs(handoff): refresh the auto-snapshot block
a62627a docs(handoff): carry the two unanswered offers forward before this duplicate tab closes
86d6302 docs(handoff): correct it - Surfshark is uninstalled; 14 orphaned WSC keys remain
2a670f9 docs(handoff): option 6 pressed elevated - refuses without -Name; only option 5 left
e0f557b docs(handoff): the menu pressed ELEVATED - options 3 and 4 report "already at target"
```

<!-- AUTO-SNAPSHOT:END -->
