#!/bin/sh
# Publishes a release: tags the version, builds TVCraft Installer, signs it with your Developer ID,
# notarizes and staples it, makes Sparkle's appcast, and creates the GitHub release with both. Players'
# installers pick the release up from GitHub: the game from its tag, the installer from the appcast.
# Adapted from Frontline Rewritten's tools/release.sh.
#
#   tools/release.sh <version> [--prerelease] [--min-app <version>] [--notes <file.md>] [--dry-run]
#
#   <version>        1.0.0, or 1.0.0-rc1 for a release candidate (with --prerelease)
#   --prerelease     a GitHub pre-release: only installers with includePrereleases see it
#   --min-app V      players need installer V or later to build this release (port.json minAppVersion)
#   --notes FILE     the release notes (Markdown); asked for otherwise
#   --dry-run        checks everything and builds ad hoc, but signs, notarizes, commits and pushes nothing
#
# One-time setup is in docs/release.md. NOTARY_PROFILE names the notarytool keychain profile
# (default frontline-notary: the same Apple ID and team sign both ports).
#
# The installer's CMake project (apps/installer) takes TVCRAFT_VERSION, TVCRAFT_COMMIT,
# TVCRAFT_INSTALLER_SIGN_IDENTITY, TVCRAFT_DEVELOPMENT_TEAM and TVCRAFT_SPARKLE_PUBLIC_KEY, builds the
# target TVCraftInstaller as "TVCraft Installer.app", and caches Sparkle's folder as TVCRAFT_SPARKLE_DIR.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="chocoguy/TVCraft"
PROFILE="${NOTARY_PROFILE:-frontline-notary}"
BUILD="$ROOT/build/release-installer"
DIST="$ROOT/build/dist"

version=""
prerelease=0
min_app=""
notes=""
dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prerelease) prerelease=1 ;;
        --min-app) min_app="$2"; shift ;;
        --notes) notes="$2"; shift ;;
        --dry-run) dry=1 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) version="$1" ;;
    esac
    shift
done

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
# Runs a command, or (dry run) only shows it.
act() {
    if [ "$dry" = 1 ]; then
        printf '   (dry run) %s\n' "$*"
    else
        "$@"
    fi
}

echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || fail "give a version like 1.0.0 or 1.0.0-rc1"
case "$version" in *-*) [ "$prerelease" = 1 ] || fail "$version looks like a release candidate: add --prerelease" ;; esac
[ -z "$min_app" ] || echo "$min_app" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "--min-app takes a version like 1.0.0"
tag="v$version"

# A problem that stops a release; a dry run only reports it.
need() {
    if [ "$dry" = 1 ]; then
        echo "   would stop a release: $1"
    else
        fail "$1"
    fi
}

say "Checking"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || need "check out main first"
[ -z "$(git status --porcelain)" ] || need "commit or stash your changes first"
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || need "main differs from origin/main: pull or push first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag already exists"
# Players clone each submodule at the commit main records: it has to be on GitHub, on any branch
# (MCPE-0.8.1-fortv's is on tvos, not its default branch).
for path in $(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}'); do
    sub="$(git ls-tree HEAD "$path" | awk '{print $3}')"
    [ -n "$sub" ] || { need "$path is in .gitmodules but not committed"; continue; }
    if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
        git -C "$path" fetch --quiet origin
        [ -n "$(git -C "$path" branch -r --contains "$sub" 2>/dev/null)" ] || need "push $path's $sub first"
    else
        need "$path isn't checked out: git submodule update --init $path"
    fi
done
echo "   engine tests"
/usr/bin/python3 -I scripts/tests/test_tvcraft.py >/dev/null 2>&1 || fail "scripts/tests/test_tvcraft.py fails: run it to see why"
key_file="$ROOT/apps/installer/sparkle-public-key.txt"
[ -s "$key_file" ] || need "no Sparkle public key in apps/installer/sparkle-public-key.txt (docs/release.md)"
identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' | head -1)"
if [ -z "$identity" ]; then
    [ "$dry" = 1 ] || fail "no Developer ID Application certificate in the keychain (docs/release.md)"
    echo "   no Developer ID certificate (fine for a dry run)"
fi
team="$(printf '%s' "$identity" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
if [ "$dry" = 0 ]; then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "no notarytool profile $PROFILE (docs/release.md)"
    command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || fail "install gh and run gh auth login (docs/release.md)"
fi
if [ -z "$notes" ]; then
    if [ "$dry" = 1 ]; then
        notes="$(mktemp -t tvcraft-notes).md"
        printf '## TVCraft %s\n\n- Dry run.\n' "$version" >"$notes"
    else
        notes="$(mktemp -t tvcraft-notes).md"
        printf '## TVCraft %s\n\n- \n' "$version" >"$notes"
        ${EDITOR:-vi} "$notes"
    fi
fi
[ -s "$notes" ] || fail "the release notes are empty"
echo "   $tag, signed by ${identity:-nobody (dry run)}"

say "Bumping port.json"
mkdir -p "$(dirname "$BUILD")"
[ "$dry" = 0 ] || cp port.json "$BUILD.port.json"
/usr/bin/python3 -I - "$version" "$min_app" <<'EOF'
import json, sys
from pathlib import Path
path = Path('port.json')
text = path.read_text()
data = json.loads(text)
version, min_app = sys.argv[1], sys.argv[2]
# Keep the file's layout: replace the two values in place.
text = text.replace(f'"version": {json.dumps(data["version"])}', f'"version": {json.dumps(version)}', 1)
if min_app:
    text = text.replace(f'"minAppVersion": {json.dumps(data["minAppVersion"])}', f'"minAppVersion": {json.dumps(min_app)}', 1)
json.loads(text)
path.write_text(text)
EOF
# port.json may already say this version (bumped by hand): then there's nothing to commit, and the
# tag goes on the current commit. (git commit with nothing to commit fails, which set -e turns into
# a silent stop.)
if git diff --quiet -- port.json; then
    echo "   port.json already says $version: tagging the current commit"
else
    act git commit --quiet -am "Release $version"
fi
act git tag -a "$tag" -m "TVCraft $version"
if [ "$dry" = 1 ]; then
    grep -E '"(version|minAppVersion)"' port.json | sed 's/^/   would be: /'
    mv "$BUILD.port.json" port.json
fi
commit="$(git rev-parse --short HEAD)"

say "Building TVCraft Installer $version"
sign_identity="${identity:--}"
[ "$dry" = 0 ] || sign_identity="-"
cmake -S "$ROOT/apps/installer" -B "$BUILD" -G Xcode \
    -DTVCRAFT_VERSION="$version" -DTVCRAFT_COMMIT="$commit" \
    -DTVCRAFT_INSTALLER_SIGN_IDENTITY="$sign_identity" -DTVCRAFT_DEVELOPMENT_TEAM="$team" \
    -DTVCRAFT_SPARKLE_PUBLIC_KEY="$(tr -d ' \n' 2>/dev/null <"$key_file")" >/dev/null
cmake --build "$BUILD" --config Release --target TVCraftInstaller -- -quiet
app="$(find "$BUILD" -path '*/Release/TVCraft Installer.app' -maxdepth 3 -type d | head -1)"
[ -n "$app" ] && [ -d "$app" ] || fail "the build made no app"
sparkle_bin="$(sed -n 's/^TVCRAFT_SPARKLE_DIR:INTERNAL=//p' "$BUILD/CMakeCache.txt")/bin"

say "Signing"
# Sparkle's parts inside-out, then the app (Sparkle's documentation, "Code signing").
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { act codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
sign "$fw/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app"
act codesign --verify --deep --strict --verbose=2 "$app"

say "Notarizing"
rm -rf "$DIST/$version"
mkdir -p "$DIST/$version"
zip="$DIST/$version/TVCraftInstaller-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
act xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait
act xcrun stapler staple "$app"
act spctl --assess --type execute --verbose=2 "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

say "Making the appcast"
cp "$notes" "$DIST/$version/TVCraftInstaller-$version.md"
act "$sparkle_bin/generate_appcast" --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$tag/" \
    --link "https://github.com/$REPO" "$DIST/$version"

say "Publishing"
if [ "$dry" = 1 ]; then
    echo "   (dry run) git push origin main $tag"
    echo "   (dry run) gh release create $tag $zip $DIST/$version/appcast.xml"
    echo "Dry run done: $zip (ad hoc signed)."
    exit 0
fi
printf 'Push %s and publish the release on GitHub? [y/N] ' "$tag"
read -r answer
case "$answer" in
    y|Y|yes) ;;
    *) echo "Stopped before pushing. The commit and $tag are local: git tag -d $tag && git reset --hard HEAD~1 undoes them."; exit 1 ;;
esac
git push origin main "$tag"
pre=""
[ "$prerelease" = 0 ] || pre="--prerelease"
# shellcheck disable=SC2086
gh release create "$tag" "$zip" "$DIST/$version/appcast.xml" --repo "$REPO" --verify-tag \
    --title "TVCraft $version" --notes-file "$notes" $pre
echo "Published $tag: https://github.com/$REPO/releases/tag/$tag"
