#!/usr/bin/env bash
# Point git at the repo-tracked hooks directory. Run once per fresh clone.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "git hooks installed: $(git config --get core.hooksPath)"
