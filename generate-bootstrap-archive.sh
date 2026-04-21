#!/usr/bin/env bash
set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=common.sh
. "$script_dir/common.sh"

COTG_RELEASE="false"
COTG_LOCAL="false"

usage() {
    echo "Script to generate bootstrap archives for Code On the Go."
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -g        Generate bootstrap archive for release builds."
    echo "            Defaults to ${COTG_RELEASE}."
    echo "  -l        Use local packages repository. Defaults to ${COTG_LOCAL}."
    echo "            This takes precendence over the repository provided using -r."
    echo "  -r        The repository where the built packages will be published."
    echo "            Defaults to '${COTG_REPO}'."
    echo
    echo "  -h        Show this help message and exit."
}

# === FUNÇÃO CORRIGIDA ===
normalize_bootstrap_archive() {
    local generated_zip="$1"
    local repo="$2"
    local temp_dir
    local extracted_dir
    local apt_dir
    local normalized_zip
    local normalized_zip9
    local base_name

    temp_dir=$(mktemp -d)
    extracted_dir="${temp_dir}/extracted"
    apt_dir="${extracted_dir}/etc/apt"

    mkdir -p "$extracted_dir" "$apt_dir"

    base_name=$(basename "$generated_zip")
    normalized_zip="${temp_dir}/${base_name}"
    normalized_zip9="${temp_dir}/${base_name}.9"

    # Extrai o bootstrap gerado pelo Termux
    unzip -qq "$generated_zip" -d "$extracted_dir"
    rm -f "$generated_zip" "${generated_zip}.9"

    # === CONFIGURAÇÃO DO SERVIDOR APT (o que você pediu) ===
    cat > "${apt_dir}/sources.list" <<EOF
deb ${repo} stable main
EOF

    # Cria os dois arquivos zip (igual na versão original que funcionava)
    (
        cd "$extracted_dir"
        zip -qr0 "$normalized_zip" ./*
        zip -qr9 "$normalized_zip9" ./*
    )

    # Move de volta para o local original
    mv "$normalized_zip" "$generated_zip"
    mv "$normalized_zip9" "${generated_zip}.9"

    rm -rf "$temp_dir"
}
# ========================

build_boostrap() {
    variant="$1"
    arch="$2"
    repo="$3"

    shift 3
    packages=("$@")
    packages=$(IFS=,; echo "${packages[*]}")

    if [[ -z "$variant" ]]; then
        scribe_error_exit "Target variant must not be empty"
    fi
    if [[ -z "$arch" ]]; then
        scribe_error_exit "Target arch must not be empty"
    fi
    if [[ -z "$repo" ]]; then
        scribe_error_exit "Target repo must not be empty"
    fi

    bootstrap_name="bootstrap-${arch}.zip"
    bootstrap_out="${COTG_OUTPUT_DIR}/bootstrap-${variant}-${arch}.zip"

    echo
    echo "==="
    echo "Building bootstrap: $(realpath --relative-to="$(pwd)" "${bootstrap_out}")"
    echo "==="
    echo

    out_dir="$script_dir/output/$arch"
    pushd "$out_dir" ||\
        scribe_error_exit "Unable to switch to output dir: ${out_dir}"

    if ! {
        set -x
        time "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" \
            --android10 \
            --architectures "$arch" \
            --repository "$repo" \
            --add "${packages}" |&\
            tee "$out_dir/generate-bootstrap-${variant}.log"
    }; then
        scribe_error_exit "Failed to generate boostrap for ${arch} ${variant}."
    fi

    # Normaliza (agora com sources.list do APT)
    normalize_bootstrap_archive "${bootstrap_name}" "$repo"

    # Rename the built files
    mv "${bootstrap_name}" "${bootstrap_out}"
    mv "${bootstrap_name}.9" "${bootstrap_out}.9"

    popd ||\
        scribe_error_exit "Unable to switch from output dir: ${out_dir}"
}

while getopts "glr:h" opt; do
    case "$opt" in
        g) COTG_RELEASE="true";;
        l) COTG_LOCAL="true";;
        r) COTG_REPO="$OPTARG";;
        h)
            usage
            exit 0
            ;;
        *)
            scribe_error "Invalid option" >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

if [[ "$COTG_LOCAL" == "true" ]]; then
    COTG_REPO="file://${COTG_REPO_DIR}"
fi

if [[ -z "${COTG_REPO}" ]]; then
    scribe_error_exit "A package repository URL must be specified."
fi

COTG_VARIANT="debug"
declare -a COTG_EXTRA_PACKAGES
COTG_EXTRA_PACKAGES=("${COTG_PACKAGES__BASE[@]}")

if [[ "$COTG_RELEASE" == "true" ]]; then
    COTG_VARIANT="release"
    COTG_EXTRA_PACKAGES+=("${COTG_PACKAGES__RELEASE[@]}")
else
    COTG_EXTRA_PACKAGES+=("${COTG_PACKAGES__DEBUG[@]}")
fi

echo "Using configuration:"
echo "  Variant        : ${COTG_VARIANT}"
echo "  Repository     : ${COTG_REPO}"
echo "  Extra packages : ${COTG_EXTRA_PACKAGES[@]}"

setup_termux_packages

for arch in aarch64 arm; do
    build_boostrap "$COTG_VARIANT" "$arch" "$COTG_REPO" "${COTG_EXTRA_PACKAGES[@]}" ||\
        scribe_error_exit "Unable to build bootstrap for ${arch}"
done
