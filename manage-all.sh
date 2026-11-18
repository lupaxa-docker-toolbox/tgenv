#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
sync=false
args=()
for arg in "$@"; do
    if [[ "${arg}" == "--sync" ]]; then
        sync=true
    else
        args+=("${arg}")
    fi
done

if [[ "${sync}" == true ]]; then
    "${repo_root}/Scripts/sync-versions.sh"
fi

if [[ ${#args[@]} -eq 0 ]]; then
    if [[ "${sync}" == true ]]; then
        exit 0
    fi
else
    set -- "${args[@]}"
fi

while IFS= read -r -d '' script; do
    "${script}" "$@"
done < <(find . -name manage.sh -print0 | sort -zVd)
