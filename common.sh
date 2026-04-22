set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=utils.sh
. "$script_dir/utils.sh"

# shellcheck source=packages.sh
. "$script_dir/packages.sh"

# The directory where the termux-packages repository
# is cloned
TERMUX_PACKAGES_DIR="$script_dir/termux-packages"
export TERMUX_PACKAGES_DIR

# Package name of the Termux application
# Should not be changed
TERMUX_PACKAGE_NAME="com.termux"
export TERMUX_PACKAGE_NAME

# The package name of the intended application
COTG_PACKAGE_NAME="com.layer.ide"
export COTG_PACKAGE_NAME

# Path to the public key
# this is used for signature verification
# while installing packages
COTG_GPG_KEY="$script_dir/layer-ide.gpg"
export COTG_GPG_KEY

# Configure build environment variables
TERMUX_SCRIPTDIR="$TERMUX_PACKAGES_DIR"
export TERMUX_SCRIPTDIR

# The target SDK version of the final Android application
TERMUX_PKG_API_LEVEL=28
export TERMUX_PKG_API_LEVEL

# The URL of the repository where the packages will be published
COTG_REPO="https://packagesyatonorai.duckdns.org/apt/termux-main"
export COTG_REPO

# All supported CPU ABIs
# Must begin and end with spaces
# Must be separated with spaces
COTG_ALL_ARCHS=" aarch64 arm "
export COTG_ALL_ARCHS

# The base output directory
COTG_OUTPUT_DIR="$script_dir/output"

# The directory where local repository is created
COTG_REPO_DIR="${COTG_OUTPUT_DIR}/repo"

# ---- Patches applied to termux-packages ----
# Shared between build.sh and generate-bootstrap-archive.sh

declare -a PATCHES=(

    # Adds our own GPG keys
    "termux-keyring.patch"

    # Fix pkg.in before compilation via build.sh termux_step_pre_configure.
    # Removes mirror-warning, failing find commands, and replaces the else
    # branch with an early return so sources.list from bootstrap is preserved.
    "termux-tools-pkg-fix-mirror.patch"

    # Update mirror configurations (removes mirrors/ subdir from build)
    "termux-tools-mirrors.patch"

    # Update motd
    "termux-tools-motd.patch"

    # Makes some of the packages depend on and link against libandroid-shmem.so
    # Required to fix some build failures
    "libdb-depend-on-android-shmem.patch"
    "libunbound-depend-on-android-shmem.patch"
    "libx11-depend-on-android-shmem.patch"

    # Fix dependencies in binutils-libs
    "binutils-libs-fix-dependencies.patch"

    # libxml2 v2.14.4 has build errors
    # "libxml2-revert-to-2.14.3.patch"

    # Remove 'scalar' binary from $PREFIX/bin and make it a symlink
    # to $PREFIX/libexec/git-core/scalar
    "git-symlink-scalar.patch"

    # subversion fails to compile, complaining that the `apr.h` and other headers
    # could not be found. These headers are located in $PREFIX/include/apr-1
    "subversion-missing-apr-includes.patch"

    # libuv has missing sources in their Makefile configuration
    # This missing source issue was fixed in their CMake configuration
    # So we force termux-packages to build using CMake instead of Makefile
    "libuv-force-cmake-build.patch"

    # Update package name in termux-tools
    "termux-tools-update-package-name.patch"



    # Cleanup OpenJDK 21 to remove postinst & prerm scripts
    "openjdk-21-cleanup.patch"

    # Cleanup vim to remove postinst scripts
    "vim-cleanup.patch"

    # Restore files and cleanup in second stage
    "scripts-cleanup-in-second-stage.patch"

    # Link pulseaudio against libiconv to resolve linker errors at build time
    "pulseaudio-link-against-libiconv.patch"

    # `rm` command complains about missing libacl.so after updating packages
    # This ensures that libacl package is installed before coreutils
    "coreutils-depend-on-libacl.patch"

    # `libapr-1.so` needs to be linked against libandroid-shmem.so
    # in order to fix undefined symbol error when building subversion
    "apr-link-against-libandroid-shmem.patch"

    # nano-editor.org/dist/latest/ is unreliable from CI environments;
    # use the stable version-specific path instead
    "nano-fix-srcurl.patch"

    # bash lists command-not-found as Recommends; some build system versions
    # promote it to Depends in the control file, causing bootstrap to fail
    # when the package is not in the repo. Remove the Recommends entirely.
    "bash-remove-recommends.patch"

    # SourceForge downloads.sf.net returns 404 from GitHub Actions IPs;
    # switch to master.dl.sourceforge.net (SF's own CDN, no redirect)
    "giflib-fix-srcurl.patch"
    "procps-fix-srcurl.patch"
    "net-tools-fix-srcurl.patch"

    # infozip on SourceForge has an unusual path structure;
    # use Debian pool mirrors (same content, guaranteed reliable)
    "unzip-fix-srcurl.patch"
    "zip-fix-srcurl.patch")


patch_bootstrap_generator() {
    local bootstrap_script="$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh"

    if [[ ! -f "$bootstrap_script" ]]; then
        scribe_error_exit "Bootstrap generator not found: ${bootstrap_script}"
    fi

    # Remove the Android 10-only package branch that pulls command-not-found
    # or proot. Keep the surrounding shell syntax intact by replacing the
    # whole block with a no-op.
    python - "$bootstrap_script" <<'PY2'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
pattern = re.compile(
    r"if ! \${BOOTSTRAP_ANDROID10_COMPATIBLE}; then\s*"
    r"pull_package command-not-found\s*"
    r"else\s*"
    r"pull_package proot\s*"
    r"fi\s*",
    re.S,
)
replacement = ": # minimal bootstrap: no command-not-found or proot\n\n"
text, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit('expected command-not-found/proot block not found')
path.write_text(text)
PY2
}



# Sets up the termux-packages submodule: substitutes package name,
# installs the GPG key, generates template-based patches, applies
# all patches, and updates the APT repository URL.
# Idempotent: skips everything if .scribe-patched already exists.
setup_termux_packages() {
    if [[ -f "$TERMUX_PACKAGES_DIR/.scribe-patched" ]]; then
        scribe_info "termux-packages already patched, skipping setup."
        return 0
    fi

    pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

    # Change package name
    echo "Updating package name.."
    grep -rniF . -e "${TERMUX_PACKAGE_NAME}" -l\
        --exclude-dir=".git" | \
        xargs -L1 sed -i "s/${TERMUX_PACKAGE_NAME//./\\.}/${COTG_PACKAGE_NAME}/g" || \
        scribe_error_exit "Unable to update package name"

    # Removes existing keyrings
    echo "Removing existing GPG keys..."
    rm -rvf packages/termux-keyring/*.gpg

    # Add our own keyring
    echo "Adding our keyring..."
    cp "${COTG_GPG_KEY}" "./packages/termux-keyring/$(basename "$COTG_GPG_KEY")"

    # Create termux-keyring.patch
    termux_keyring_patch="$script_dir/patches/termux-keyring.patch"
    sed "s|@COTG_GPG_KEY@|$(basename "$COTG_GPG_KEY")|g" "${termux_keyring_patch}.in" > "$termux_keyring_patch"

    # Create termux-tools-update-package-name.patch
    termux_tools_update_package_name_patch="$script_dir/patches/termux-tools-update-package-name.patch"
    sed "s|@TERMUX_PACKAGE_NAME@|$COTG_PACKAGE_NAME|g" "${termux_tools_update_package_name_patch}.in" > "${termux_tools_update_package_name_patch}"


    # Apply patches
    for patch in "${PATCHES[@]}"; do
        scribe_info "Applying patch: ${patch}"
        if patch -p1 --no-backup-if-mismatch<"$script_dir/patches/$patch" ||\
            scribe_error_exit "Failed to apply '$patch'"; then
            scribe_ok "Applied '$patch'"
        fi
    done

    # Update the packages repository
    grep -rnI . -e "https://packages-cf.termux.dev/apt/termux-main" -l |\
        xargs -L1 sed -i "s|https://packages-cf.termux.dev/apt/termux-main|${COTG_REPO}|g"

    patch_bootstrap_generator

    # Marked patched
    touch .scribe-patched

    popd || scribe_error_exit "Unable to popd from termux-packages"
}
