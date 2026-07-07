#!/usr/bin/env bash
set -euo pipefail
f() { return 1; }
f
echo "reached"
