#!/usr/bin/env bash

# Minimal packages required for the bootstrap to function.
# These are passed to generate-bootstraps.sh --add and represent
# the smallest set that makes apt, the shell, and basic POSIX tools
# available after first boot.  Everything else should be installed
# via `apt install` at runtime.
declare -a COTG_PACKAGES__BOOTSTRAP

# Extra packages added on top of the bootstrap for each variant.
# Kept separate so the bootstrap archive stays small.
declare -a COTG_PACKAGES__DEBUG
declare -a COTG_PACKAGES__RELEASE

# List of all packages that need to be built.
# Used by build.sh / build-local.sh to know what to compile.
declare -a COTG_PACKAGES

# ---- Minimal bootstrap ----
COTG_PACKAGES__BOOTSTRAP=(

    ## Core shell & package-manager dependencies.
    ## Removing any of these will break apt or the login shell.
    "apt"
    "bash"
    "coreutils"
    "dash"
    "diffutils"
    "findutils"
    "gawk"
    "grep"
    "gzip"
    "less"
    "libbz2"
    "procps"
    "psmisc"
    "sed"
    "tar"
    "termux-core"
    "termux-exec"
    "termux-keyring"
    "termux-tools"
    "util-linux"

    # Required by generate-bootstraps.sh when BOOTSTRAP_ANDROID10_COMPATIBLE=false
    "command-not-found"
)

# ---- Variant-specific extras (installed via apt, not baked into bootstrap) ----

# debug-only extras
COTG_PACKAGES__DEBUG=(
    "binutils-libs"
    "brotli"
    "debianutils"
    "dos2unix"
    "ed"
    "file"
    "git"
    "inetutils"
    "libprotobuf"
    "libsqlite"
    "lsof"
    "mandoc"
    "nano"
    "net-tools"
    "openjdk-21"
    "patch"
    "python"
    "python-pip"
    "unzip"
    "vim"
    "wget"
    "which"
    "zip"
)

# release-only extras
COTG_PACKAGES__RELEASE=(
    "brotli"
    "debianutils"
    "dos2unix"
    "ed"
    "git"
    "inetutils"
    "libprotobuf"
    "lsof"
    "mandoc"
    "nano"
    "net-tools"
    "openjdk-21"
    "patch"
    "unzip"
    "wget"
    "zip"

    # cmake and libllvm for Android SDK support
    "cmake"
    "libllvm"
)

# All packages that need to be compiled/available in the repo.
COTG_PACKAGES=(
    "${COTG_PACKAGES__BOOTSTRAP[@]}"
    "${COTG_PACKAGES__DEBUG[@]}"
    "${COTG_PACKAGES__RELEASE[@]}"
)

# De-duplicate (bash does not do this automatically)
readarray -t COTG_PACKAGES < <(printf '%s\n' "${COTG_PACKAGES[@]}" | sort -u)
