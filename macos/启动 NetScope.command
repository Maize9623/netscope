#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x dist/NetScope.app/Contents/MacOS/NetScope ]; then
  /bin/bash ./build.sh
fi
open dist/NetScope.app
