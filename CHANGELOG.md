# Patch notes

The installer prints the section for the version it just installed.
Each release adds its section at the top, as `## vX.Y.Z - YYYY-MM-DD`.

## v1.2.0 - 2026-11-19

- Opt-in updates (menu U and V): Off, Check or Install. The default is Off, and a fresh install creates no scheduled task.
- Install mode refuses a zip that has no valid signature from the key in `scripts/update-pubkey.xml`. It also refuses a wrong hash or a missing `.sig`. It keeps the previous copy and writes a revert file. It waits while a game runs.
- The privacy scripts are now rows in the menu and in the click-install window.
- New: `telemetry-tune` (menu T and Y), and a read-only Recommended view (menu S).

## v1.1.0

- Game mode (`09-game-mode.ps1`), opt-in. While a game you list runs, it caps cloud-sync uploads and can stop the processes or services you choose. It undoes exactly what it changed when the game exits. Anti-cheat and system processes are never touched. Dry-run is the default.
- Menu options 7 and 8, the GUI options and the privacy scripts are in the release zip.

## v1.0.0

- First release: network, power, storage, component-store and Defender steps, each with a revert file.
