# Releasing

A release is a git tag (`v1.0.0`) and a GitHub release with two files:
- **`TVCraftInstaller-<version>.zip`:** the installer, signed with a Developer ID and notarized.
- **`appcast.xml`:** Sparkle's feed. Installers read it from `releases/latest/download/appcast.xml` to update themselves.

Players' installers see the new tag on GitHub, build the game from it on their Mac from their own APK, and reinstall it on every Apple TV it's on.

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
3. **Sparkle's signing key:** TVCraft Installer uses the same EdDSA key as Frontline Installer. The private key is in your login keychain ("Private key for signing Sparkle updates"). Check that the public key it prints matches `apps/installer/sparkle-public-key.txt`:
   ```sh
   build/release-installer/_deps/sparkle-src/bin/generate_keys -p
   ```
   (The folder appears after the first installer build, or use Frontline's copy.) Back the private key up with `generate_keys -x <file>`: **without it, installers already out there can't take updates.**
4. **GitHub CLI:** `gh` is installed. Check that it's signed in:
   ```sh
   gh auth status
   ```

## Each release

From a clean `main` that's pushed, with every submodule's recorded commit pushed too:

```sh
tools/release.sh 1.0.0
```

It does this, in order:
1. Checks the above, and runs the engine tests (`scripts/tests/test_tvcraft.py`).
2. Opens your editor for the release notes (Markdown), or takes `--notes <file>`.
3. Sets `port.json`'s `version`, commits "Release 1.0.0", and tags `v1.0.0`.
4. Builds TVCraft Installer Release, stamped 1.0.0 (build number 10000), with Sparkle's public key.
5. Signs Sparkle's parts inside-out, then the app (hardened runtime, timestamp).
6. Notarizes the zip, staples the app, checks it with `spctl`, and zips it again into `build/dist/1.0.0/`.
7. Makes `appcast.xml` with Sparkle's `generate_appcast` (signed with your key, release notes embedded).
8. Asks before pushing, then pushes `main` and the tag, and creates the GitHub release with both files.

If you answer no at the push, the commit and tag stay local. The script prints how to undo them.

**Options:**
- **Release candidates:** `tools/release.sh 1.0.0-rc1 --prerelease`. GitHub marks it a pre-release, so players don't see it (their installers skip pre-releases, and `latest/download` skips them for Sparkle). To test one, download its zip from the release page and turn on pre-releases in your installer:
  ```sh
  defaults write com.vanillacoffeesoft.TVCraftInstaller includePrereleases -bool YES
  ```
- **A release that needs a newer installer:** `--min-app 1.1.0` sets `port.json`'s `minAppVersion`. Older installers then stop before building it and ask to update themselves first.
- **Dry run:** `--dry-run` runs the checks (reporting, not stopping) and builds an ad hoc installer into `build/dist`. It signs, notarizes, commits, tags and pushes nothing.

## Versions

- Tags are `v` plus a semantic version. The installer and the game share it: a release's installer is built from the same tag.
- The game app's `CFBundleShortVersionString` is its numeric part, and `CFBundleVersion` is `major×10000 + minor×100 + patch`.
- `TVCraftVersion` (the full version, `-rc1` included), `TVCraftCommit` and `TVCraftGameVersion` (`0.8.1`) are in the game's Info.plist.
- `scripts/tvcraft.py build` stamps all of them from `port.json` and git. `tvcraft.py installed --device <ID>` reads the version back from the Apple TV.

## Bundle IDs

Bundle IDs are global, so each player's team gets its own: `io.github.chocoguy.tvcraft.<team ID>`. Builds made before 1.0.0 used `io.github.chocoguy.tvcraft`. Their worlds stay in that app until you move them (see `docs/installer-status.md`, "Moving your own worlds").
