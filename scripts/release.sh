#!/bin/zsh
# Cuts a release: scripts/release.sh 0.2.0
#
# Before running, move the notes from "## [Unreleased]" in CHANGELOG.md into a "## [0.2.0] - <date>"
# section. This script then sets VERSION, commits, tags v0.2.0 and pushes; the Release workflow on
# GitHub builds, tests and publishes the release with those notes.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version>, e.g. 0.2.0}
TAG="v$VERSION"

[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Release from main"; exit 1; }
[[ -z $(git status --porcelain -- ':!CHANGELOG.md') ]] || { echo "Commit or stash other changes first"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists"; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no '## [$VERSION]' section"; exit 1; }

git pull --ff-only
echo "$VERSION" > VERSION
./build.sh
./scripts/test.sh

git add VERSION CHANGELOG.md
git commit -m "Release $TAG"
git tag -a "$TAG" -m "MacFrameGen $VERSION"
git push origin main "$TAG"
echo "Pushed $TAG. Follow the release at https://github.com/PabloVSouza/MacFrameGen/actions"
