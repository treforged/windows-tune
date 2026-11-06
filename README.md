# windows-tune

Measured fixes for a Windows 11 gaming and development desktop. Network, power
and core-unpark changes write a revert file before they change anything. The others do
not. Every claim here came from a before/after
measurement on a real machine, not from a tweak list.

The theme: most "gaming optimizer" tools and custom power plans make things
**worse**. This repo mostly undoes them.

## Results on the reference machine

Ryzen 7 7700X · RTX 4070 Super 12 GB · 32 GB DDR5 · 2.5 GbE · Windows 11 Pro

| Change | Before | After |
| --- | --- | --- |
| Single-stream download | 17.0 Mbit/s | **336 Mbit/s** |
| WinSxS component store | 21.0 GB | **14.9 GB** |
| GPU idle | 50 °C / 35 W | 43 °C / 20 W |
| Local LLM prompt processing | 118 tok/s | **1,036 tok/s** |
| PowerShell spawn | 598 ms | **~120 ms** |

## The findings worth knowing

**TCP receive-window auto-tuning was disabled.** This is the big one. Disabled
pins the receive window at 64 KB, capping a single stream at `64 KB / RTT`. At a
22 ms round-trip that is ~23 Mbit/s regardless of your line speed. Optimizer
scripts disable it because "auto" sounds slow. It is not. 20x recovered here.

**Minimum processor state was pinned at 100%.** A boost-driven CPU earns its top
clocks out of thermal and power headroom. Pinning the floor at 100% spends that
headroom idling — higher temps, higher power, no gain, and potentially lower
sustained boost. AMD's guidance is a 0% floor with a 100% ceiling.

**NIC power saving causes latency spikes, not throughput loss.** Green Ethernet,
Gigabit Lite and Flow Control renegotiate or pause the link. They cost you
percentile latency — the hitches you feel in a match — while leaving average
throughput and average ping looking fine. Average ping is a bad metric for this.

**Interrupt Moderation off is the one tweak the optimizers get right.** It is
deliberately left disabled.

**`C:\Windows` is not as big as your disk tool says.** WinSxS is built from
hardlinks, so recursive size scans count the same bytes many times. Only DISM
reports the real component-store size. A scan said 143 GB; the truth was 21 GB.

**Disabling a third-party AV without uninstalling it can leave you with
nothing.** Windows stands Defender down when another AV registers with the
Security Center. Turn that AV's scanner off but leave it installed, and the
registration persists: the third-party scanner is off, Defender has not taken
over, and no loud warning appears. `05-defender-handover.ps1` detects exactly
this state.

**Uninstalling beats disabling, and this is the whole trick.** Tamper Protection
stops *scripts* from enabling Defender or writing its settings — that is its
purpose, and any tool claiming to force past it is lying. But it does **not**
stop Windows from promoting Defender by itself once no other product holds the
Security Center registration. Remove the other AV and Windows does the handover,
past Tamper Protection, because Windows is the one doing it. On the reference
machine that took Defender from fully disabled (`DisableAntiSpyware=1`,
`WinDefend` stopped, signatures 7 months stale) to `AMRunningMode: Normal` with
current signatures **seconds later, with no reboot** — after two hours of
scripted repair had achieved nothing.

**Check whether you actually use the thing you are protecting.** The removal
above was only obvious once the bundled VPN's adapter was measured: 0 bytes in,
0 bytes out. The constraint "keep the VPN" had been taken at face value and was
never load-bearing. Measure the thing before you engineer around it.

**A call that does not throw is not a call that worked.** `Add-MpPreference`
returns quietly when Defender is still settling after a handover: eleven
exclusions reported success and none were stored. Only reading
`Get-MpPreference` back revealed it, so `05` now verifies every exclusion
rather than trusting the write.

The first guess at the cause was Tamper Protection, and that was wrong.
Re-running once `AMRunningMode` reached `Normal` stored 11/11 with Tamper
Protection still on. The real rule is narrower: **wait for Defender to reach
`Normal` before configuring it**, and verify afterwards either way. Recorded
because the wrong cause was the plausible one.

**Developer exclusions were measured, then removed.** Shell spawn was 115-123 ms
with them and 111-137 ms without: no difference outside noise. The speedup came
entirely from removing the competing scanner. Excluding your interpreters
shrinks the protection surface, so unless it shows up in a measurement on your
own machine, do not keep it. `05 -AddDevExclusions` is opt-in for that reason.

**Real-time AV scanning of interpreters is a large hidden tax.** Every
`python`/`node`/`git` spawn gets scanned before it runs. On a machine driving
agent tooling that fires several subprocesses per action, it dominates.

## Install

Read [NOTICE.md](NOTICE.md) first. It is short and it is the whole risk and
privacy story; the menu shows it and will not run anything until you type
`I ACCEPT`.

**Recommended:** download the installer, read it, then run it from an
**elevated** PowerShell. It puts the repo in `%ProgramFiles%\windows-tune`,
a folder only administrators can write, and runs nothing. It downloads one
pinned release, not the moving `main` branch, and refuses the zip if its SHA256
does not match the value written in the script:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/treforged/windows-tune/main/install.ps1 -OutFile install.ps1
notepad .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Then double-click `Run-WindowsTune.cmd` in that folder. It opens the menu, asks
for administrator rights once, and runs one script at a time with a y/N
confirmation before every change.

**Why Program Files:** the menu runs its scripts and revert files as
administrator. In a folder a normal program can write (`%LOCALAPPDATA%`,
Downloads, anywhere you extract a zip), malware running as you could swap a
script before you click Yes on the admin prompt. So the menu **will not
elevate** from such a folder, and an elevated run there refuses with exit 4.
From a zip extracted anywhere, the read-only options (storage report,
antivirus status, revert list) still work; for the rest, install as above.

There is deliberately no `irm <url> | iex` one-liner. Download-and-execute in
one step is the ClickFix malware pattern, Windows Defender flags that exact
string as `Trojan:Win32/ClickFix.PM!MTB`, and a tool about undoing bad tweaks
should not teach the habit.

## Scripts

Run elevated, in order, or individually. None support `-WhatIf` (09 has `-DryRun`). Only 01, 02, 08, 09 and 10
write a `*-revert.ps1` beside themselves first. 03 changes nothing. 04, 05 and 06
write no revert file: 04's cleanup cannot be undone, and 06 removes a product.

| Script | Does |
| --- | --- |
| `windows-tune.ps1` / `Run-WindowsTune.cmd` | The menu. Shows NOTICE.md, requires `I ACCEPT`, elevates once, confirms every change, lists revert files. |
| `install.ps1` | Downloads one pinned release zip, checks its SHA256, unpacks it to `%ProgramFiles%\windows-tune` (run it elevated) and unblocks it. Runs nothing. |
| `01-network-tune.ps1` | Restores auto-tuning, RSS, RSC and NIC offloads; disables NIC power saving. Tier A applies live; Tier B stages until `-BounceAdapter` or reboot. |
| `02-power-tune.ps1` | Minimum processor state → 0%, ceiling untouched. |
| `03-storage-report.ps1` | Read-only. Largest folders per drive; every Steam game with **real** last-played dates; Epic/Xbox by size. |
| `04-component-cleanup.ps1` | Checks the component store's HEALTH first and stops with repair instructions if it is damaged. Then true WinSxS size, and reclaims superseded packages. `/ResetBase` opt-in only. |
| `05-defender-handover.ps1` | Diagnoses the "no AV at all" state; repairs what a script safely can; adds developer exclusions once protection is genuinely on, and **verifies they were actually stored**. |
| `06-remove-third-party-av.ps1` | Fully uninstalls an MSI-based third-party AV and waits for Windows to hand protection back to Defender. Usually needs no reboot and no Tamper Protection toggle. |
| `08-core-unpark.ps1` | Keeps every CPU core unparked (minimum cores 100%) on the active plan, AC and battery. |
| `10-auto-update.ps1` | Opt-in update choice: Off (default), Check and tell me, or Install automatically. See Updates below. |
| `11-recommended.ps1` | Read-only. Lists the privacy changes worth making on this PC, with risk, undo and source. |
| `09-game-mode.ps1` | Game mode. While a game you list runs, pauses the background work you list, and puts it back when the game exits. See below. |

### Game mode (`09-game-mode.ps1`, menu 8, 9 and G)

While a listed game is running, game mode applies what its config lists, and
undoes exactly that when the last listed game exits. **With the shipped
defaults it only caps the upload of OneDrive, Google Drive and Dropbox** to
1 Mbit/s with a Windows QoS policy: a big background upload is a common cause
of ping spikes, a cap kills nothing and interrupts no sync, and a reboot clears
it. Stopping programs (for example Docker Desktop, or Ollama to free GPU
memory), stopping services and shutting WSL down are in the config as
examples, switched off.

- **Config:** copy `scripts\09-game-mode.defaults.json` to
  `scripts\09-game-mode.json` and edit the copy. Game mode reads yours first,
  and an update never replaces it. Games are matched by the game's own exe
  name, not its launcher.
- **Never touched, whatever the config says:** anti-cheat (Vanguard `vgc`/`vgk`,
  EasyAntiCheat, BattlEye, FACEIT, Ricochet, PunkBuster and others), Windows
  system processes and services (`csrss`, `wininit`, `lsass`, `services`,
  `smss`, `winlogon`, `svchost`, `explorer`, `dwm` and others), Defender and
  Windows Security, and any program on your game list. Those entries print
  `REFUSED` and are skipped. Stopping anti-cheat gets you kicked at best.
- **Preview first:** `.\scripts\09-game-mode.ps1 -DryRun` (menu 8) prints what
  it would do and changes nothing. It needs no admin.
- **Run it:** menu 9 (`-Watch`) watches until you close the window. Ctrl+C
  undoes game mode before it stops. A program it stopped is asked to close
  first, killed only if its entry says `"force": true`, and started again
  afterwards with your normal rights.
- **Undo:** while game mode is on, `09-game-mode-revert.ps1` names exactly what
  it changed, read back off the machine (menu R). It removes itself once
  everything is back. If a watcher is killed mid-game, the next run undoes the
  leftover changes first.
- **Start at sign-in (opt-in):** menu G (`-InstallWatcher`) registers a
  scheduled task, `windows-tune game mode`, that runs the watcher hidden at
  every sign-in. That is the only thing in this repo that stays running. It is
  refused unless windows-tune is installed in Program Files, because the task
  runs as admin. Remove it with `09-game-mode-watcher-revert.ps1` (menu R) or
  `-RemoveWatcher`.

### Recommended changes (menu S, and the Recommended button in the click-install window)

`scripts\11-recommended.ps1` reads this PC (it runs `privacy\privacy-audit.ps1`, which is read-only) and lists
only the changes the audit found worth making. For each one it says what it does, the risk, the undo and where
the claim is documented. **Nothing is applied by looking.** In the click-install window the safe changes are
pre-ticked, the others are listed unticked, and a tick only selects rows: you still press Install selected and
answer the confirmation box. A change whose source says NOT FOUND is a judgement call and is never pre-ticked.

### Privacy scripts (`privacy\`, menu P, T, Y, L, B and D)

Merged in from the former net-tune repo, plus `telemetry-tune.ps1`. Each is a menu row and a click-install row.

| Menu | Script | Does |
| --- | --- | --- |
| P | `privacy\privacy-audit.ps1` | Read-only. Checks 12 telemetry, ad-ID, location, browser-cookie and DoH settings. Exit 0 all as expected, 1 drift, 2 nothing readable. |
| T | `privacy\telemetry-tune.ps1` | Diagnostic data policy (lowest level your edition allows: 0 on Enterprise, Education and Server, 1 Required on Home and Pro, as Microsoft documents), advertising ID, tailored experiences, activity-feed publishing. Records the old values and writes `telemetry-tune-revert.ps1` first; refuses a policy it did not set. `-DryRun` shows the plan. |
| Y | `privacy\telemetry-tune.ps1 -ServicesOnly` | Disables the DiagTrack and dmwappushservice services. Separate and never pre-ticked: Microsoft's pages do not recommend it. |
| L | `privacy\privacy-tune.ps1` | Hides your language list from websites (per user, no admin). Writes `privacy-tune-revert.ps1` first. |
| B | `privacyrowser-privacy.ps1` | Chrome and Edge policy: block third-party cookies and Chrome ad-topic APIs. Run elevated. Undo: `-Undo`. Refuses to overwrite a policy it did not write. |
| D | `privacy\dns-encrypt.ps1` | Turns on DNS over HTTPS for 1.1.1.1 and 1.0.0.1. Run elevated. Rolls back by itself if a test lookup fails. Writes `dns-encrypt-revert.ps1` first. |

Revert files from `privacy\` are listed by menu R together with the ones in `scripts\`.

### Updates (`10-auto-update.ps1`, menu U and V)

Off by default. A fresh install checks nothing and registers no task. Menu V asks for one of three modes:

- **Off** - nothing is checked.
- **Check** - a scheduled task asks GitHub for the latest release at sign-in and daily and leaves a notice (menu U shows it). It installs nothing.
- **Install** - the same task also downloads the new release zip and refuses unless ALL of these hold: its SHA256 matches the digest GitHub publishes for that asset; a detached signature (`windows-tune-vX.Y.Z.zip.sig`) verifies against the release key in `scripts\update-pubkey.xml`, the key shipped with the copy you already have; and the zip holds only the file types this tool ships and no path that leaves the folder. It then keeps your current copy in `<install folder>.previous` and installs through `install.ps1 -FromZip -Sha256`. It never runs while a game from the game mode list is running (checked again after the download). Menu R lists `10-update-revert.ps1`, which puts the previous copy back. A copy that ships no key cannot turn Install on (exit 5); Check still works.

Both on-modes register one scheduled task, `windows-tune update`, only from a Program Files install (the same rule as menu G). Choosing Off removes it.

**What the signature does and does not give you:**

- The SHA256 alone comes from the same GitHub release as the zip, so alone it would not prove who published it. The signature is made with a private key that lives only on the maintainer's PC, outside every repo (`tools\new-signing-key.ps1` makes it, DPAPI-protected, and prints only the public key and its fingerprint; `tools\sign-release.ps1` signs a release zip). Menu U shows the fingerprint of the key your copy trusts, so you can compare it with the one the maintainer publishes.
- **First install:** the public key reaches your PC inside the first install, and that install is trusted by the SHA256 pinned in `install.ps1` on the main branch. So for the first install the trust is that pin and the maintainer's GitHub account, not the signature.
- **Key change:** an update is checked with the key you already have, never with a key inside the new zip. Rotating the key means a fresh manual install. If the maintainer loses the private key, copies carrying the old public key cannot take another automatic update.
- A valid signature proves the maintainer signed those exact bytes. It does not prove they are free of bugs.

```powershell
# see what is wrong, change nothing
.\scripts\03-storage-report.ps1
.\scripts\05-defender-handover.ps1 -Diagnose

# fix
.\scripts\01-network-tune.ps1 -BounceAdapter
.\scripts\02-power-tune.ps1
.\scripts\04-component-cleanup.ps1

# a third-party AV switched off but Defender still not running?
# remove it properly instead of fighting Defender
.\scripts\06-remove-third-party-av.ps1 -Name Surfshark
```

## Already tuned? The scripts say so

Every script that changes something reads the current value first. If your
machine is already where the script would put it, it prints
`already at target - nothing to change` and stops - no revert file, no writes,
and no adapter bounce. `01` also changes only the settings that actually differ,
and bounces the NIC only if a NIC driver property really changed, so a run on a
tuned machine costs nothing instead of five seconds offline.

A menu option describes what it *can* change. What it *did* change is what the
script prints when you run it.

## Reverting

Scripts 01, 02, 08 and 09 write `<name>-revert.ps1` capturing the values that were live
before they ran, and only when there is something to change. Run it elevated.
04, 05 and 06 have no revert file (see the scripts table).
Reverts are generated from your machine's actual state, not from assumed
defaults.

## Scope and cautions

- Written for Windows 11 on a desktop. The power-plan reasoning is
  boost-CPU-specific (Zen 2+, Intel Turbo).
- `01` and `02` are reversible and low-risk. `04` is irreversible in the sense
  that reclaimed packages are gone, though nothing you use is removed.
- `04` will refuse to run on a PC whose component store is already damaged, and
  will tell you to run `DISM /Online /Cleanup-Image /RestoreHealth` first. A
  cleanup cannot repair a damaged store, and DISM prints
  `The operation completed successfully` either way - so without that check you
  would be told it worked and never learn your PC needs attention. A damaged
  store also blocks adding or removing Windows features and can make Windows
  updates fail in ways that look like something else entirely.
- `05` and `06` change security posture. Read them before running them.
- `06` uninstalls software. Confirm you do not rely on the product first -
  many AV suites bundle a VPN or password manager you may still want.
- Nothing here touches firewall rules, UAC, SmartScreen, or Secure Boot.
- Measure before and after. If a change does not show up in a measurement on
  *your* hardware, revert it — that is the entire point of the revert files.

## Testing

`tests\preflight.ps1` parses every script, checks the notice is ASCII, greps the
tree for pipe-to-iex, drives the menu's notice gate (missing -> exit 2,
declined -> exit 3, `-Choice R` read-only, `-Choice 2` runs the antivirus
status check without admin), and runs `install.ps1 -FromZip` against a zip of
the working tree into a temp folder. Non-zero exit on any failure. No admin
needed - run it from a normal prompt, or the `-Choice 2` stage cannot prove
the no-admin path and says so.

## Security

Found something exploitable? Use the Security tab's private vulnerability
reporting or email contact@treforged.com - see [SECURITY.md](SECURITY.md)
for what counts, what does not, and the response window.

## Licence

MIT.
