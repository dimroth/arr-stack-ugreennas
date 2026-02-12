#!/bin/bash
# BATS test runner for arr-stack
# Usage: ./tests/run-tests.sh [test-file.bats ...]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check for bats submodule
BATS="$SCRIPT_DIR/bats-core/bin/bats"
if [[ ! -x "$BATS" ]]; then
    echo "BATS not found. Initializing submodules..."
    git -C "$REPO_ROOT" submodule update --init --recursive tests/bats-core tests/bats-support tests/bats-assert
    if [[ ! -x "$BATS" ]]; then
        echo "ERROR: Failed to install BATS. Check git submodules."
        exit 1
    fi
fi

# Run specified tests, or all *.bats files
if [[ $# -gt 0 ]]; then
    "$BATS" "$@"
else
    "$BATS" "$SCRIPT_DIR"/*.bats
fi
