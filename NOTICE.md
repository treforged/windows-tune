# Read this before running anything

These scripts change system settings with administrator rights. You run them
at your own risk, and the author collects nothing from you or your machine.

## What these scripts change

- **01-network-tune.ps1** - changes TCP receive-window auto-tuning, RSS, RSC
  and NIC offload settings, and disables NIC power-saving features (Green
  Ethernet, Gigabit Lite, Flow Control, Energy-Efficient Ethernet). With
  `-BounceAdapter` it disables and re-enables the network adapter, which takes
  the connection down for a few seconds. With `-SetDns` - and only then - it
  sets the adapter's DNS to 1.1.1.1 and 1.0.0.1. Writes
  `01-network-tune-revert.ps1`. Needs admin.
- **02-power-tune.ps1** - sets the active power plan's minimum processor state
  to 0%. The ceiling is untouched and no new plan is created. Writes
  `02-power-tune-revert.ps1`. Needs admin.
- **03-storage-report.ps1** - **read-only.** Lists the largest folders per
  drive and installed Steam, Epic and Xbox games with sizes and last-played
  dates, printed to your console. Changes nothing.
- **04-component-cleanup.ps1** - runs DISM component-store cleanup, which
  permanently removes superseded Windows update packages. Nothing in use is
  removed, but this **cannot be reverted**: older updates can no longer be
  uninstalled afterwards. `/ResetBase` is opt-in and goes further. Needs admin.
- **05-defender-handover.ps1** - **read-only by default**: diagnoses the
  Windows Defender / third-party antivirus state. With `-Repair` it clears
  Defender's disable keys and sets its services to automatic. With
  `-AddDevExclusions` it adds Defender exclusions for developer tools, which
  reduces what gets scanned. Needs admin.
- **06-remove-third-party-av.ps1** - **uninstalls** an MSI-based third-party
  antivirus product you name, including anything bundled with it (a VPN, a
  password manager), after a y/N prompt; `-Force` skips the prompt. Writes an
  uninstall log to `%TEMP%`. **Not reversible** by this repo - you would
  reinstall the product yourself. Needs admin.

Every script that changes something writes a `*-revert.ps1` beside itself
first, capturing the values that were live on your machine before it ran. Run
that file from an elevated PowerShell to restore them. Every script is a plain
PowerShell text file; read it before you run it.

## What can go wrong

- The network tune drops your connection for a few seconds when it bounces the
  adapter. On an unusual adapter it could leave a setting you need to put back
  with the revert file.
- The power-plan change is harmless on modern CPUs and is revertible.
- Component cleanup means older Windows updates cannot be uninstalled later.
- Removing an antivirus leaves the machine relying on Windows Defender taking
  over. The script checks for that, but confirm it yourself in Windows Security
  before you trust it.
- Everything here was written and measured on one machine: Windows 11 Pro on a
  desktop (AMD Ryzen 7 7700X, RTX 4070 Super). It has not been tested on
  laptops, Windows 10, Windows Home, ARM, or domain-joined, company-managed or
  Group Policy machines, and it can behave differently there.
- The licence is MIT: there is no warranty of any kind. The author is not
  responsible for damage, data loss or downtime.

## Privacy

- Nothing leaves your machine. No script sends anything anywhere: no
  telemetry, no analytics, no crash reporting, no update check, no account, no
  sign-in, no network call of any kind.
- The author collects nothing. Nothing about your hardware, games, files or
  settings is seen by anyone but you.
- The only network activity in the whole repo is the installer's one download
  of the repo zip from github.com over HTTPS. The install path is always
  download, read, run: the ZIP from GitHub, or `install.ps1` saved to disk
  first. There is deliberately no "paste this one line into PowerShell"
  installer. A `irm <url> | iex` line downloads and executes code in one step
  without you ever seeing it, which is exactly how the ClickFix malware family
  is delivered - and Windows Defender scores that pattern as
  Trojan:Win32/ClickFix.PM!MTB (severity 5) and will fire on it. Nothing here
  asks you to do that.
- The storage report prints information about your files and games to your
  console only.
- Revert files and logs are written beside the scripts and are yours. They are
  listed in `.gitignore`, so they are never shared if you fork or push the
  repo.
- The scripts do not touch firewall rules, UAC, SmartScreen, Secure Boot,
  BitLocker, Windows Update settings, user files, browsers, or any registry
  key beyond the specific settings named above.
- Nothing is left running: no service, no scheduled task, no startup entry, no
  background process. Deleting the folder removes everything except the
  changes you chose to apply - use the revert files for those.

## Who should not run this

- Company-managed or domain-joined PCs, or any machine under Group Policy.
- Anyone who cannot open Windows Security and check Defender themselves.
- Anyone who is not comfortable running a revert file from an elevated
  PowerShell.

## Before you start

- Read the script you are about to run.
- Note the revert file it writes, and where.
- Do one script at a time, and measure before and after.

## How to accept

The menu asks you to type `I ACCEPT`. Typing it means you have read this file.
