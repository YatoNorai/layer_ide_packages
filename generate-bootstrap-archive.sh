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
# Uses a sentinel file to avoid re-applying on subsequent runs.
setup_bootstrap_patches() {
    local sentinel="$TERMUX_PACKAGES_DIR/.scribe-bootstrap-patched"
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

    # Use Python to make targeted fixes to generate-bootstraps.sh that cannot
    # be expressed cleanly as patch hunks without the full original source:
    #
    # Fix 1 – add_termux_bootstrap_second_stage_files() writes a profile.d
    # fallback script but never creates etc/profile.d first.  We insert a
    # mkdir -p immediately before the specific redirect/cat line that opens
    # the file for writing.  Using Python (not sed) avoids matching the same
    # filename when it appears inside the heredoc body of the fallback script.
    #
    # Fix 2 – GNU sed has no -p flag; p is an in-script command.  Any
    # 'sed -p' call would fail with "invalid option -- 'p'".  Convert those
    # occurrences to the correct 'sed -n' … '/pattern/p' idiom.
    python3 - "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

# ---- Fix 1: mkdir -p for etc/profile.d ----
FALLBACK_SCRIPT = "01-termux-bootstrap-second-stage-fallback.sh"
MKDIR_LINE = '\tmkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/profile.d"\n'

already_has_mkdir = any(
    "mkdir" in l and "profile.d" in l for l in lines
)

if not already_has_mkdir:
    new_lines = []
    in_heredoc = False
    heredoc_delim = None

    for line in lines:
        # Track heredoc boundaries so we never insert inside one
        if not in_heredoc:
            hm = re.search(r"<<\s*'?([A-Z_]+)'?", line)
            if hm and FALLBACK_SCRIPT not in line:
                # entering a heredoc that is NOT the fallback-script creator
                in_heredoc = True
                heredoc_delim = hm.group(1)
            elif (FALLBACK_SCRIPT in line
                  and re.search(r'(cat\s*>|>\s*["\x27])', line)
                  and "mkdir" not in line):
                # This is the redirect that creates the fallback script
                new_lines.append(MKDIR_LINE)
        else:
            if line.rstrip("\n") == heredoc_delim:
                in_heredoc = False
                heredoc_delim = None

        new_lines.append(line)

    lines = new_lines
    print("Fix 1 applied: mkdir -p for etc/profile.d inserted")
else:
    print("Fix 1 skipped: mkdir for profile.d already present")

# ---- Fix 2: sed -p → sed -n (GNU sed has no -p option) ----
fixed_sed = False
out_lines = []
for line in lines:
    # Match bare 'sed -p' or combined flags containing p (e.g. sed -ip, sed -np)
    # but NOT sed expressions that happen to contain 'p' as a substitute flag
    patched = re.sub(
        r'\bsed(\s+(?:-[a-zA-Z]*)?)\s+-p\b',
        lambda m: "sed" + m.group(1) + " -n",
        line,
    )
    if patched != line:
        fixed_sed = True
    out_lines.append(patched)

if fixed_sed:
    print("Fix 2 applied: replaced invalid 'sed -p' with 'sed -n'")
else:
    print("Fix 2 skipped: no 'sed -p' found")

with open(path, 'w') as f:
    f.writelines(out_lines)
PYEOF

    touch "$sentinel"
    popd || scribe_error_exit "Unable to popd from termux-packages"
}

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
    echo "Building bootstrap: $(realpath --relative-to="$(pwd)" ${bootstrap_out})"
    echo "==="
    echo

    out_dir="$script_dir/output/$arch"
    pushd "$out_dir" ||\
        scribe_error_exit "Unable to switch to output dir: ${out_dir}"

    if ! {
        set -x
        time "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" \
            --architectures "$arch" \
            --repository "$repo" \
            --add "${packages}" |&\
            tee "$out_dir/generate-bootstrap-${variant}.log"
    }; then
        scribe_error_exit "Failed to generate boostrap for ${arch} ${variant}."
    fi

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
echo "  Extra packages : ${COTG_EXTRA_PACKAGES[@]}"

for arch in aarch64 arm; do
    build_boostrap "$COTG_VARIANT" "$arch" "$COTG_REPO" "${COTG_EXTRA_PACKAGES[@]}" ||\
        scribe_error_exit "Unable to build bootstrap for ${arch}"
done
