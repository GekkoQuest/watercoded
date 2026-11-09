#!/bin/bash
# Install into a fresh bundle, preserving framework symlinks and avoiding stale files.
set -euo pipefail
source_app="${1:?Pass the built Watercoded.app path}"
directory="${2:-/Applications}"
mkdir -p "$directory"
directory="$(cd "$directory" && pwd -P)"
destination="$directory/Watercoded.app"
if pgrep -f "^$destination/Contents/MacOS/Watercoded( |$)" >/dev/null; then
    echo 'Quit the installed Watercoded and let its background sessions finish before replacing it.' >&2
    exit 1
fi
staging="$(mktemp -d "$directory/.watercoded-install.XXXXXX")"
trap 'rmdir "$staging" 2>/dev/null || true' EXIT
ditto "$source_app" "$staging/Watercoded.app"
codesign --verify --deep --strict "$staging/Watercoded.app"
if [ -e "$destination" ]; then
    mv "$destination" "$staging/Previous.app"
fi
if ! mv "$staging/Watercoded.app" "$destination"; then
    if [ -e "$staging/Previous.app" ]; then mv "$staging/Previous.app" "$destination"; fi
    exit 1
fi
if [ -e "$staging/Previous.app" ]; then
    # Keep recovery copies outside Spotlight so they don't appear as duplicate apps.
    backups="$directory/.watercoded-backups.noindex"
    mkdir -p "$backups"
    mv "$staging/Previous.app" "$backups/Watercoded.$(date +%Y%m%d%H%M%S).app"
fi
printf 'Installed %s\nLaunch it from Finder or Spotlight.\n' "$destination"
