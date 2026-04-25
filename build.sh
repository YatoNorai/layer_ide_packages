#!/usr/bin/env bash

#
# Copyright (C) 2025 Akash Yadav
#
# This file is part of The Scribe Project.
#
# Scribe is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Scribe is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Scribe.  If not, see <https://www.gnu.org/licenses/>.
#

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=common.sh
. "${script_dir}/common.sh"

# Script configuration
COTG_ARCH=""
COTG_EXPLICIT="false"
COTG_NO_BUILD="false"

usage() {
    echo "Script to build termux-packages for Code On the Go."
    echo ""
    echo "Usage: $0 -a ARCH [options] [package...]"
    echo ""
    echo "Options:"
    echo "  -a        The target architecture. Must be one of [${COTG_ALL_ARCHS}]."
    echo "  -e        Build only the explicitly specified packages."
    echo "  -n        Set up the build, but do not execute."
    echo "  -p        The package name of the application. Defaults to '${COTG_PACKAGE_NAME}'."
    echo "  -r        The repository where the built packages will be published."
    echo "            Defaults to '${COTG_REPO}'."
    echo "  -s        The GPG key used for signing packages. Defaults to '${COTG_GPG_KEY}'."
    echo
    echo "  -h        Show this help message and exit."
    echo ""
}

sed_escape() {
  printf '%s\n' "$1" | sed -e 's/[.[\*^$/]/\\&/g' -e 's/\\/\\\\/g' -e 's/#/\\#/g'
}



if [[ $# -eq 0 ]]; then
    # No arguments provided
    usage
    exit 1
fi

# Argument parsing
while getopts "a:enp:r:s:h" opt; do
    case "$opt" in
    a) COTG_ARCH="$OPTARG"                         ;;
    e) COTG_EXPLICIT="true"                        ;;
    n) COTG_NO_BUILD="true"                        ;;
    p) COTG_PACKAGE_NAME="$OPTARG"                 ;;
    r) COTG_REPO="$OPTARG"                         ;;
    s) COTG_GPG_KEY="$(realpath "$OPTARG")"        ;;
    h)
        usage
        exit 0
        ;;
    *)
        echo "Invalid option" >&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

if [[ "$COTG_ALL_ARCHS" != *" $COTG_ARCH "* ]]; then
    scribe_error_exit "Unsupported arch: '$COTG_ARCH'"
fi

if [[ -z "${COTG_PACKAGE_NAME}" ]]; then
    scribe_error_exit "A package name must be specified."
fi

if [[ -z "${COTG_REPO}" ]]; then
    scribe_error_exit "A package repository URL must be specified."
fi

if ! [[ -f "${COTG_GPG_KEY}" ]]; then
    scribe_error_exit "${COTG_GPG_KEY} does not exist or is not a file."
fi

# Get extra packages to build
declare -a EXTRA_PACKAGES=("$@")

OUTPUT_DIR="${COTG_OUTPUT_DIR}/$COTG_ARCH"
mkdir -p "${OUTPUT_DIR}"

# Check required commands
scribe_check_command "git"
scribe_check_command "patch"
scribe_check_command "tee"
scribe_check_command "time"

if ! [[ -f "$TERMUX_PACKAGES_DIR/.scribe-patched" ]]; then
    setup_termux_packages
fi

# Symlink termux-packages/output to OUTPUT_DIR
if ! [[ -L "$TERMUX_PACKAGES_DIR/output" ]]; then
    rm -rf "$TERMUX_PACKAGES_DIR/output"
fi

rm -v "$TERMUX_PACKAGES_DIR/output" || true
ln -sf "$OUTPUT_DIR" "$TERMUX_PACKAGES_DIR/output"

if [[ "$COTG_NO_BUILD" == "true" ]]; then
    scribe_ok "Skipping build."
    exit 0
fi

# All the packages that we'll be building
declare -a COTG_PACKAGES

if [[ "$COTG_EXPLICIT" == "true" ]]; then
    # We have been instructed to build only explicitly
    # specified packages
    COTG_PACKAGES=()
fi

COTG_PACKAGES+=("${EXTRA_PACKAGES[@]}")

pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

echo
echo "==="
echo "Building packages: ${COTG_PACKAGES[*]}"
echo "==="
echo

if ! { time ./build-package.sh -a "$COTG_ARCH" -o "$OUTPUT_DIR" "${COTG_PACKAGES[@]}" |&\
    tee "$OUTPUT_DIR/build.log"; }; then
    scribe_error_exit "Failed to build packages."
fi

popd || scribe_error_exit "Unable to popd from termux-packages"
