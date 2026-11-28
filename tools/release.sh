#!/bin/sh
# Publishes a release: tags the version and creates the GitHub release with the installer attached.
# Players' installers pick the game up from the tag.
#
# The major version is the installer:
#   N.0.0   a new installer: builds TVCraft Installer, signs it with your Developer ID, notarizes and
#           staples it, and attaches it as TVCraftInstaller.zip. It builds only N.x.y releases.
#   N.x.y   a game update: builds no installer. It downloads vN.0.0's TVCraftInstaller.zip and attaches
#           it again unchanged, so the latest release always has the installer.
# Adapted from Frontline Rewritten's tools/release.sh.
#
#   tools/release.sh <version> [--prerelease] [--notes <file.md>] [--dry-run]
#
#   <version>        1.0.0, or 1.0.0-rc1 for a release candidate (with --prerelease)
#   --prerelease     a GitHub pre-release: only installers with includePrereleases see it
#   --notes FILE     the release notes (Markdown); asked for otherwise
#   --dry-run        checks everything (and builds an N.0.0 installer ad hoc), but signs, notarizes,
#                    commits and pushes nothing
#
# One-time setup is in docs/release.md. NOTARY_PROFILE names the notarytool keychain profile
# (default frontline-notary: the same Apple ID and team sign both ports).
#
# The installer's CMake project (apps/installer) takes TVCRAFT_VERSION, TVCRAFT_COMMIT,
# TVCRAFT_INSTALLER_SIGN_IDENTITY and TVCRAFT_DEVELOPMENT_TEAM, and builds the target
# TVCraftInstaller as "TVCraft Installer.app".
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="chocoguy/TVCraft"
PROFILE="${NOTARY_PROFILE:-frontline-notary}"
BUILD="$ROOT/build/release-installer"
DIST="$ROOT/build/dist"

version=""
prerelease=0
notes=""
dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prerelease) prerelease=1 ;;
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
tag="v$version"
numeric="${version%%-*}"
major="${numeric%%.*}"
installer_tag="v$major.0.0"
ZIP_NAME="TVCraftInstaller.zip"
# N.0.0 (or N.0.0-rc1) makes a new installer; anything else reuses vN.0.0's.
case "$numeric" in
    "$major.0.0") new_installer=1 ;;
    *) new_installer=0 ;;
esac

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
identity=""
team=""
if [ "$new_installer" = 1 ]; then
    echo "   new installer: $tag builds TVCraft Installer (it builds $major.x.y releases)"
    identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' | head -1)"
    if [ -z "$identity" ]; then
        [ "$dry" = 1 ] || fail "no Developer ID Application certificate in the keychain (docs/release.md)"
        echo "   no Developer ID certificate (fine for a dry run)"
    fi
    team="$(printf '%s' "$identity" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
    if [ "$dry" = 0 ]; then
        xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "no notarytool profile $PROFILE (docs/release.md)"
    fi
else
    echo "   game update: attaches $installer_tag's installer"
fi
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    if [ "$new_installer" = 0 ]; then
        gh release view "$installer_tag" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null | grep -qx "$ZIP_NAME" \
            || need "$installer_tag has no $ZIP_NAME on GitHub: a $major.x.y release needs the $major.0.0 installer"
    fi
else
    need "install gh and run gh auth login (docs/release.md)"
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
if [ "$new_installer" = 1 ]; then
    echo "   $tag, signed by ${identity:-nobody (dry run)}"
else
    echo "   $tag"
fi

say "Bumping port.json"
mkdir -p "$(dirname "$BUILD")"
[ "$dry" = 0 ] || cp port.json "$BUILD.port.json"
# minAppVersion is N.0.0 only for the Sparkle-era installers (1.x), which read it and so stop before
# building a newer major; installers from 2.0.0 on go by the major version instead.
/usr/bin/python3 -I - "$version" "$major.0.0" <<'EOF'
import json, sys
from pathlib import Path
path = Path('port.json')
text = path.read_text()
data = json.loads(text)
version, min_app = sys.argv[1], sys.argv[2]
# Keep the file's layout: replace the two values in place.
text = text.replace(f'"version": {json.dumps(data["version"])}', f'"version": {json.dumps(version)}', 1)
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

rm -rf "$DIST/$version"
mkdir -p "$DIST/$version"
zip="$DIST/$version/$ZIP_NAME"
if [ "$new_installer" = 1 ]; then
    say "Building TVCraft Installer $version"
    sign_identity="${identity:--}"
    [ "$dry" = 0 ] || sign_identity="-"
    # A clean build: Xcode leaves files an earlier build made in the bundle (Sparkle.framework, up to 1.x).
    rm -rf "$BUILD"
    cmake -S "$ROOT/apps/installer" -B "$BUILD" -G Xcode \
        -DTVCRAFT_VERSION="$version" -DTVCRAFT_COMMIT="$commit" \
        -DTVCRAFT_INSTALLER_SIGN_IDENTITY="$sign_identity" -DTVCRAFT_DEVELOPMENT_TEAM="$team" >/dev/null
    cmake --build "$BUILD" --config Release --target TVCraftInstaller -- -quiet
    app="$(find "$BUILD" -path '*/Release/TVCraft Installer.app' -maxdepth 3 -type d | head -1)"
    [ -n "$app" ] && [ -d "$app" ] || fail "the build made no app"

    say "Signing"
    act codesign --force --options runtime --timestamp --sign "$identity" "$app"
    act codesign --verify --deep --strict --verbose=2 "$app"

    say "Notarizing"
    ditto -c -k --keepParent "$app" "$zip"
    act xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait
    act xcrun stapler staple "$app"
    act spctl --assess --type execute --verbose=2 "$app"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
else
    say "Attaching $installer_tag's installer"
    act gh release download "$installer_tag" --repo "$REPO" --pattern "$ZIP_NAME" --dir "$DIST/$version"
    [ "$dry" = 1 ] || [ -s "$zip" ] || fail "couldn't download $ZIP_NAME from $installer_tag"
fi

say "Publishing"
if [ "$dry" = 1 ]; then
    echo "   (dry run) git push origin main $tag"
    echo "   (dry run) gh release create $tag $zip"
    if [ "$new_installer" = 1 ]; then
        echo "Dry run done: $zip (ad hoc signed)."
    else
        echo "Dry run done: game update: attaches $installer_tag's installer."
    fi
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
gh release create "$tag" "$zip" --repo "$REPO" --verify-tag \
    --title "TVCraft $version" --notes-file "$notes" $pre
echo "Published $tag: https://github.com/$REPO/releases/tag/$tag"
