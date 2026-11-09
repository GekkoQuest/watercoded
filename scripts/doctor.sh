#!/usr/bin/env bash
# Checks that this Mac can build and run Watercoded, and says how to fix anything missing.
# Usage: scripts/doctor.sh   (or `make doctor`)
set -uo pipefail

failures=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n      → %s\n" "$1" "$2"; }
fail() { printf "  \033[31m✗\033[0m %s\n      → %s\n" "$1" "$2"; failures=$((failures + 1)); }

echo "Watercoded doctor"

# macOS
major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -ge 26 ]; then ok "macOS $(sw_vers -productVersion)"; else fail "macOS $(sw_vers -productVersion)" "Watercoded needs macOS 26 or later."; fi

# Xcode (not just the Command Line Tools)
developer_dir=$(xcode-select -p 2>/dev/null || true)
if [[ "$developer_dir" == *"Xcode"*".app"* ]]; then
  version=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
  if [ "${version%%.*}" -ge 26 ] 2>/dev/null; then ok "Xcode $version"; else fail "Xcode $version" "Install Xcode 26 or later from the App Store."; fi
  if xcodebuild -license check >/dev/null 2>&1; then ok "Xcode license accepted"; else fail "Xcode license not accepted" "Open Xcode once, or run: sudo xcodebuild -license accept"; fi
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then ok "Xcode first-launch setup done"; else fail "Xcode first-launch setup pending" "Run: sudo xcodebuild -runFirstLaunch"; fi
else
  fail "Xcode isn't the active developer directory (${developer_dir:-none})" "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
fi

# Metal Toolchain (separate download since Xcode 26)
if xcrun metal --version >/dev/null 2>&1; then ok "Metal Toolchain"; else fail "Metal Toolchain missing" "Run: xcodebuild -downloadComponent MetalToolchain"; fi

# Homebrew tools
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew"
  for tool in xcodegen swiftformat swiftlint; do
    if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else fail "$tool missing" "Run: brew bundle --file=Brewfile"; fi
  done
else
  fail "Homebrew missing" "Install it from https://brew.sh"
fi

# Git identity (needed to commit; Watercoded never commits for you without asking)
if [ -n "$(git config --global user.email 2>/dev/null)" ]; then ok "git identity configured"; else
  warn "git has no user.email" 'Run: git config --global user.name "Your Name" && git config --global user.email you@example.com'
fi

# Agent CLIs (optional: the built-in demo needs none)
# Keep in sync with ClaudeCodeProvider's testedVersion and the README's Requirements.
claude_tested="2.1.319"
if command -v claude >/dev/null 2>&1; then
  claude_version=$(claude --version 2>/dev/null | awk '{print $1}')
  if [ "$claude_version" = "$claude_tested" ]; then ok "Claude Code $claude_version"; else
    warn "Claude Code $claude_version (tested with $claude_tested)" "It may work, but Watercoded relies on undocumented CLI formats. Report problems as issues."
  fi
else
  warn "Claude Code CLI not found (optional)" "Install: https://code.claude.com/docs/en/setup, then run \`claude\` once to sign in"
fi

echo
if [ "$failures" -eq 0 ]; then echo "All set."; else echo "$failures problem(s) to fix."; exit 1; fi
