#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-local.sh  –  Local equivalent of the GitHub Actions workflow.
# Runs everything inside Docker so the environment matches CI exactly.
#
# Usage:
#   ./build-local.sh [options]
#
# Options:
#   -a ARCH           Build only one architecture (aarch64 or arm).
#                     Default: build both.
#   -s                Skip package build (use existing output/ debs).
#   -b                Skip bootstrap generation.
#   -u                Skip SSH upload.
#   -h                Show this help message.
#
# Required tools on the host:  docker, gpg, rsync, ssh
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────
PACKAGE_NAME="com.layer.ide"
REPO_URL="https://packagesyatonorai.duckdns.org/apt/termux-main"
SSH_HOST="158.101.9.154"
SSH_USER="ubuntu"
SSH_REMOTE_PATH="/var/www/html/apt/termux-main"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ssh-key-2026-03-14.key}"
GPG_KEY_ID="${GPG_KEY_ID:-B28242D0BD9E3FC4}"
BUILDER_IMAGE="ghcr.io/termux/package-builder:latest"

ARCHS=("aarch64" "arm")
SKIP_BUILD=false
SKIP_BOOTSTRAP=false
SKIP_UPLOAD=false

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD} $*${RESET}"; \
            echo -e "${BOLD}════════════════════════════════════════${RESET}"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while getopts "a:sbuh" opt; do
    case "$opt" in
        a) ARCHS=("$OPTARG") ;;
        s) SKIP_BUILD=true ;;
        b) SKIP_BOOTSTRAP=true ;;
        u) SKIP_UPLOAD=true ;;
        h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Invalid option. Run with -h for help." ;;
    esac
done

# ── Preflight checks ─────────────────────────────────────────────────────────
section "Preflight checks"

command -v docker >/dev/null || die "docker is not installed or not in PATH"
command -v gpg    >/dev/null || die "gpg is not installed"
command -v rsync  >/dev/null || die "rsync is not installed"

if [[ ! -f "$SSH_KEY" ]]; then
    # Try the Windows OneDrive path via WSL
    WIN_KEY="/mnt/c/Users/mathu/OneDrive/Desktop/ssh-key-2026-03-14.key"
    if [[ -f "$WIN_KEY" ]]; then
        # Copy to a temp location with correct permissions
        SSH_KEY="/tmp/layer-ide-deploy.key"
        cp "$WIN_KEY" "$SSH_KEY"
        chmod 600 "$SSH_KEY"
        ok "SSH key found at Windows path, copied to $SSH_KEY"
    else
        warn "SSH key not found at $SSH_KEY or $WIN_KEY"
        warn "Set SSH_KEY=/path/to/key or skip upload with -u"
        SKIP_UPLOAD=true
    fi
fi

if ! gpg --list-secret-keys "$GPG_KEY_ID" &>/dev/null; then
    die "GPG key $GPG_KEY_ID not found. Was it generated on this machine?"
fi

ok "Docker, GPG, rsync available"
ok "GPG key $GPG_KEY_ID present"

# ── Pull builder image ────────────────────────────────────────────────────────
section "Pulling Docker image"
docker pull "$BUILDER_IMAGE"
ok "Image ready: $BUILDER_IMAGE"

# ── Helper: run a command inside the builder container ───────────────────────
# Usage: docker_build <arch> <bash_command>
docker_build() {
    local arch="$1"; shift
    local cmd="$*"
    docker run --rm \
        --privileged \
        -e HOME=/home/builder \
        -e PACKAGE_NAME="$PACKAGE_NAME" \
        -e REPO_URL="$REPO_URL" \
        -v "${SCRIPT_DIR}:/workspace" \
        -w /workspace \
        "$BUILDER_IMAGE" \
        bash -c "
            # Fix CRLF line endings that Windows git may have introduced
            find /workspace -maxdepth 1 -name '*.sh' -exec sed -i 's/\r//' {} +
            find /workspace/patches -name '*.patch*' -exec sed -i 's/\r//' {} + 2>/dev/null || true
            export HOME=/home/builder
            $cmd
        "
}

# ── Phase 1: Build packages ───────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
    for arch in "${ARCHS[@]}"; do
        section "Building packages — $arch"
        mkdir -p "${SCRIPT_DIR}/output/${arch}"
        time docker_build "$arch" \
            "./build.sh -a '${arch}' -p \"\$PACKAGE_NAME\" -r \"\$REPO_URL\" -s layer-ide.gpg"
        ok "Build complete: $arch"
    done
else
    warn "Skipping package build (-s flag)"
fi

# ── Phase 2: Generate APT repository ─────────────────────────────────────────
section "Generating APT repository"

# Fix line endings on host scripts before running them natively
sed -i 's/\r//' "${SCRIPT_DIR}/generate-apt-repo.sh" \
                "${SCRIPT_DIR}/common.sh" \
                "${SCRIPT_DIR}/utils.sh" \
                "${SCRIPT_DIR}/packages.sh" 2>/dev/null || true

bash "${SCRIPT_DIR}/generate-apt-repo.sh"
ok "APT repository generated at output/repo/"

# ── Phase 3: Sign the repository ─────────────────────────────────────────────
section "Signing APT repository"

RELEASE_FILE="${SCRIPT_DIR}/output/repo/dists/stable/Release"
INRELEASE_FILE="${SCRIPT_DIR}/output/repo/dists/stable/InRelease"

[[ -f "$RELEASE_FILE" ]] || die "Release file not found: $RELEASE_FILE"

gpg --batch \
    --yes \
    --pinentry-mode loopback \
    --default-key "$GPG_KEY_ID" \
    --digest-algo SHA256 \
    --clearsign \
    -o "$INRELEASE_FILE" \
    "$RELEASE_FILE"

ok "Repository signed → $INRELEASE_FILE"

# ── Phase 4: Upload to SSH server ─────────────────────────────────────────────
if [[ "$SKIP_UPLOAD" == "false" ]]; then
    section "Uploading to SSH server ($SSH_HOST)"

    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "${SSH_USER}@${SSH_HOST}" \
        "mkdir -p ${SSH_REMOTE_PATH}" || die "Cannot reach SSH server"

    rsync -avz --delete \
        -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" \
        "${SCRIPT_DIR}/output/repo/" \
        "${SSH_USER}@${SSH_HOST}:${SSH_REMOTE_PATH}/"

    ok "Repository uploaded → https://packagesyatonorai.duckdns.org/apt/termux-main"
else
    warn "Skipping SSH upload (-u flag)"
fi

# ── Phase 5: Generate Bootstrap archives ──────────────────────────────────────
if [[ "$SKIP_BOOTSTRAP" == "false" ]]; then
    section "Generating Bootstrap archives"

    mkdir -p "${SCRIPT_DIR}/output/aarch64" "${SCRIPT_DIR}/output/arm"

    info "Generating debug bootstrap..."
    docker_build "" \
        "./generate-bootstrap-archive.sh -r \"\$REPO_URL\""

    info "Generating release bootstrap..."
    docker_build "" \
        "./generate-bootstrap-archive.sh -g -r \"\$REPO_URL\""

    ok "Bootstrap archives:"
    ls -lh "${SCRIPT_DIR}"/output/bootstrap-*.zip* 2>/dev/null || warn "No bootstrap files found"
else
    warn "Skipping bootstrap generation (-b flag)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
section "All done"
echo ""
echo -e "  ${GREEN}Packages:${RESET}   output/{aarch64,arm}/*.deb"
echo -e "  ${GREEN}APT repo:${RESET}   output/repo/"
echo -e "  ${GREEN}Bootstrap:${RESET}  output/bootstrap-*.zip"
echo ""
ok "Build finished successfully"
