#!/bin/zsh
# Prints the CHANGELOG.md section for a version: scripts/release-notes.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
awk -v v="$1" '
  /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  /^\[.*\]: / { next }
  found { print }
' CHANGELOG.md
