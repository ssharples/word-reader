#!/bin/bash
# Builds Word Reader from source and installs it in ~/Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/ssharples/word-reader/main/Scripts/install.sh | bash
#
# Or, from a copy of this repository: Scripts/install.sh
#
# Run it again to update. It needs no sudo and changes nothing outside
# ~/Applications/Word Reader.app and a temporary folder it deletes.
set -euo pipefail

repo="https://github.com/ssharples/word-reader.git"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$(uname)" = "Darwin" ] || fail "Word Reader is a Mac app."
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge 14 ] || fail "Word Reader needs macOS 14 (Sonoma) or later. This Mac has $macos."

if ! xcrun --find swift >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  fail "Swift isn't installed. A window should have opened to install Apple's Command Line Tools. When it finishes, run this again."
fi
swift_major="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p' | head -1)"
[ "${swift_major:-0}" -ge 6 ] ||
  fail "Word Reader needs Swift 6 or later, which comes with Xcode 16 or its Command Line Tools. This Mac has Swift ${swift_major:-unknown}. Update Xcode or the Command Line Tools in Software Update, then run this again."

# Build this copy of the repository when run from one; otherwise download it.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/build-app.sh" ] && [ -f "$here/../Package.swift" ]; then
  cd "$here/.."
else
  command -v git >/dev/null || fail "git isn't installed. Install Apple's Command Line Tools with: xcode-select --install"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  echo "Downloading Word Reader…"
  git clone --quiet --depth 1 "$repo" "$work/word-reader"
  cd "$work/word-reader"
fi

echo "Building Word Reader. The first build takes a minute or two…"
Scripts/build-app.sh --install

open "$HOME/Applications/Word Reader.app"
echo
echo "Word Reader is installed in ~/Applications and is opening now."
echo "If macOS asks whether Word Reader may use files in iCloud Drive, click Allow:"
echo "Apple Books keeps your books there."
