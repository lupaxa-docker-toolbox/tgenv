#!/usr/bin/env bash
#
# Generate, build, and publish one image in this tree.
#
# manage.sh cds into Dockerfiles/<os>/<version> and execs this script.
# The directory names are the operating system and the tag. Debian uses the
# numeric tag. CentOS Stream is the directory "centos" and the image
# quay.io/centos/centos. Alpine uses ash. Slim and minimal images use sh.
# Arch Linux is built and queried as linux/amd64. IMAGE_SHELL overrides the
# entrypoint. Version Helper still uses the base image shell.
#
# Generate reads Templates/Dockerfile.tpl and replaces the @@TOKENS@@.
# When Config/packages.cfg has a package list, generate downloads
# get-versions and version-grabber from version-helper and inserts the
# pinned install fragment. An empty package list skips that download.
#
# Build passes IMAGE_CREATED. Publish pushes every tag, including latest
# and any extra tags from manage.sh. --ghcr selects GHCR. Otherwise
# the image is pushed to DOCKER_HUB_ORG on Docker Hub. A GHCR push sets
# the manifest annotation org.opencontainers.image.source so GitHub links
# the package to this repository. A plain docker push does not. GitHub
# has no API to change an organisation package between public and private.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HELPER_ROOT="${REPO_ROOT}/Helpers"
GET_VERSIONS="${HELPER_ROOT}/get-versions"
VERSION_GRABBER="${HELPER_ROOT}/version-grabber"

GET_VERSIONS_URL='https://raw.githubusercontent.com/lupaxa-docker-toolbox/version-helper/master/src/get-versions'
VERSION_GRABBER_URL='https://raw.githubusercontent.com/lupaxa-docker-toolbox/version-helper/master/src/version-grabber'

USE_COLOURS=true
FORCE_TERMINAL=true

GENERATE=false
BUILD=false
CLEAN=false
LATEST=false
PUBLISH=false
GHCR=false
ADDITIONAL_TAGS=""

abort() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    local status=${1:-0}
    if [[ $# -gt 1 ]]; then
        printf 'error: %s\n' "$2" >&2
    fi
    cat <<'EOF'
Usage: manage.sh [-h] [-d] [-g] [-b] [-c] [-p] [-G] [-l] [-t tag]

Generate, build, and publish the image for this directory. Combine
-g, -b, and -p to run more than one step.

  -h, --help       Show this help
  -d, --debug      Trace this script
  -g, --generate   Write the Dockerfile
  -b, --build      Build the image
  -c, --clean      Build without the cache
  -p, --publish    Push the image
  -G, --ghcr       Push to GHCR instead of Docker Hub
  -l, --latest     Also tag latest
  -t, --tags       Extra publish tag (repeatable)
EOF
    exit "$status"
}

init_colours() {
    fgRed=''
    fgGreen=''
    fgYellow=''
    fgCyan=''
    bold=''
    reset=''

    if [[ "${USE_COLOURS}" == false ]]; then
        return
    fi
    if ! test -t 1; then
        if [[ "${FORCE_TERMINAL}" == true ]]; then
            export TERM=xterm
        else
            return
        fi
    fi
    if ! tput longname >/dev/null 2>&1; then
        return
    fi

    local ncolors
    ncolors=$(tput colors)
    if [[ -z "${ncolors}" || "${ncolors}" -le 7 ]]; then
        return
    fi

    fgRed=$(tput setaf 1)
    fgGreen=$(tput setaf 2)
    fgYellow=$(tput setaf 3)
    fgCyan=$(tput setaf 6)
    bold=$(tput bold)
    reset=$(tput sgr0)
}

notify() {
    local type=${1:-}
    shift
    local message=${*:-}
    local fgColor=''

    [[ -n "${message}" ]] || return 0
    case "${type}" in
        error) fgColor=${fgRed} ;;
        warning) fgColor=${fgYellow} ;;
        success) fgColor=${fgGreen} ;;
        info) fgColor=${fgCyan} ;;
        *) fgColor='' ;;
    esac
    printf '%s%s%s%s\n' "${fgColor}" "${bold}" "${message}" "${reset}" >&2
}

info() { notify info "$@"; }
warn() { notify warning "$@"; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || abort "$1 is not in your command path"
}

hash_stdin() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q
    else
        abort "md5sum or md5 is required to refresh version-helper"
    fi
}

hash_file() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    else
        abort "md5sum or md5 is required to refresh version-helper"
    fi
}

download_helper() {
    local filename=$1
    local url=$2
    curl --fail --silent --show-error --location --output "${filename}" "${url}"
    chmod 755 "${filename}"
}

ensure_helper() {
    local filename=$1
    local url=$2
    local online_md5
    local local_md5

    if [[ ! -f "${filename}" ]]; then
        download_helper "${filename}" "${url}"
        return
    fi
    online_md5=$(curl --fail --silent --show-error --location "${url}" | hash_stdin)
    local_md5=$(hash_file "${filename}")
    if [[ "${online_md5}" != "${local_md5}" ]]; then
        download_helper "${filename}" "${url}"
    fi
}

ensure_version_helper() {
    require_command curl
    mkdir -p "${HELPER_ROOT}"
    ensure_helper "${GET_VERSIONS}" "${GET_VERSIONS_URL}"
    ensure_helper "${VERSION_GRABBER}" "${VERSION_GRABBER_URL}"
}

# True when a package list has a value. DISCOVER_BY alone does not count.
packages_configured() {
    local line key value
    [[ -f "${REPO_ROOT}/Config/packages.cfg" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z "${line}" || "${line}" != *=* ]] && continue
        key=${line%%=*}
        key=${key%"${key##*[![:space:]]}"}
        [[ "${key}" == "DISCOVER_BY" ]] && continue
        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        if [[ -n "${value}" ]]; then
            return 0
        fi
    done < "${REPO_ROOT}/Config/packages.cfg"
    return 1
}

image_name_for() {
    case "$1" in
        centos) printf '%s\n' 'quay.io/centos/centos' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

shell_for() {
    local os=$1
    local version=$2
    case "${version}" in
        *slim | *minimal)
            printf '%s\n' sh
            return
            ;;
    esac
    case "${os}" in
        alpine) printf '%s\n' ash ;;
        *) printf '%s\n' bash ;;
    esac
}

shell_path() {
    case "$1" in
        ash) printf '%s\n' /bin/ash ;;
        sh) printf '%s\n' /bin/sh ;;
        bash) printf '%s\n' /bin/bash ;;
        *) abort "IMAGE_SHELL must be ash, sh, or bash (got: $1)" ;;
    esac
}

entrypoint_for() {
    if [[ -n "${IMAGE_SHELL:-}" ]]; then
        shell_path "${IMAGE_SHELL}"
        return
    fi
    shell_path "$(shell_for "$1" "$2")"
}

read_fragment() {
    local path=$1
    [[ -f "${path}" ]] || abort "${path} is missing"
    # Command substitution drops the trailing newlines. Callers put one back.
    printf '%s' "$(<"${path}")"
}

ensure_trailing_newline() {
    local name=$1
    local value=${!name}
    if [[ -n "${value}" && "${value}" != *$'\n' ]]; then
        printf -v "${name}" '%s\n' "${value}"
    fi
}

get_git_url() {
    local url host path
    url=$(git remote get-url origin) || abort "git remote origin is not set"
    url=${url%.git}
    if [[ "${url}" == git@*:* ]]; then
        host=${url#git@}
        host=${host%%:*}
        path=${url#*:}
    else
        url=${url#ssh://}
        url=${url#https://}
        url=${url#http://}
        host=${url%%/*}
        path=${url#*/}
    fi
    printf 'https://%s/%s\n' "${host}" "${path}"
}

setup_container_details() {
    local parts=()
    local part
    IFS='/' read -ra parts <<< "$(pwd)"
    part=${parts[${#parts[@]}-1]}
    if [[ "${SINGLE_OS}" == true ]]; then
        [[ -n "${SINGLE_OS_NAME}" ]] || abort "SINGLE_OS_NAME is empty in Config/config.cfg"
        CONTAINER_OS_NAME=${SINGLE_OS_NAME}
    else
        CONTAINER_OS_NAME=${parts[${#parts[@]}-2]}
    fi
    CONTAINER_OS_VERSION_RAW=${part}
    CONTAINER_OS_VERSION=${part//./-}
    CONTAINER_OS_VERSION_ALT=${CONTAINER_OS_VERSION_RAW}
    CONTAINER_IMAGE_NAME=$(image_name_for "${CONTAINER_OS_NAME}")

    if [[ "${NO_OS_NAME_IN_CONTAINER}" == true ]]; then
        LOCAL_CONTAINER_NAME="${CONTAINER_PREFIX}-${CONTAINER_OS_VERSION}"
        PUBLISHED_CONTAINER_NAME=${CONTAINER_PREFIX}
    else
        LOCAL_CONTAINER_NAME="${CONTAINER_PREFIX}-${CONTAINER_OS_NAME}-${CONTAINER_OS_VERSION}"
        PUBLISHED_CONTAINER_NAME="${CONTAINER_PREFIX}-${CONTAINER_OS_NAME}"
    fi
    LOCAL_CONTAINER_NAME=${LOCAL_CONTAINER_NAME//./-}
}

render_dockerfile() {
    local template="${REPO_ROOT}/Templates/Dockerfile.tpl"
    [[ -f "${template}" ]] || abort "${template} is missing"
    require_command python3
    export CONTAINER_IMAGE_NAME CONTAINER_OS_VERSION_ALT
    export LABELS PACKAGES INSTALL CLEANUP ENTRYPOINT_PATH GIT_URL
    python3 - "${template}" Dockerfile <<'PY'
import os
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
mapping = {
    "@@CONTAINER_IMAGE_NAME@@": os.environ["CONTAINER_IMAGE_NAME"],
    "@@CONTAINER_OS_VERSION_ALT@@": os.environ["CONTAINER_OS_VERSION_ALT"],
    "@@LABELS@@": os.environ.get("LABELS", ""),
    "@@PACKAGES@@": os.environ.get("PACKAGES", ""),
    "@@INSTALL@@": os.environ.get("INSTALL", ""),
    "@@CLEANUP@@": os.environ.get("CLEANUP", ""),
    "@@ENTRYPOINT@@": os.environ["ENTRYPOINT_PATH"],
    "@@GIT_URL@@": os.environ["GIT_URL"],
}
for key, value in mapping.items():
    if key not in text:
        sys.stderr.write(f"error: {sys.argv[1]} is missing {key}\n")
        sys.exit(1)
    text = text.replace(key, value)
Path(sys.argv[2]).write_text(text)
PY
}

generate_container() {
    local container_shell
    info "Generating Dockerfile for ${LOCAL_CONTAINER_NAME}"

    CLEANUP=$(read_fragment "Templates/cleanup.tpl")
    INSTALL=$(read_fragment "${REPO_ROOT}/Templates/install.tpl")
    if [[ -f "${REPO_ROOT}/Config/labels.cfg" ]]; then
        LABELS=$(read_fragment "${REPO_ROOT}/Config/labels.cfg")
    else
        LABELS=''
    fi

    container_shell=$(shell_for "${CONTAINER_OS_NAME}" "${CONTAINER_OS_VERSION_RAW}")
    ENTRYPOINT_PATH=$(entrypoint_for "${CONTAINER_OS_NAME}" "${CONTAINER_OS_VERSION_RAW}")
    PACKAGES=''
    if packages_configured; then
        local -a args
        require_command docker
        ensure_version_helper
        args=(
            -g "${VERSION_GRABBER}"
            -p
            -c "${REPO_ROOT}/Config/packages.cfg"
            -o "${CONTAINER_IMAGE_NAME}"
            -t "${CONTAINER_OS_VERSION_ALT}"
            -s "${container_shell}"
        )
        if [[ "${CONTAINER_OS_NAME}" == "archlinux" ]]; then
            args+=(-P linux/amd64)
        fi
        if ! PACKAGES=$("${GET_VERSIONS}" "${args[@]}"); then
            abort "version-helper could not resolve packages for ${CONTAINER_IMAGE_NAME}:${CONTAINER_OS_VERSION_ALT}"
        fi
    fi

    ensure_trailing_newline LABELS
    ensure_trailing_newline PACKAGES
    ensure_trailing_newline INSTALL
    ensure_trailing_newline CLEANUP
    GIT_URL=$(get_git_url)
    render_dockerfile
    info "Complete"
}

build_container() {
    local created
    local -a cmd
    require_command docker
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cmd=(docker build --pull --build-arg "IMAGE_CREATED=${created}")
    if [[ "${CLEAN}" == true ]]; then
        cmd+=(--no-cache)
        info "Clean building ${LOCAL_CONTAINER_NAME}"
    else
        info "Building ${LOCAL_CONTAINER_NAME}"
    fi
    if [[ "${CONTAINER_OS_NAME}" == "archlinux" ]]; then
        cmd+=(--platform linux/amd64)
    fi
    cmd+=(-t "${LOCAL_CONTAINER_NAME}" .)
    "${cmd[@]}"
    info "Complete"
}

get_image_id() {
    local image_id
    image_id=$(docker images -q "${LOCAL_CONTAINER_NAME}" | head -n 1)
    [[ -n "${image_id}" ]] || abort "Unable to locate image ID for ${LOCAL_CONTAINER_NAME}"
    printf '%s\n' "${image_id}"
}

publish_single_version() {
    local image_id=$1
    local tag=$2
    info "Publishing ${LOCAL_CONTAINER_NAME} (${image_id}) to ${PUBLISHED_CONTAINER_NAME_FULL}:${tag}"
    docker tag "${image_id}" "${PUBLISHED_CONTAINER_NAME_FULL}:${tag}"
    docker push "${PUBLISHED_CONTAINER_NAME_FULL}:${tag}"
}

# GitHub links a container package to a repository from the manifest
# annotation, not from the image config label. buildx writes that
# annotation while it pushes. Index annotations are rejected for a
# single-platform image.
publish_ghcr() {
    local source_url platform work tag
    local -a cmd
    source_url=$(get_git_url)
    platform=$(docker image inspect "${LOCAL_CONTAINER_NAME}" --format '{{.Os}}/{{.Architecture}}')
    [[ -n "${platform}" && "${platform}" != "/" ]] || abort "Unable to read the platform of ${LOCAL_CONTAINER_NAME}"
    docker buildx version >/dev/null 2>&1 || abort "docker buildx is required to publish to GHCR"
    cmd=(
        docker buildx build
        --push
        --provenance=false
        --sbom=false
        --platform "${platform}"
        --build-context "base=docker-image://${LOCAL_CONTAINER_NAME}"
        --annotation "manifest:org.opencontainers.image.source=${source_url}"
    )
    for tag in "$@"; do
        info "Publishing ${LOCAL_CONTAINER_NAME} to ${PUBLISHED_CONTAINER_NAME_FULL}:${tag}"
        cmd+=(-t "${PUBLISHED_CONTAINER_NAME_FULL}:${tag}")
    done
    cmd+=(-f - .)
    work=$(mktemp -d)
    (
        cd "${work}"
        "${cmd[@]}" <<'EOF'
FROM base
EOF
    )
    rm -rf "${work}"
}

publish_container() {
    local tag_string image_id tag
    local -a publish_tags=()
    require_command docker
    if [[ "${GHCR}" == true ]]; then
        [[ -n "${GHCR_ORGNAME}" ]] || abort "GHCR_ORGNAME is empty in Config/config.cfg"
        PUBLISHED_CONTAINER_NAME_FULL="ghcr.io/${GHCR_ORGNAME}/${PUBLISHED_CONTAINER_NAME}"
    else
        [[ -n "${DOCKER_HUB_ORG}" ]] || abort "DOCKER_HUB_ORG is empty in Config/config.cfg. Set it, or pass --ghcr."
        PUBLISHED_CONTAINER_NAME_FULL="${DOCKER_HUB_ORG}/${PUBLISHED_CONTAINER_NAME}"
    fi

    tag_string="${CONTAINER_OS_VERSION_RAW}${ADDITIONAL_TAGS}"
    if [[ "${LATEST}" == true ]]; then
        tag_string+=",latest"
    fi

    image_id=$(get_image_id)
    IFS=',' read -ra publish_tags <<< "${tag_string}"
    local -a tags=()
    for tag in "${publish_tags[@]}"; do
        tag=${tag#"${tag%%[![:space:]]*}"}
        tag=${tag%"${tag##*[![:space:]]}"}
        [[ -n "${tag}" ]] || continue
        tags+=("${tag}")
    done
    [[ ${#tags[@]} -gt 0 ]] || abort "No tags to publish for ${LOCAL_CONTAINER_NAME}"

    if [[ "${GHCR}" == true ]]; then
        publish_ghcr "${tags[@]}"
    else
        for tag in "${tags[@]}"; do
            publish_single_version "${image_id}" "${tag}"
        done
    fi
    info "Complete"
}

process_options() {
    if [[ $# -eq 0 ]]; then
        usage 1 "Choose generate, build, or publish"
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage 0
                ;;
            -d | --debug)
                set -x
                shift
                ;;
            -b | --build)
                BUILD=true
                shift
                ;;
            -c | --clean)
                CLEAN=true
                shift
                ;;
            -g | --generate)
                GENERATE=true
                shift
                ;;
            -p | --publish)
                PUBLISH=true
                shift
                ;;
            -l | --latest)
                LATEST=true
                shift
                ;;
            -G | --ghcr)
                GHCR=true
                shift
                ;;
            -t | --tags)
                [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] || usage 1 "--tags needs a value"
                ADDITIONAL_TAGS+=",$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage 1 "unknown option: $1"
                ;;
            *)
                usage 1 "unexpected argument: $1"
                ;;
        esac
    done

    if [[ "${GENERATE}" != true && "${BUILD}" != true && "${PUBLISH}" != true ]]; then
        usage 1 "Choose generate, build, or publish"
    fi
    if [[ "${GENERATE}" == true ]]; then
        generate_container
    fi
    if [[ "${BUILD}" == true ]]; then
        build_container
    fi
    if [[ "${PUBLISH}" == true ]]; then
        publish_container
    fi
}

main() {
    init_colours
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/Config/config.cfg"
    setup_container_details
    process_options "$@"
}

main "$@"
