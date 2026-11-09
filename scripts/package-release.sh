#!/bin/bash
# Package an already built Release app; never publish or print signing material.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-.build/xcode/Build/Products/Release/Watercoded.app}"
repository="${GITHUB_REPOSITORY:-GekkoQuest/watercoded}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
tag="v$version"
if [ "${RELEASE_TAG:-${GITHUB_REF_NAME:-$tag}}" != "$tag" ]; then
    echo "Tag must match the app version ($tag)." >&2
    exit 1
fi
tools="$(scripts/sparkle-tools.sh)"
output="$PWD/.build/release/$tag"
if [ -e "$output" ]; then
    echo "Release output already exists: $output. Move it aside before packaging again." >&2
    exit 1
fi
mkdir -p "$output"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Watercoded-$version.zip"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
        --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
        --link "https://github.com/$repository/releases/tag/$tag" \
        --maximum-deltas 0 "$output"
else
    "$tools/generate_appcast" --account dev.watercoded.app \
        --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
        --link "https://github.com/$repository/releases/tag/$tag" \
        --maximum-deltas 0 "$output"
fi
# The app requires signed feeds as well as signed archives.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - "$output/appcast.xml"
else
    "$tools/sign_update" --account dev.watercoded.app "$output/appcast.xml"
fi
printf 'Release files: %s\n' "$output"
