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
# Build dependencies for the Lambda runtime (Python 3.12 on Linux x86_64),
# not the local interpreter ABI.
python3 -m pip install \
  --upgrade \
  --only-binary=:all: \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  -r "$LAMBDA_SRC_DIR/requirements.txt" \
  -t "$LAMBDA_BUILD_DIR"

echo "Lambda package directory ready: $LAMBDA_BUILD_DIR"
