#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r -d '' script; do
    "${script}" "$@"
done < <(find . -name manage.sh -print0 | sort -zVd)
