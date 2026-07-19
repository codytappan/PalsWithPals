#!/usr/bin/env zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAMBDA_SRC_DIR="$REPO_ROOT/lambda"
LAMBDA_BUILD_DIR="$REPO_ROOT/build/lambda-package"

rm -rf "$LAMBDA_BUILD_DIR"
mkdir -p "$LAMBDA_BUILD_DIR"

cp "$LAMBDA_SRC_DIR/lambda_handler.py" "$LAMBDA_BUILD_DIR/"
cp "$LAMBDA_SRC_DIR/requirements.txt" "$LAMBDA_BUILD_DIR/"

# register_commands.py is a local utility, not required at runtime.
python3 -m pip install -r "$LAMBDA_SRC_DIR/requirements.txt" -t "$LAMBDA_BUILD_DIR"

echo "Lambda package directory ready: $LAMBDA_BUILD_DIR"
