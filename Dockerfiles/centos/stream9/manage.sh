#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
repo_root=$(git rev-parse --show-toplevel)
exec "${repo_root}/Scripts/core.sh" "$@"
