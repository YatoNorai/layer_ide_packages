#!/usr/bin/env bash

set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

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
    echo "  -l        Use local packages repository."
    echo "  -r        Repository URL."
    echo "  -h        Help"
}

declare -a BOOTSTRAP_PATCHES=(
    "scripts-generate-bootstraps-CoGo-changes.patch"
    "bash-remove-recommends.patch"
)

setup_bootstrap_patches() {
    local sentinel="$TERMUX_PACKAGES_DIR/.scribe-bootstrap-patched"

    if [[ -f "$sentinel" ]]; then
        scribe_info "Patches already applied"
        return
    fi

    pushd "$TERMUX_PACKAGES_DIR" || \
        scribe_error_exit "pushd failed"

    for patch in "${BOOTSTRAP_PATCHES[@]}"; do
        patch_file="$script_dir/patches/$patch"

        [[ -f "$patch_file" ]] || \
            scribe_error_exit "Patch not found: $patch_file"

        scribe_info "Applying $patch"

        patch -p1 --no-backup-if-mismatch < "$patch_file" || \
            scribe_error_exit "Patch failed: $patch"
    done

    ########################################
    # 🔥 CORREÇÃO ROBUSTA (PYTHON)
    ########################################
    python3 - "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# =========================
# FIX 1 - mkdir profile.d
# =========================
if "profile.d" not in text:
    text = re.sub(
        r'(cat\s+>.*01-termux-bootstrap-second-stage-fallback\.sh)',
        r'mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/profile.d"\n\1',
        text
    )
    print("✔ Fix1 aplicado (mkdir profile.d)")
else:
    print("✔ Fix1 já existe")

# =========================
# FIX 2 - sed -p BUG (CRÍTICO)
# =========================
original = text

# Corrige:
# sed -p
# sed -ip
# sed -rp
# sed -n -p (sim, acontece)
text = re.sub(
    r'(?<!\S)(sed(?:\s+-[a-zA-Z]+)*)\s+-p(\s|$)',
    r'\1 -n\2',
    text
)

# fallback extra (casos extremos)
text = re.sub(r'\bsed\s+-p\b', 'sed -n', text)

if text != original:
    print("✔ Fix2 aplicado (sed -p corrigido)")
else:
    print("⚠ Nenhum sed -p encontrado (ou já corrigido)")

path.write_text(text)
PY

    ########################################

    touch "$sentinel"
    popd
}

build_boostrap() {
    variant="$1"
    arch="$2"
    repo="$3"

    shift 3
    packages=$(IFS=,; echo "$*")

    bootstrap_name="bootstrap-${arch}.zip"
    bootstrap_out="${COTG_OUTPUT_DIR}/bootstrap-${variant}-${arch}.zip"

    out_dir="$script_dir/output/$arch"
    mkdir -p "$out_dir"

    pushd "$out_dir" || \
        scribe_error_exit "cd failed"

    if ! {
        set -x
        time "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" \
            --architectures "$arch" \
            --repository "$repo" \
            --add "$packages" |& tee "log-${variant}.txt"
    }; then
        scribe_error_exit "Bootstrap FAILED ($arch)"
    fi

    mv "$bootstrap_name" "$bootstrap_out" 2>/dev/null || true
    mv "$bootstrap_name.9" "$bootstrap_out.9" 2>/dev/null || true

    popd
}

while getopts "glr:h" opt; do
    case "$opt" in
        g) COTG_RELEASE="true";;
        l) COTG_LOCAL="true";;
        r) COTG_REPO="$OPTARG";;
        h) usage; exit 0;;
        *) exit 1;;
    esac
done

shift $((OPTIND - 1))

if [[ "$COTG_LOCAL" == "true" ]]; then
    COTG_REPO="file://${COTG_REPO_DIR}"
fi

[[ -n "${COTG_REPO:-}" ]] || \
    scribe_error_exit "Repository required"

setup_bootstrap_patches

COTG_VARIANT="debug"
COTG_EXTRA_PACKAGES=("${COTG_PACKAGES__BASE[@]}")

if [[ "$COTG_RELEASE" == "true" ]]; then
    COTG_VARIANT="release"
    COTG_EXTRA_PACKAGES+=("${COTG_PACKAGES__RELEASE[@]}")
else
    COTG_EXTRA_PACKAGES+=("${COTG_PACKAGES__DEBUG[@]}")
fi

echo "Variant: $COTG_VARIANT"
echo "Repo: $COTG_REPO"

for arch in aarch64 arm; do
    build_boostrap "$COTG_VARIANT" "$arch" "$COTG_REPO" "${COTG_EXTRA_PACKAGES[@]}"
done
