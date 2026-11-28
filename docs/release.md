# Releasing

A release is a git tag (`v2.0.0`) and a GitHub release with one file, **`TVCraftInstaller.zip`**: the installer, signed with a Developer ID and notarized. Every release has it, so `releases/latest/download/TVCraftInstaller.zip` always works.

Players' installers see the new tag on GitHub, build the game from it on their Mac from their own APK, and reinstall it on every Apple TV it's on.

## The major version is the installer

- **`N.0.0` is a new installer.** `release.sh` builds, signs, notarizes and staples it, and attaches it.
- **`N.x.y` is a game update only.** `release.sh` builds no installer: it downloads `vN.0.0`'s `TVCraftInstaller.zip` and attaches it again, unchanged. It stops if `vN.0.0` has none.
- An installer builds only releases of its own major version (its `TVCraftVersion` is the `N.0.0` it was built for). Engine fixes (`scripts/tvcraft.py`, `tvos/`) ship with game releases, since the installer runs the engine from the tag.
- When a later major is on GitHub, the installer says so once per launch and shows a banner with a **Download** button (the release page). Until the player downloads it, Update All and Install Another Version… do nothing, and installing on a first Apple TV is blocked. **Reinstall still works**, so a free Apple ID's 7 days can be renewed.
- The installer doesn't update itself (no Sparkle). `port.json`'s `minAppVersion` is set to `N.0.0` only so that 1.x installers, which still read it, stop before building a newer major.
- **Transition:** 1.x installers used Sparkle. The first release with the new installer is **2.0.0**. 1.x installers will say they need installer 2.0.0, but their Check for Updates… finds nothing: players download 2.0.0 by hand from the release page.

`tools/release.sh` does all of it on your Mac. Nothing signs or publishes in CI.

## One-time setup

1. **Developer ID certificate:** already in this Mac's keychain. Check with:
   ```sh
   security find-identity -v -p codesigning
   ```
   It should list `Developer ID Application: … (USLHQ524FW)`.
2. **Notarization credentials:** the script uses the keychain profile `frontline-notary` by default, the one Frontline Rewritten's releases use (same Apple ID and team). Check it with:
   ```sh
   xcrun notarytool history --keychain-profile frontline-notary
   ```
   If it isn't there, store it. It asks for an app-specific password (account.apple.com → Sign-In and Security → App-Specific Passwords):
   ```sh
   xcrun notarytool store-credentials frontline-notary --apple-id <your Apple ID> --team-id USLHQ524FW
   ```
   To use a different profile, set `NOTARY_PROFILE=<name>` when you run the script.
   The certificate and the notary profile are only needed for `N.0.0` releases.
3. **GitHub CLI:** `gh` is installed. Check that it's signed in:
   ```sh
   gh auth status
   ```

## Each release

From a clean `main` that's pushed, with every submodule's recorded commit pushed too:

```sh
tools/release.sh 2.0.0
```

It does this, in order:
1. Checks the above, and runs the engine tests (`scripts/tests/test_tvcraft.py`). For `N.x.y`, checks that `vN.0.0` has `TVCraftInstaller.zip`.
2. Opens your editor for the release notes (Markdown), or takes `--notes <file>`.
3. Sets `port.json`'s `version` (and `minAppVersion` to `N.0.0`), commits "Release 2.0.0", and tags `v2.0.0`.
4. **`N.0.0`:** builds TVCraft Installer Release, stamped 2.0.0 (build number 20000); signs it (hardened runtime, timestamp); notarizes the zip, staples the app, checks it with `spctl`, and zips it again into `build/dist/2.0.0/TVCraftInstaller.zip`.
   **`N.x.y`:** downloads `vN.0.0`'s `TVCraftInstaller.zip` into `build/dist/<version>/`.
5. Asks before pushing, then pushes `main` and the tag, and creates the GitHub release with the zip.

If you answer no at the push, the commit and tag stay local. The script prints how to undo them.

**Options:**
- **Release candidates:** `tools/release.sh 1.0.0-rc1 --prerelease`. GitHub marks it a pre-release, so players don't see it (their installers skip pre-releases, and `latest/download` skips them). `2.0.0-rc1` builds an installer; `2.1.0-rc1` attaches `v2.0.0`'s. To test one, download its zip from the release page and turn on pre-releases in your installer:
  ```sh
  defaults write com.vanillacoffeesoft.TVCraftInstaller includePrereleases -bool YES
  ```
- **A release that needs a new installer:** make it a new major version (`3.0.0`).
- **Dry run:** `--dry-run` runs the checks (reporting, not stopping); for `N.0.0` it builds an ad hoc installer into `build/dist`, and for `N.x.y` it says "game update: attaches vN.0.0's installer". It signs, notarizes, commits, tags, downloads and pushes nothing.

## Versions

- Tags are `v` plus a semantic version. The installer's version is the `N.0.0` release it was built from; `N.x.y` releases reuse it.
- The game app's `CFBundleShortVersionString` is its numeric part, and `CFBundleVersion` is `major×10000 + minor×100 + patch`.
- `TVCraftVersion` (the full version, `-rc1` included), `TVCraftCommit` and `TVCraftGameVersion` (`0.8.1`) are in the game's Info.plist.
- `scripts/tvcraft.py build` stamps all of them from `port.json` and git. `tvcraft.py installed --device <ID>` reads the version back from the Apple TV.

## Bundle IDs

Bundle IDs are global, so each player's team gets its own: `io.github.chocoguy.tvcraft.<team ID>`. Builds made before 1.0.0 used `io.github.chocoguy.tvcraft`. Their worlds stay in that app until you move them (see `docs/installer-status.md`, "Moving your own worlds").
