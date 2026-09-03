# Handoff: windows-tune

Newest first. Public repo - nothing machine-specific goes in this file.

Resume this desk on **Opus** (the manager default since 2026-09-02).
Earlier resume briefs said to start on Fable; they are out of date.

## 2026-09-03 - measuring context: megabytes cannot do it (machine-level, for Sam)

Not a windows-tune change. Recorded here because this desk did the measurement
and a cold session would otherwise re-derive it.

- **Transcript file size is NOT a proxy for context.** Across the 14 largest
  transcripts on this machine, bytes per token runs 16.0 to 130.5 - an **8.2x
  spread**. A 7.96 MB session held 941,635 tokens while a 17.38 MB session held
  909,779. The bigger file held less context.
- **The real number is already recorded.** Every assistant line carries
  `message.usage`, and `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` is the context that request carried.
- `claudecontext/context_size.py` reads it. Installed by Sam, sha verified, three
  modes live-tested: list, `--compactions`, and `--log` for a Stop hook.
- **No threshold exists yet, and none was invented.** Only **2** compaction
  events exist on this disk, both `trigger=manual`, at pre-token counts of
  **209,889** and **666,655**. Neither measures where AUTOMATIC compaction fires.
  The highest context seen with no compaction at all is **946,249 tokens on a 1M
  window**.
- **The sample is biased toward interactive desks.** A Remote Control session
  writes no transcript to this disk. Any future number must say so.
- `Forgenta Token Usage` now runs nightly at 23:30, so the earliest honest
  threshold is about **2026-09-10**. That is a wait for DATA, not for effort.

## 2026-09-03 - "applied" is not "changed": 01 and 02 now read their values back

Tre's standing requirement across every desk today: evidence must be a LIVE test,
not a green build or a log line. A tuning script that "applied" is not a tuning
script that CHANGED the machine - read the value back off the system, not out of
your own script.

`01` printed an `=== AFTER ===` block and `02` printed the new percentage. Both
were displays, not checks: every command in them can report no error and change
nothing, and a settings write that silently did not take looks exactly like one
that did. `05` already read its exclusions back - that was the 2026-09-01 fix -
so this brings 01 and 02 up to the same standard.

- `01` now has a `=== VERIFY (read back from the system, not from this script) ===`
  block: autotuninglevel, rss, rsc, NetworkThrottlingIndex, DNS and
  AllowComputerToTurnOffDevice are each read back and compared. Tier B is exempt
  ON PURPOSE - it is staged until the adapter bounces, so flagging it would be a
  false alarm.
- `02` compares `Get-MinState` against the floor it asked for and says which.

**The live test found a bug in the checker itself, which is the whole argument
for live tests.** The first version counted an UNREADABLE value as a change that
did not take. Running it against this machine reported
`AllowComputerToTurnOffDevice` as failed - when the truth was that
`Get-NetAdapterPowerManagement` needs elevation and the check was running without
it. That would send someone chasing a change that was fine. Unreadable and
not-applied are now counted and worded separately: "could not read either way,
and it will not guess."

Live evidence, read off this machine rather than out of the script:

    ok  autotuninglevel = normal
    ok  rss = enabled
    ok  rsc = enabled
    ok  NetworkThrottlingIndex = 4294967295
    ok  DNS = 1.1.1.1, 1.0.0.1
    UNREADABLE AllowComputerToTurnOffDevice   (unelevated harness only)
    -> notApplied=0 unreadable=1
    02: minimum processor state now 0%, which is what 02 sets.

Then read again ELEVATED, which is how `01` actually runs:

    elevated=True
    AllowComputerToTurnOffDevice = [Disabled]      <- 01's target

So all SIX Tier A values are confirmed against the live machine, and the single
UNREADABLE was an artefact of the harness rather than anything about the tune.
That is the distinction the checker now makes for the user too - it reported
"could not read either way" rather than "did not apply", which was the truthful
answer at the privilege level it had.

- `tests/preflight.ps1` stage 17 lifts `Confirm-Applied` and CALLS it with a
  match, a mismatch and a blank, asserting the blank lands in `unreadable` and
  NOT in `notApplied`; then checks statically that the verify block sits AFTER
  the changes it checks. Gate: **72 ok, exit 0**.

## 2026-09-03 - this PC's component store is damaged, and 04 now refuses to clean a damaged store

Tre approved enabling Windows Sandbox (queue 1's replacement - a genuinely clean
Windows to test against). Enabling it FAILED:

    Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
    -> The component store has been corrupted.

Read-only diagnosis, elevated, nothing repaired and nothing changed:

    DISM /Online /Cleanup-Image /CheckHealth  -> The component store is repairable.
    DISM /Online /Cleanup-Image /ScanHealth   -> The component store is repairable.

CBS.log names exactly one file:

    Unable to repair payload file 'SgrmEnclave.dll' for component
    amd64_security-octagon-enclave_..._10.0.26100.1150 from backups directory.
    A backup file may not exist or may be corrupt. Falling back to WU.
    Attempting to mark store corrupt with category 'CorruptPayloadFile'

So: repairable, one payload file, and the repair-from-backups path could not find
it. `DISM /Online /Cleanup-Image /RestoreHealth` was approved and **run, and it
worked**:

    The restore operation completed successfully.   exit 0
    02:30:50 -> 02:46:30, about 16 minutes, from Windows Update, no reboot.

Verified by RE-READING the state rather than by trusting that line - the same
rule that caught option 5 reporting success while reclaiming nothing:

    DISM /Online /Cleanup-Image /CheckHealth
    -> No component store corruption detected.     exit 0

**And it was still not fixed.** That reading was true at that instant and it was
not enough. Enabling Sandbox again one minute later failed with the SAME error,
and `CheckHealth` then went back to `The component store is repairable`. The
verification was honest and the conclusion drawn from it was premature: DISM's
verdict is a FLAG, and RestoreHealth clears the flag. Only a real servicing
transaction re-tests the thing itself, and it re-set the flag immediately.

**What RestoreHealth actually did - it MOVED the fault.** Before, the component
folder held `SgrmEnclave_secure.dll` and the error named `SgrmEnclave.dll`. After,
it holds `SgrmEnclave.dll` (546,824 bytes, written 02:44:49 during the repair) and
the error names `SgrmEnclave_secure.dll`. Same defect, other file:

    Regenerating payload files from delta files on component:
      amd64_security-octagon-enclave_..._10.0.26100.1150
    (F) Unexpected compression state. CompressedFileType for
      ...\SgrmEnclave_secure.dll is 0, ComponentFileFlags : LZMS: 3
    Attempting to mark store corrupt with category 'CorruptPayloadFile'
    STATUS_SXS_COMPONENT_STORE_CORRUPT in
      ComponentStore::CRawStoreLayout::RecursivelyRegenerateComponentPayload
    Failed to decompress OC Content. [0x80073712 ERROR_SXS_COMPONENT_STORE_CORRUPT]

So the component needs both files, each is stored UNCOMPRESSED where the manifest
says LZMS, and delta regeneration fails on whichever one is present. Restoring
one appears to displace the other. Running RestoreHealth again is retrying a
command that already failed in a way it cannot fix - the antipattern, not the fix.

No reboot is pending (`RebootPending`, `RebootRequired`, `RebootInProgress`,
`PackagesPending` all False). `Containers-DisposableClientVM` is still `Disabled`.
This is past a routine repair and is parked for a decision rather than improvised
at 03:00.

**Worth noting for the product:** 04's new health gate behaves exactly right on
this genuinely damaged machine - `CheckHealth` reads `repairable`, so option 5
would STOP and print the repair instructions instead of running a cleanup that
cannot help. The gate was written from this machine's failure and is now
confirmed against it.

**Did option 5 cause it? No, and the disk says so rather than the reasoning.**
The suspicion was fair: the damaged component is version `10.0.26100.1150` on an
image at `10.0.26200.9168` - a SUPERSEDED version, which is exactly what
`DISM /StartComponentCleanup` prunes, and exactly what option 5 ran on
2026-09-02. Three findings kill it:

- **The WinSxS `Backup` directory was last written 2026-09-01 00:10:55.** The
  cleanup ran 2026-09-02 00:20:29. Removing an entry from an NTFS directory
  updates that directory's mtime, so a prune that deleted a backup payload would
  have stamped it 09-02. It reads 09-01, a day earlier. That cleanup never
  modified the backups directory at all.
- **The cleanup ran for 30 seconds** (00:20:28 to 00:20:58) and reclaimed
  0.03 GB. A prune that removed almost nothing cannot have removed the last good
  copy of anything.
- **The first error is not a missing file.** It is
  `Unexpected compression state. CompressedFileType for ...SgrmEnclave.dll is 0,
  ComponentFileFlags : LZMS: 3` - a payload whose compression state does not
  match its manifest. A prune does not produce that shape; an interrupted or
  interfered-with servicing write does. The "unable to repair from backups" line
  that made this look like a deletion is the repair ATTEMPT failing, not the
  cause.

The corruption was first marked `2026-09-03 02:22:07` - during the
Enable-WindowsOptionalFeature attempt above. It was latent until something
finally looked.

**A second hypothesis, not oversold.** That backup directory's last write sits
about fifteen minutes before `surfshark-av-off-revert.ps1`'s capture stamp of
`2026-09-01T00:26:14` - the window in which net-tune was retiring Surfshark's
antivirus and handing protection back to Defender. `SgrmEnclave` is System Guard
Runtime Monitor, a SECURITY component. An antivirus transition across a servicing
operation is a more plausible disruptor of a security payload than a 30-second
prune the next day. Close timestamps are not causation and this is not a
conclusion; it is recorded so the next person has it.

**04 now asks about HEALTH before it cleans anything.** A cleanup cannot help a
damaged store and DISM will still print `The operation completed successfully`,
so a stranger with this exact problem currently gets a success message from
windows-tune and no idea their PC needs repair. `Get-StoreHealth` reads DISM's
`/CheckHealth` verdict, and on Repairable or Corrupt the script STOPS without
changing anything and prints the `RestoreHealth` command, what it needs, and the
fact that a damaged store also blocks adding Windows features and can make
updates fail in ways that look like something else. Unreadable output is
`Unknown` - never "healthy" - and only warns, so a non-English Windows is not
locked out of the option.

- `tests/preflight.ps1` stage 15: `Get-StoreHealth` is lifted by the Parser and
  **CALLED** with six synthetic DISM outputs, including the exact wording this
  machine produced today, and German text that must come back `Unknown`. Then 04
  is checked statically for the STOP sitting BETWEEN the verdict and the cleanup -
  a verdict nothing acts on is not a gate.
- Gate: **65 ok, exit 0**, unelevated.
- Pressed with REAL data: this machine's actual `/CheckHealth` output fed through
  04's own function returns `Repairable`, so 04 would stop here today.
- Proven red on purpose: weakening the parser so `repairable` reads as `Unknown`
  gives `a damaged store would be cleaned anyway`, exit 1; renaming the STOP so
  the order check cannot find it also exits 1.

**Operational note for whoever runs a long elevated job from a session here.**
`Start-Process -Verb RunAs -Wait` survives its caller: when the harness killed the
wrapper on a timeout, `Dism.exe`, `DismHost.exe`, `TrustedInstaller.exe` and
`TiWorker.exe` were all still running and the repair carried on. Check
`tasklist` before concluding a repair died, and NEVER start a second DISM to
"retry" - they contend for the same servicing lock and that is how a recoverable
store becomes a stuck one. Watch the transcript for its completion marker
instead.

**The sandbox harness's mapping rules ARE gated, even though the harness itself
cannot run yet.** The one way a disposable VM can reach back into this machine is
a writable host mapping, so `New-SandboxConfig` was pulled out into a function
purely so stage 16 can lift it and CALL it with planted folder names, then assert
the resulting XML: the repo mapped READ-ONLY, exactly ONE writable mapping and it
is the out folder, and networking off. Gate: **69 ok, exit 0**. Proven red three
ways - making the repo mapping writable, turning networking on, and adding a
third writable mapping of the user profile all fail the gate, the last one with
`2 writable host mapping(s) - every extra one is a way out of the sandbox onto
this machine`.

**`tests/sandbox-run.ps1` is written and cannot yet be proven END TO END.** It runs the
installer, the gate, the menu's read-only path and `05 -Diagnose` inside a
disposable clean Windows - repo mapped READ-ONLY, one writable folder for the
result, networking DISABLED so the install is proven from a local zip. `-RunTune`
additionally presses option 1 for real, which is the first place this repo's
elevated WRITE path could ever be run without touching somebody's actual PC. It
currently refuses with a clear message saying Sandbox is not installed and how to
enable it, which is the honest empty state and all that can be claimed until the
store is repaired and the machine rebooted.

## 2026-09-02 - dead paths after the folder move, and a gate so they cannot come back

Gus also owns **net-tune** from today (Sam, 2026-09-02) - same domain, same
audience, same "runs on other people's machines" risk. net-tune is NOT a git
repo, so its fixes live only on disk; this file is the record.

Mona's `claudecontext/sweep_dead_paths.py` found four hardcoded paths across the
two folders, all left behind when everything moved one level down into
`Desktop\TRE-Forged\`. All four are now derived at runtime; none was replaced
with a new absolute path, because that just breaks again on the next move.

- `net-tune/remove-excl.ps1` wrote its report to `Desktop\net-tune\` - now
  `Join-Path $root 'excl-after.txt'`.
- `net-tune/test-05.ps1` ran `Desktop\windows-tune\scripts\05-defender-handover.ps1`
  and wrote beside it - now the sibling folder of `$PSScriptRoot`, and it
  **throws naming the path it looked for** if that script is not there. It
  elevates and changes Defender settings, so a wrong target must fail loudly
  rather than quietly do nothing.
- `windows-tune/install.ps1:32` pointed at `C:\tools\windows-tune`. This one was
  **documentation, not code** - an `.EXAMPLE` line in the comment-based help -
  but it told a stranger to install into a folder that does not exist and needs
  admin to create. Now `$env:LOCALAPPDATA\windows-tune-test`.
- Known false positive, left alone: `net-tune/surfshark-uninstall.ps1:53` checks
  for `C:\Program Files\Surfshark`, whose ABSENCE is the desired state.

**The guard-before-the-call rule.** `Split-Path` and `Join-Path` THROW on an
empty string, so `$root = Split-Path -Parent $x` followed by `if (-not $root)`
is defensive-looking code that can never fire - the line above it already threw,
on the empty/missing case, which is the degrade path least likely to be
exercised and most likely to hit a stranger. Both net-tune scripts check
`$PSScriptRoot`, then `$MyInvocation.MyCommand.Path`, **before** calling
`Split-Path` on either, and throw a sentence a human can act on.

**`tests/preflight.ps1` stage 14** now fails the build on any absolute
machine-specific path (`X:\Users\...`, `X:\tools\...`) in a repo `.ps1`/`.cmd`.
`C:\Windows` and `C:\Program Files` are real fixed locations and are not flagged.
A scanner with nothing planted for it reports clean forever, so the stage ends by
handing its own detector a planted bad path and failing if it matches nothing.

- Gate: **57 ok, exit 0**, unelevated.
- Proven red on purpose: a dead `Desktop\windows-tune\planted.log` added to a
  scratch copy of `01-network-tune.ps1` gives
  `FAIL hardcoded absolute path in 01-network-tune.ps1:303`, exit 1.
- net-tune evidence (neither script can run end to end here - one strips Defender
  exclusions, the other elevates): `test-05.ps1` run against a stand-in `05` in a
  temp sibling layout reached it with `Repair=True AddDevExclusions=True` and
  wrote `test-05.out` beside itself; with the sibling removed it threw naming the
  path it wanted. `remove-excl.ps1` with the Defender cmdlets stubbed resolved its
  output to its own folder. Both throw the folder-resolution message when their
  body is run with no script file behind it.
- The sweep now reports **0 dead paths in either folder**.

**Correction to the migration note below:** "the repo hard-codes NO absolute
paths" was not true - `install.ps1`'s help example was one. Stage 14 is why that
claim is now checked by a gate instead of by a grep somebody remembers to run.

**And the gap that closed it, 2026-09-03: are the revert's values the RIGHT
values?** `net-tune/tests/revert-credibility.ps1` reads a third source - what the
TUNE itself sets - so a claim is no longer merely "different from the machine"
but positively credible: the tune set Y, the machine holds Y, so the revert
holding X is exactly right. 20 claims against 21 targets: 19 credible, 1 MISSING
(the Surfshark service that no longer exists), nothing else. A revert that would
restore the TUNED value undoes nothing and exits 1; drift and not-applied are
reported and exit 0, because only a human knows why a value moved. Targets are
read through the AST rather than by text, and a plant proves why - `net-tune.ps1`
contains the same netsh line twice, once as a command it runs and once inside a
string it writes into the revert file, and a grep cannot tell those apart. Six
plants, one per verdict branch. Detail in `net-tune/handoff.md`.

**Then the value check, and it found the same class from the other side.**
`net-tune/tests/revert-drift.ps1` reads the CURRENT value behind every claim each
revert makes - never applying one - and reports it. 20 claims: 19 verifiable and
all 19 differing from the machine, which is the healthy reading for a tune that
IS applied, and 1 UNVERIFIABLE. That one is real: `surfshark-av-off-revert.ps1`
promises to set the `Surfshark Antivirus` service back to Automatic and that
service no longer exists, because a sibling script uninstalled the app. A revert
that cannot do the first thing it promises is the only outcome the script fails
on; drift alone exits 0, because only a human knows whether a value moved
because the tune did it or because the capture was wrong. All three outcomes
proven by plants. Detail in `net-tune/handoff.md`.

**And the serious one, later the same session: a net-tune revert file would have
left this machine with NO antivirus.** `surfshark-av-off-revert.ps1` started the
Surfshark service and then disabled Defender on the next line, unconditionally -
and Surfshark has since been uninstalled, so that start could only fail. Fixed in
the file AND in the generator that rewrites it, and gate stage 6 now refuses any
revert that stands real-time protection down outside an `if`, that invokes
anything but known-safe restore commands, or that restores nothing at all. 50 ok,
exit 0; proven red against the real pre-fix file. No revert is ever executed by
the gate. Detail in `net-tune/handoff.md`, which remains the only record - that
folder has no git remote and no history.

**Follow-on the same session: net-tune got its own gate.** Eight of its ELEVATED
scripts had the guard-that-can-never-fire - `Split-Path -Parent
$MyInvocation.MyCommand.Path` with the emptiness check after it - and every one
of them derived its LOG and its REVERT path from that call. All eight now try
`$PSScriptRoot` first. New `net-tune/tests/preflight.ps1`: parse, no hardcoded
path (planted positive), guard shape, each guard LIFTED OUT and RUN with no
script file behind it (never the elevated body), and no orphaned revert file.
38 ok, exit 0. Proven red three ways. Its planted-path check caught a bug in its
own detector regex on the first run, which had been reporting clean while
matching nothing. net-tune is not a git repo, so `net-tune/handoff.md` - also new
- is the only record.

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

**STATE AT CLOSE, 2026-09-03. THE QUEUE IS EMPTY. This desk retired with
everything green and pushed, so a successor should NOT go looking for work here
- read this section, confirm nothing below has reopened, and say so.**

- `tests\preflight.ps1`: **83 ok, exit 0**, unelevated. Tree clean, `origin/main`
  at 0/0.
- Items 1 to 6 below are all closed. Nothing is open.
- **Nothing here needs Tre's hands.** The one thing that does is the component
  store, and he has already answered it: do nothing now, in-place repair upgrade
  when he wants it fixed. Do not re-run RestoreHealth - it cleared the flag and
  MOVED the fault rather than fixing it. `tests/sandbox-run.ps1` stays unprovable
  end to end until the store is fixed and the machine rebooted; its mapping rules
  ARE gated meanwhile, proven red three ways.
- **net-tune is a git repo as of 2026-09-03 and has a remote now.** It was not a
  repo at all before that date. See the merge section below for what stays
  private and why.
- **`forged-agents` was built from this desk on 2026-09-03** and lives at
  `Desktop/TRE-Forged/forged-agents`, pushed PRIVATE to
  `treforged/forged-agents`. **PUBLIC IS A SEPARATE DECISION AND IT HAS NOT BEEN
  MADE - do not push it public.** Run `python tests/check_public_safe.py
  --self-test` and then `--denylist denylist.txt` before any push; the deny list
  is deliberately not committed, so a fresh clone has to rebuild it.


**For the Desktop folder migration (checked 2026-09-02, so it is not
rediscovered): this desk is SAFE TO MOVE, but NOT safe to RENAME.**

- The repo hard-codes no absolute paths, and **`tests/preflight.ps1` stage 14
  now enforces it** rather than leaving it to a grep somebody remembers to run.
  Every path is derived at runtime from `$PSScriptRoot` / `Split-Path -Parent`.
  (The original claim here was wrong: `install.ps1`'s help example carried
  `C:\tools\windows-tune` until 2026-09-02.)
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

## The net-tune merge: history stayed private, three tests came over (2026-09-03)

Tre asked for net-tune to be merged into windows-tune so people download and run
both in one go. Two findings changed the shape of that job, and both are worth
not re-deriving.

**The merge was already about 90 percent done.** Scripts 01 to 06 here ARE
net-tune generalized. Each pair was checked, not assumed: 01 covers net-tune.ps1,
02 covers perf-tune.ps1, 04 covers store-cleanup.ps1, 05 covers
restore-defender/defender-force/ensure-protected, and 06 is the vendor-neutral
form of the two Surfshark scripts. The design goal was already met too - the menu
is per-task, so nobody is forced into the network half to get the Windows half.

**DELETING AFTER MERGING DOES NOT UNPUBLISH.** net-tune's first commit
(`191b5ce`) carries a full drive inventory with the username in it, a captured
security posture of one machine, and generated revert files holding that
machine's LAN DNS. A subtree merge would have put all of it into this PUBLIC repo
permanently, even with a later commit deleting the files. So the history stayed
in the private net-tune repo - which is where an internal handoff belongs - and
the three test files came over as a fresh commit citing `191b5ce` and `af3e319`.
That citation is the only surviving link between this repo and that record.

**What came over:** `tests/revert-lib.ps1`, `tests/revert-drift.ps1` and
`tests/revert-credibility.ps1`. They answer a question preflight could not:
would running a revert file put back what it captured? Neither ever runs one.
The port rebound them to `scripts\`, keyed NIC targets on the property
DisplayName alone because 01 resolves its adapter at runtime, and taught the
parser this repo's `@{ Name = ...; Value = ... }` table shape.

**What was deliberately left behind, and must stay behind:** storage.txt,
test-05.out, excl-after.txt, the three generated `*-revert.ps1` captures,
test-05.ps1, and net-tune's own handoff.md. The `evals/*.txt` moved to
`~/.claude/ollama/evals/`.

**Preflight is 83 ok, exit 0.** Stage 18 hands the two new checks four planted
fixtures and asserts all eight verdicts, four of them RED - a no-op revert, an
unreadable setting, and an empty folder for each script. The fixtures are parsed
and never executed. Note the limit: no revert file exists in a clean checkout, so
the fixtures prove the logic and the real-machine path is first exercised when
somebody actually runs 01 or 02.

**Free-tier note.** ollama qwen3:14b drafted the fixture stage and got four of
eight expectations backwards - it thought the drift check should fail on a no-op
revert. Scored in `~/.claude/ollama/playbook.md`: this tier drafts harness SHAPE
acceptably and assert TABLES unacceptably.

<!-- AUTO-SNAPSHOT:BEGIN - machine-written, replaced each compaction -->
## Auto-snapshot

_Written 2026-09-03 16:58 by handoff_hook. Everything below this heading is
machine-generated and replaced each time; put durable notes above it._

- **Branch:** `main`
- **vs upstream:** 0 ahead, 0 behind

- **Uncommitted (1 file(s)):**

```
M handoff.md
```

- **Recent commits:**

```
ba91bf5 docs(handoff): why net-tune's history stayed private and only its tests came over
3589621 test(revert): prove a revert file would restore what was actually there
875dd21 chore(handoff): refresh the auto-snapshot at the close of this desk
9a96425 docs(handoff): record why megabytes cannot measure context, before this desk closes
08a5751 docs(handoff): the sixth Tier A value reads Disabled when elevated, as 01 runs
19e3049 chore(handoff): refresh the machine-written auto-snapshot
724c330 feat(01,02): read the values back off the machine instead of printing an after-state
f37df40 docs(handoff): RestoreHealth cleared the flag and moved the fault, it did not fix it
```

<!-- AUTO-SNAPSHOT:END -->
