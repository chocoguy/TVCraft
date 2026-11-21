# TVCraft Installer: status and test checklist

TVCraft Installer is the Mac app players download. It builds TVCraft from their own Minecraft PE 0.8.1 APK at a GitHub release tag and installs it on their Apple TV. It follows the installer playbook (`~/Documents/installer-playbook.md`) and is adapted from Frontline Rewritten's installer.

## Milestones

| | Milestone | State |
|---|---|---|
| M0 | Repo hygiene: the `MCPE-1.1.5-decomp` submodule committed (7000c01); `.DS_Store` untracked; `tvos/save-backups/` and `build/` ignored | done; the last three not yet committed |
| M1 | Build engine: `scripts/tvcraft.py` with `--json`, `--work-dir`, `check`, `prepare` (cached), `build --platform tvos`, `install` (backs up worlds first, never launches), `installed`, `clean` | done |
| M1b | Version stamping: `port.json`; `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `TVCraftVersion`, `TVCraftCommit`, `TVCraftGameVersion` in the app | done |
| M2 | The installer app, `apps/installer/` | not started |
| M3 | `tools/release.sh`, `docs/release.md`, README | done; `--dry-run` needs M2 |
| M4 | Your tests (below), then `v1.0.0` | waiting on M2 |

## What was verified (by the agent)

- `/usr/bin/python3 -I scripts/tests/test_tvcraft.py`: 22 tests pass.
- From a copy of the repo under `…/Application Support/TV Craft src`, with the work dir `…/Application Support/work dir` and Finder's bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`, XcodeGen passed with `--xcodegen`):
  - `check --json`: every check passes on this Mac.
  - `prepare --json`: about 2 s the first time; the second run answers "already prepared" in 0.1 s.
  - `build --platform tvos --sim --json`: builds, 665 files compiled (the progress estimate is also 665). The app's Info.plist has `CFBundleShortVersionString 1.0.0`, `CFBundleVersion 10000`, `TVCraftVersion 1.0.0`, `TVCraftGameVersion 0.8.1`.
  - An unsigned `generic/platform=tvOS` (arm64) build of the same project.
- Not done by the agent, on purpose: signed device builds (they register an App ID on your team), installing, launching.

## Your test checklist

### Moving your own worlds (once)
Builds before 1.0.0 used the bundle ID `io.github.chocoguy.tvcraft`. From 1.0.0 it's `io.github.chocoguy.tvcraft.<team>`, a separate app on the TV, so its worlds start empty. Move them before you open the new app for the first time:

```sh
python3 scripts/tvcraft.py devices
```
```sh
python3 scripts/tvcraft.py backup --device <UDID> --bundle-id io.github.chocoguy.tvcraft
```
Then install 1.0.0 (Terminal or installer), and before opening it:
```sh
python3 scripts/tvcraft.py restore --device <UDID> --bundle-id io.github.chocoguy.tvcraft.USLHQ524FW
```
(Use the team the installer signed with; `tvcraft.py check` shows it.) Then delete the old app from the TV.

### The Terminal path
```sh
python3 scripts/tvcraft.py check
```
```sh
python3 scripts/tvcraft.py prepare
```
```sh
python3 scripts/tvcraft.py build --device <UDID>
```
```sh
python3 scripts/tvcraft.py install --device <UDID>
```
```sh
python3 scripts/tvcraft.py installed --device <UDID>
```
`installed` should say 1.0.0 (build 10000).

### A release candidate
1. `tools/release.sh 1.0.0-rc1 --prerelease --dry-run`, then the same without `--dry-run`.
2. On a fresh macOS user account: download the zip from the release page, open it (Gatekeeper should not complain), turn on pre-releases (`defaults write com.vanillacoffeesoft.TVCraftInstaller includePrereleases -bool YES`).
3. Setup: everything green after downloading XcodeGen; a free Apple ID shows "installs open for 7 days".
4. Game: pick the APK; a wrong APK is refused with a clear message.
5. Install On your Apple TV. It installs and does not open. Open it from the Home screen and play.
6. The install shows "Opens until <date>".

### Updates
1. Tag `v1.0.1-rc1 --prerelease`. Update All rebuilds and reinstalls; a world backup appears first (Show world backups in Finder); your worlds are still there.
2. Switch the Apple TV off during Update All: it's marked pending, and Finish the Update installs it later.
3. Installer update: a release with `--min-app` above the installed installer. The old installer stops before building and asks to update; Check for Updates… updates it through Sparkle.
4. Rollback: Install Another Version back to 1.0.0.
5. Free Apple ID: Reinstall renews the 7 days.

### Then
`tools/release.sh 1.0.0`.
