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
this state. **Tamper Protection cannot be scripted around** — that is its
purpose — so any script claiming to force Defender back on past it is lying.

**Real-time AV scanning of interpreters is a large hidden tax.** Every
`python`/`node`/`git` spawn gets scanned before it runs. On a machine driving
agent tooling that fires several subprocesses per action, it dominates.

## Scripts

Run elevated, in order, or individually. All are `-WhatIf`-free but all write
a `*-revert.ps1` beside themselves first.

| Script | Does |
| --- | --- |
| `01-network-tune.ps1` | Restores auto-tuning, RSS, RSC and NIC offloads; disables NIC power saving. Tier A applies live; Tier B stages until `-BounceAdapter` or reboot. |
| `02-power-tune.ps1` | Minimum processor state → 0%, ceiling untouched. |
| `03-storage-report.ps1` | Read-only. Largest folders per drive; every Steam game with **real** last-played dates; Epic/Xbox by size. |
| `04-component-cleanup.ps1` | True WinSxS size, then reclaims superseded packages. `/ResetBase` opt-in only. |
| `05-defender-handover.ps1` | Diagnoses the "no AV at all" state; repairs what a script safely can; adds developer exclusions once protection is genuinely on. |

```powershell
# see what is wrong, change nothing
.\scripts\03-storage-report.ps1
.\scripts\05-defender-handover.ps1 -Diagnose

# fix
.\scripts\01-network-tune.ps1 -BounceAdapter
.\scripts\02-power-tune.ps1
.\scripts\04-component-cleanup.ps1
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
- `05` changes security posture. Read it before running it.
- Nothing here touches firewall rules, UAC, SmartScreen, or Secure Boot.
- Measure before and after. If a change does not show up in a measurement on
  *your* hardware, revert it — that is the entire point of the revert files.

## Licence

MIT.
