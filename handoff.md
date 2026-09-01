# Handoff: windows-tune

Newest first. Public repo - nothing machine-specific goes in this file.

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

- `05-defender-handover.ps1 -Diagnose` needs admin even though it is
  read-only; the menu's "read-only options work unelevated" line names only
  1 and R for that reason.
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
3. [ ] Consider a `-Diagnose` path in 05 that works unelevated, so the menu's
   read-only list can include it.
