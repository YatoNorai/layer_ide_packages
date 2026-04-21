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
    echo "            This takes precedence over the repository provided using -r."
    echo "  -r        The repository where the built packages will be published."
    echo "            Defaults to '${COTG_REPO:-}'."
    echo
    echo "  -h        Show this help message and exit."
}

# Patches that must be applied to termux-packages before generating bootstraps.
# These are a subset of the patches in build.sh that affect the bootstrap
# generation process itself (not package builds).
declare -a BOOTSTRAP_PATCHES=(
    # Removes command-not-found from the list of packages pulled into the
    # bootstrap by generate-bootstraps.sh (also adds brotli archive creation).
    "scripts-generate-bootstraps-CoGo-changes.patch"

    # bash lists command-not-found as Recommends; some build system versions
    # promote it to Depends in the control file, causing bootstrap to fail
    # when the package is not in the repo. Remove the Recommends entirely.
    "bash-remove-recommends.patch"
)

# Apply bootstrap-specific patches to termux-packages if not already done.
# Uses a versioned sentinel so fixes can be reapplied when this script changes.
setup_bootstrap_patches() {
    local sentinel="$TERMUX_PACKAGES_DIR/.scribe-bootstrap-patched-v2"

    if [[ -f "$sentinel" ]]; then
        scribe_info "Bootstrap patches already applied, skipping."
        return 0
    fi

    scribe_info "Applying bootstrap patches to termux-packages..."
    pushd "$TERMUX_PACKAGES_DIR" || \
        scribe_error_exit "Unable to pushd into termux-packages"

    for patch in "${BOOTSTRAP_PATCHES[@]}"; do
        local patch_file="$script_dir/patches/$patch"
        if [[ ! -f "$patch_file" ]]; then
            scribe_error_exit "Patch file not found: $patch_file"
        fi
        scribe_info "Applying patch: ${patch}"
        if patch -p1 --no-backup-if-mismatch < "$patch_file"; then
            scribe_ok "Applied '${patch}'"
        else
            scribe_error_exit "Failed to apply '${patch}'"
        fi
    done

    # Targeted fixes for generate-bootstraps.sh
    python3 - "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" <<'PYEOF'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)

mkdir_line = '\tmkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/profile.d"\n'
fallback_script = "01-termux-bootstrap-second-stage-fallback.sh"

# -------------------------------------------------------------------
# Fix 1:
# Ensure etc/profile.d exists before writing the fallback script.
# Insert mkdir -p immediately before the line that creates that file.
# -------------------------------------------------------------------
new_lines = []
inserted_mkdir = False

for line in lines:
    if (
        not inserted_mkdir
        and fallback_script in line
        and ">" in line
    ):
        # Avoid inserting more than once if script is rerun on the same file
        already_has_mkdir_nearby = any(
            mkdir_line.strip() in prev_line
            for prev_line in new_lines[-5:]
        )
        if not already_has_mkdir_nearby:
            new_lines.append(mkdir_line)
            inserted_mkdir = True

    new_lines.append(line)

lines = new_lines

# -------------------------------------------------------------------
# Fix 2:
# GNU sed does not support "-p" as a flag. Replace invalid usages with
# "-n". This catches cases like:
#   sed -p
#   sed -ip
#   sed -rp
# -------------------------------------------------------------------
text = "".join(lines)

# Replace a standalone "-p" option that is being used as a sed flag.
text2 = re.sub(
    r'(?<!\S)(sed(?:\s+-[A-Za-z]+)*)\s+-p(\s|$)',
    r'\1 -n\2',
    text,
)

# Extra fallback for direct occurrences.
text2 = re.sub(r'\bsed\s+-p\b', 'sed -n', text2)

path.write_text(text2)

print("generate-bootstraps.sh patched successfully")
PYEOF

    # Validation so the script fails early if the fix was not applied.
    if ! grep -q 'mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/profile.d"' \
        "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh"; then
        scribe_error_exit "Failed to patch generate-bootstraps.sh with mkdir for etc/profile.d"
    fi

    if grep -qE '\bsed\b.*\s-p\b' "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh"; then
        scribe_error_exit "Invalid sed -p still present in generate-bootstraps.sh"
    fi

    touch "$sentinel"
    popd || scribe_error_exit "Unable to popd from termux-packages"
}

build_boostrap() {
    local variant="$1"
    local arch="$2"
    local repo="$3"

    shift 3
    local packages=("$@")
    local packages_joined
    packages_joined=$(IFS=,; echo "${packages[*]}")

    if [[ -z "$variant" ]]; then
        scribe_error_exit "Target variant must not be empty"
    fi

    if [[ -z "$arch" ]]; then
        scribe_error_exit "Target arch must not be empty"
    fi

    if [[ -z "$repo" ]]; then
        scribe_error_exit "Target repo must not be empty"
    fi

    local bootstrap_name="bootstrap-${arch}.zip"
    local bootstrap_out="${COTG_OUTPUT_DIR}/bootstrap-${variant}-${arch}.zip"

    echo
    echo "==="
    echo "Building bootstrap: $(realpath --relative-to="$(pwd)" "${bootstrap_out}")"
    echo "==="
    echo

    local out_dir="$script_dir/output/$arch"
    mkdir -p "$out_dir"

    pushd "$out_dir" || \
        scribe_error_exit "Unable to switch to output dir: ${out_dir}"

    if ! {
        set -x
        time "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" \
            --architectures "$arch" \
            --repository "$repo" \
            --add "$packages_joined" |& tee "$out_dir/generate-bootstrap-${variant}.log"
    }; then
        scribe_error_exit "Failed to generate bootstrap for ${arch} ${variant}."
    fi

    mv "${bootstrap_name}" "${bootstrap_out}"
    mv "${bootstrap_name}.9" "${bootstrap_out}.9"

    popd || \
        scribe_error_exit "Unable to switch from output dir: ${out_dir}"
}

while getopts "glr:h" opt; do
    case "$opt" in
        g) COTG_RELEASE="true" ;;
        l) COTG_LOCAL="true" ;;
        r) COTG_REPO="$OPTARG" ;;
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

if [[ -z "${COTG_REPO:-}" ]]; then
    scribe_error_exit "A package repository URL must be specified."
fi

# Apply patches needed by the bootstrap generation before running
# generate-bootstraps.sh. This is required when the bootstrap workflow
# runs independently of build.sh (which normally applies these patches).
setup_bootstrap_patches

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
echo "  Extra packages : ${COTG_EXTRA_PACKAGES[*]}"

for arch in aarch64 arm; do
    build_boostrap "$COTG_VARIANT" "$arch" "$COTG_REPO" "${COTG_EXTRA_PACKAGES[@]}" || \
        scribe_error_exit "Unable to build bootstrap for ${arch}"
done
