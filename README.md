# windows-tune

Measured fixes for a Windows 11 gaming and development desktop. Every script
writes a revert file before it changes anything, and every claim here came from
a before/after measurement on a real machine, not from a tweak list.

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

**Easiest:** Code > Download ZIP, extract it anywhere, double-click
`Run-WindowsTune.cmd`. It opens the menu, asks for administrator rights once,
and runs one script at a time with a y/N confirmation before every change.

**From PowerShell:** download the installer, read it, then run it. It puts the
repo in `%LOCALAPPDATA%\windows-tune` and runs nothing:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/treforged/windows-tune/main/install.ps1 -OutFile install.ps1
notepad .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

There is deliberately no `irm <url> | iex` one-liner. Download-and-execute in
one step is the ClickFix malware pattern, Windows Defender flags that exact
string as `Trojan:Win32/ClickFix.PM!MTB`, and a tool about undoing bad tweaks
should not teach the habit.

## Scripts

Run elevated, in order, or individually. All are `-WhatIf`-free but all write
a `*-revert.ps1` beside themselves first.

| Script | Does |
| --- | --- |
| `windows-tune.ps1` / `Run-WindowsTune.cmd` | The menu. Shows NOTICE.md, requires `I ACCEPT`, elevates once, confirms every change, lists revert files. |
| `install.ps1` | Downloads the repo zip to `%LOCALAPPDATA%\windows-tune` and unblocks it. Runs nothing. |
| `01-network-tune.ps1` | Restores auto-tuning, RSS, RSC and NIC offloads; disables NIC power saving. Tier A applies live; Tier B stages until `-BounceAdapter` or reboot. |
| `02-power-tune.ps1` | Minimum processor state → 0%, ceiling untouched. |
| `03-storage-report.ps1` | Read-only. Largest folders per drive; every Steam game with **real** last-played dates; Epic/Xbox by size. |
| `04-component-cleanup.ps1` | True WinSxS size, then reclaims superseded packages. `/ResetBase` opt-in only. |
| `05-defender-handover.ps1` | Diagnoses the "no AV at all" state; repairs what a script safely can; adds developer exclusions once protection is genuinely on, and **verifies they were actually stored**. |
| `06-remove-third-party-av.ps1` | Fully uninstalls an MSI-based third-party AV and waits for Windows to hand protection back to Defender. Usually needs no reboot and no Tamper Protection toggle. |

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

## Reverting

Every script writes `<name>-revert.ps1` capturing the values that were live
before it ran. Run it elevated. Reverts are generated from your machine's actual
state, not from assumed defaults.

## Scope and cautions

- Written for Windows 11 on a desktop. The power-plan reasoning is
  boost-CPU-specific (Zen 2+, Intel Turbo).
- `01` and `02` are reversible and low-risk. `04` is irreversible in the sense
  that reclaimed packages are gone, though nothing you use is removed.
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
