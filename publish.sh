#!/bin/bash
# Publish Flatpak apps to flatpak.rueegger.dev
# Usage: ./publish.sh [app]
# Example: ./publish.sh bootmate
# Without argument: publishes all configured apps
#
# All builds must run inside the bootmate-devsystem Distrobox (the host
# intentionally doesn't have flatpak-builder installed). If this script is
# started on the host, it re-execs itself inside the box automatically.

set -euo pipefail

DEVBOX_NAME="bootmate-devsystem"

# ── Auto-reentry into the dev distrobox ────────────────────────
if ! command -v flatpak-builder >/dev/null 2>&1; then
    if [ -n "${BOOTMATE_DEVBOX_REENTRY:-}" ]; then
        echo "ERROR: flatpak-builder not found inside $DEVBOX_NAME." >&2
        echo "Recreate the box: ~/Projects/bootmate/scripts/devbox-setup.sh" >&2
        exit 1
    fi
    export BOOTMATE_DEVBOX_REENTRY=1
    exec distrobox enter "$DEVBOX_NAME" -- "$0" "$@"
fi

# Reuse the box-local Flatpak user installation (populated by devbox-flatpak.sh).
# Keeps host $HOME clean and avoids redownloading GNOME runtimes.
export FLATPAK_USER_DIR="${FLATPAK_USER_DIR:-/var/cache/bootmate-flatpak/flatpak-user}"

# ── Configuration ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/repo"
GPG_HOMEDIR="$SCRIPT_DIR/gpg"
GPG_KEY_ID="A597D880A0505622AA55A6CB0718DBE47E8CA409"
BRANCH="stable"

SERVER="scifitre@rueegger.dev"
REMOTE_PATH="public_html/flatpak.rueegger.dev"

# ── App definitions ────────────────────────────────────────────
# Add new apps here: APP_<name>_DIR and APP_<name>_MANIFEST
APP_bootmate_DIR="$HOME/Projects/bootmate"
APP_bootmate_MANIFEST="me.rueegger.bootmate.yml"

APP_cargo_DIR="$HOME/Projects/me.rueegger.cargo"
APP_cargo_MANIFEST="me.rueegger.cargo.yml"

ALL_APPS="bootmate cargo"

# ── Functions ──────────────────────────────────────────────────

build_app() {
    local app="$1"
    local dir_var="APP_${app}_DIR"
    local manifest_var="APP_${app}_MANIFEST"
    local app_dir="${!dir_var}"
    local manifest="${!manifest_var}"

    echo "══════════════════════════════════════════════════"
    echo "  Building: $app"
    echo "  Source:   $app_dir"
    echo "  Manifest: $manifest"
    echo "══════════════════════════════════════════════════"

    if [ ! -d "$app_dir" ]; then
        echo "ERROR: App directory not found: $app_dir"
        exit 1
    fi

    if [ ! -f "$app_dir/$manifest" ]; then
        echo "ERROR: Manifest not found: $app_dir/$manifest"
        exit 1
    fi

    cd "$app_dir"

    flatpak-builder \
        --user \
        --repo="$REPO_DIR" \
        --gpg-sign="$GPG_KEY_ID" \
        --gpg-homedir="$GPG_HOMEDIR" \
        --force-clean \
        --disable-rofiles-fuse \
        --default-branch="$BRANCH" \
        _flatpak \
        "$manifest"

    echo "  ✓ $app built and exported to repo"
}

update_repo() {
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  Updating repository metadata"
    echo "══════════════════════════════════════════════════"

    flatpak build-update-repo \
        --gpg-sign="$GPG_KEY_ID" \
        --gpg-homedir="$GPG_HOMEDIR" \
        --generate-static-deltas \
        --prune \
        --prune-depth=3 \
        --title="rueegger-dev" \
        --comment="Flatpak repository by Samuel Rüegger" \
        --homepage="https://rueegger.me" \
        --default-branch="$BRANCH" \
        "$REPO_DIR"

    echo "  ✓ Repository metadata updated"
}

upload() {
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  Uploading to $SERVER"
    echo "══════════════════════════════════════════════════"

    # Upload static files (flatpakrepo, flatpakref, htaccess, gpg key)
    rsync -rlptv \
        "$SCRIPT_DIR/public/" \
        "$SERVER:$REMOTE_PATH/"

    # Upload repo (objects first, then summary)
    rsync -rlptv --ignore-existing \
        --exclude='tmp/' --exclude='state/' \
        --include='/objects' --include='/objects/**' \
        --include='/deltas' --include='/deltas/**' \
        --include='/config' \
        --exclude='*' \
        "$REPO_DIR/" "$SERVER:$REMOTE_PATH/repo/"

    rsync -rlptv --delete \
        --exclude='tmp/' --exclude='state/' \
        --include='/refs' --include='/refs/**' \
        --include='/summary' --include='/summary.sig' \
        --include='/summaries' --include='/summaries/**' \
        --exclude='*' \
        "$REPO_DIR/" "$SERVER:$REMOTE_PATH/repo/"

    # Final pass: clean up old objects
    rsync -rlptv --delete \
        --exclude='tmp/' --exclude='state/' \
        "$REPO_DIR/" "$SERVER:$REMOTE_PATH/repo/"

    echo "  ✓ Upload complete"
}

# ── Main ───────────────────────────────────────────────────────

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [app]"
    echo ""
    echo "Available apps: $ALL_APPS"
    echo ""
    echo "Examples:"
    echo "  $0 bootmate    # Build and publish bootmate"
    echo "  $0             # Build and publish all apps"
    echo ""
    echo "Note: this script auto-enters the $DEVBOX_NAME Distrobox when run"
    echo "      from the host — no manual 'distrobox enter' needed."
    exit 0
fi

TARGET_APPS="${1:-$ALL_APPS}"

for app in $TARGET_APPS; do
    build_app "$app"
done

update_repo
upload

echo ""
echo "══════════════════════════════════════════════════"
echo "  Done!"
echo ""
echo "  Users can add this repo with:"
echo "    flatpak remote-add --if-not-exists rueegger-dev https://flatpak.rueegger.dev/rueegger-dev.flatpakrepo"
echo ""
echo "  Then install apps with:"
echo "    flatpak install rueegger-dev me.rueegger.bootmate"
echo "    flatpak install rueegger-dev me.rueegger.cargo"
echo "══════════════════════════════════════════════════"
