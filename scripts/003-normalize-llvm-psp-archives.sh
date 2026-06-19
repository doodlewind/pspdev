#!/usr/bin/env bash

set -euo pipefail

# Normalize the core PSPSDK archives before psp-packages and psplink build
# against them. The final normalization step runs again after packages install
# their own archives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/006-normalize-llvm-psp-archives.sh"
