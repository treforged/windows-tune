# Security policy

windows-tune is a set of PowerShell scripts that change system settings with
administrator rights. A bug here is a security issue almost by definition, so
reports are welcome and taken seriously.

## Reporting a vulnerability

Please do not open a public issue for anything exploitable.

- Preferred: **GitHub private vulnerability reporting** - the "Report a
  vulnerability" button under this repository's Security tab. It is enabled.
- Or email **contact@treforged.com** with `windows-tune` in the subject.

Include what you can of: the script and line, the Windows edition and
version, what you ran, what happened, and what you expected. A minimal repro
beats a long description. If you have a fix, a pull request against `main`
is welcome after the report.

You will get an acknowledgement within 7 days and a fix or a reasoned
"won't fix" within 30. Credit in the commit and the release notes unless you
ask otherwise.

## What counts

- Any way a script does something its help text and `NOTICE.md` do not say
  it does: touching a setting, file, service or network endpoint that is not
  named there.
- Any way to make a script execute code it did not ship with - a path built
  from user input, a downloaded file that gets run, a revert file that can be
  poisoned.
- Any way for `windows-tune.ps1` to run a changing script without the
  `I ACCEPT` gate and the y/N confirmation.
- Any way for `install.ps1` to execute what it downloads, write outside the
  chosen folder, or overwrite a user's existing `*-revert.ps1`.
- Anything that weakens protection on the machine beyond what the script
  states (`05` and `06` change antivirus state and are the highest-risk files
  here).
- A secret, credential or personal data committed to this repository.

## What does not count

- The scripts require administrator rights and change settings; that is what
  they are for. "It changes settings as admin" is not a finding.
- `-ExecutionPolicy Bypass` in the launcher is per-process and documented;
  it does not change the machine's policy.
- Things Windows Defender flags in your own copy: the scripts are plain text,
  read them. If a shipped file trips a scanner, report it anyway and we will
  look, but the answer is usually the signature, not the script.

## Scope and supported versions

Only `main` is supported. There are no releases or version numbers; a fix
lands on `main` and the resume note in `handoff.md` records it. Forks are
not in scope.

## What this repo does to protect itself

- Private vulnerability reporting, secret scanning and push protection are
  turned on for the GitHub repository.
- `tests/preflight.ps1` runs before every commit: every script must parse,
  no file may pipe a download into `Invoke-Expression`, the notice gate is
  exercised for real, and the installer is run offline into a temp folder.
- Runtime-generated files (`*-revert.ps1`, `*.log`, storage reports) are
  gitignored so a machine's real state is never committed.
- There is deliberately no `irm <url> | iex` install path. See `NOTICE.md`.

## Release signing (automatic Install mode)

- Install mode installs an update only if its SHA256 matches the digest on the release AND a detached RSA signature
  (`windows-tune-vX.Y.Z.zip.sig`) verifies against `scripts/update-pubkey.xml`, the key shipped with the copy you
  already have. The private key is made by `tools/new-signing-key.ps1`, protected with Windows DPAPI, and kept
  outside every git tree.
- **A process running as the maintainer's Windows user can sign.** DPAPI protects the key from other users and from
  other PCs, not from a program already running as the same user on the maintainer's PC. The signature therefore
  proves "signed on the maintainer's PC under the maintainer's account", not more.
- **A lost key means one fresh manual install.** DPAPI ties the key to that user on that PC. If the key is lost
  (reinstall, disk failure), no new release can be signed for copies that carry the old public key; those copies
  need one manual install of a release that ships a new key. An update never replaces the key, because an update
  is checked with the key you already trust.
- The first install is trusted by the SHA256 pinned in `install.ps1` on `main` and the maintainer's GitHub account,
  not by the signature.
