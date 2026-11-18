#!/usr/bin/env bash
#
# Rewrite Dockerfiles/<os>/<tag> from the version catalogue.
#
# Container Framework reads Config/versions.cfg. Every other image
# repository downloads that file from Container Framework master.
# Config/os.cfg lists the families this repository builds. Sync keeps
# those rows and removes the rest. SINGLE_OS=true writes
# Dockerfiles/<tag>/, with the cleanup link three levels up.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
source "${repo_root}/Config/config.cfg"

catalogue_url='https://raw.githubusercontent.com/lupaxa-docker-toolbox/container-framework/master/Config/versions.cfg'
downloaded=''

abort() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${downloaded}" ]]; then
        rm -f "${downloaded}"
    fi
}
trap cleanup EXIT

catalogue_file() {
    local local_file="${repo_root}/Config/versions.cfg"
    if [[ -f "${local_file}" ]]; then
        printf '%s\n' "${local_file}"
        return
    fi
    command -v curl >/dev/null 2>&1 || abort "curl is required to download the version catalogue"
    downloaded=$(mktemp)
    curl --fail --silent --show-error --location --output "${downloaded}" "${catalogue_url}" \
        || abort "could not download the version catalogue"
    printf '%s\n' "${downloaded}"
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

load_os_list() {
    local file="${repo_root}/Config/os.cfg"
    local line name count
    [[ -f "${file}" ]] || abort "Config/os.cfg is missing"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n "${line}" ]] || continue
        [[ "${line}" != *" "* ]] || abort "Config/os.cfg lists one family per line: ${line}"
        valid_name "${line}" || abort "invalid family in Config/os.cfg: ${line}"
        if grep -qx "${line}" "${os_list}"; then
            abort "Config/os.cfg repeats ${line}"
        fi
        printf '%s\n' "${line}" >> "${os_list}"
    done < "${file}"
    [[ -s "${os_list}" ]] || abort "Config/os.cfg is empty"
    if [[ "${SINGLE_OS}" == true ]]; then
        count=$(wc -l < "${os_list}" | tr -d '[:space:]')
        [[ "${count}" == 1 ]] || abort "SINGLE_OS=true needs one family in Config/os.cfg"
        name=$(head -n 1 "${os_list}")
        [[ "${name}" == "${SINGLE_OS_NAME}" ]] \
            || abort "SINGLE_OS_NAME is ${SINGLE_OS_NAME} but Config/os.cfg lists ${name}"
    fi
}

manage_script() {
    local flags=$1
    cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

cd "\$(dirname "\$0")"
repo_root=\$(git rev-parse --show-toplevel)
exec "\${repo_root}/Scripts/core.sh" "\$@"${flags}
EOF
}

write_family_manage_all() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r -d '' script; do
    "${script}" "$@"
done < <(find . -name manage.sh -print0 | sort -zVd)
EOF
    chmod 755 "$1"
}

write_tree() {
    local catalogue=$1
    local line family tag cleanup flag flags extra latest_flag
    local -a fields
    local dir link_target relative

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n "${line}" ]] || continue
        # shellcheck disable=SC2206
        fields=(${line})
        [[ ${#fields[@]} -ge 3 ]] || abort "catalogue row needs a family, tag, and cleanup: ${line}"
        family=${fields[0]}
        tag=${fields[1]}
        cleanup=${fields[2]}
        valid_name "${family}" || abort "invalid family: ${family}"
        valid_name "${tag}" || abort "invalid tag: ${tag}"
        valid_name "${cleanup}" || abort "invalid cleanup: ${cleanup}"
        grep -qx "${family}" "${os_list}" || continue
        [[ -f "${repo_root}/Templates/${cleanup}-cleanup.tpl" ]] \
            || abort "Templates/${cleanup}-cleanup.tpl is missing"
        grep -qx "${family}" "${seen}" || printf '%s\n' "${family}" >> "${seen}"

        flags=''
        latest_flag=false
        for flag in "${fields[@]:3}"; do
            case "${flag}" in
                latest)
                    [[ "${latest_flag}" == false ]] || abort "${family} ${tag} repeats latest"
                    if grep -qx "${family}" "${families}"; then
                        abort "${family} already has a latest tag"
                    fi
                    latest_flag=true
                    flags+=' --latest'
                    ;;
                tag:*)
                    extra=${flag#tag:}
                    valid_name "${extra}" || abort "invalid extra tag: ${extra}"
                    flags+=" --tags ${extra}"
                    ;;
                *)
                    abort "unknown flag: ${flag}"
                    ;;
            esac
        done
        if [[ "${latest_flag}" == true ]]; then
            printf '%s\n' "${family}" >> "${families}"
        fi

        if [[ "${SINGLE_OS}" == true ]]; then
            dir="${repo_root}/Dockerfiles/${tag}"
            link_target="../../../Templates/${cleanup}-cleanup.tpl"
            relative="${tag}"
        else
            dir="${repo_root}/Dockerfiles/${family}/${tag}"
            link_target="../../../../Templates/${cleanup}-cleanup.tpl"
            relative="${family}/${tag}"
            mkdir -p "${repo_root}/Dockerfiles/${family}"
            write_family_manage_all "${repo_root}/Dockerfiles/${family}/manage-all.sh"
        fi

        mkdir -p "${dir}/Templates"
        manage_script "${flags}" > "${dir}/manage.sh"
        chmod 755 "${dir}/manage.sh"
        ln -sfn "${link_target}" "${dir}/Templates/cleanup.tpl"
        printf '%s\n' "${relative}" >> "${keep}"
    done < "${catalogue}"

    while IFS= read -r family || [[ -n "${family}" ]]; do
        grep -qx "${family}" "${seen}" || abort "catalogue has no rows for ${family}"
    done < "${os_list}"

    if [[ "${SINGLE_OS}" == true ]]; then
        prune_single "${keep}"
    else
        prune_families "${keep}"
    fi
}

prune_single() {
    local keep=$1
    local dir name
    local -a remove=()
    shopt -s nullglob
    for dir in "${repo_root}/Dockerfiles"/*/; do
        name=$(basename "${dir}")
        [[ -f "${dir}/manage.sh" ]] || continue
        if ! grep -qx "${name}" "${keep}"; then
            remove+=("${dir}")
        fi
    done
    shopt -u nullglob
    if [[ ${#remove[@]} -gt 0 ]]; then
        rm -rf "${remove[@]}"
    fi
}

prune_families() {
    local keep=$1
    local family_dir version_dir family version leftover
    local -a remove=()
    shopt -s nullglob
    for family_dir in "${repo_root}/Dockerfiles"/*/; do
        family=$(basename "${family_dir}")
        for version_dir in "${family_dir}"*/; do
            version=$(basename "${version_dir}")
            [[ -f "${version_dir}/manage.sh" ]] || continue
            if ! grep -qx "${family}/${version}" "${keep}"; then
                remove+=("${version_dir}")
            fi
        done
    done
    if [[ ${#remove[@]} -gt 0 ]]; then
        rm -rf "${remove[@]}"
    fi
    for family_dir in "${repo_root}/Dockerfiles"/*/; do
        leftover=false
        for version_dir in "${family_dir}"*/; do
            if [[ -f "${version_dir}/manage.sh" ]]; then
                leftover=true
            fi
        done
        if [[ "${leftover}" == false ]]; then
            rm -rf "${family_dir}"
        fi
    done
    shopt -u nullglob
}

os_list=$(mktemp)
keep=$(mktemp)
families=$(mktemp)
seen=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '${os_list}' '${keep}' '${families}' '${seen}'; cleanup" EXIT

load_os_list

root_manage_all="${repo_root}/Dockerfiles/manage-all.sh"
if [[ ! -f "${root_manage_all}" ]]; then
    write_family_manage_all "${root_manage_all}"
fi

write_tree "$(catalogue_file)"
printf 'Synced version directories from the catalogue.\n'
