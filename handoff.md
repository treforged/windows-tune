# Handoff: windows-tune

Newest first. Public repo - nothing machine-specific goes in this file.

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

- `06-remove-third-party-av.ps1` has no admin check of its own; the menu
  elevates before calling it, but run directly it will fail late rather than
  early.
- `05-defender-handover.ps1 -Diagnose` needs admin even though it is
  read-only; the menu's "read-only options work unelevated" line names only
  1 and R for that reason.
- Only tested on the reference machine (Windows 11 Pro, desktop). No
  Windows 10 / Home / laptop / ARM run yet.
- `tests/preflight.ps1` cannot test elevation (UAC) or the live download; both
  paths are exercised only by hand.

## Resume queue

1. [ ] Run `tests\preflight.ps1` on a second machine (any Windows 10/11 box)
   and note what differs - the whole repo has one data point.
2. [ ] Add an admin check to `06-remove-third-party-av.ps1` in the same shape
   as the others (copy the line from 02).
