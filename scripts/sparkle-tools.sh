#!/bin/bash
# Keep this version aligned with project.yml. Verify downloads before executing them.
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
directory="$PWD/.build/sparkle-tools"
archive="$directory/distribution.tar.xz"
mkdir -p "$directory"
if [ ! -f "$archive" ]; then
    curl --fail --location --silent --show-error \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check --status
if [ ! -x "$directory/bin/generate_appcast" ]; then
    tar -xJf "$archive" -C "$directory"
fi
printf '%s\n' "$directory/bin"
