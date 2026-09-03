#!/usr/bin/env bash
#
# Installs the claude user's dotfiles and keeps local changes.
# Run as root from the root of this repo:
#   sudo ./scripts/sync-claude-dotfiles.sh [--dry-run] [--review]
#
# The claude user gets copies, not symlinks, because the repo is in the
# ubuntu user's home, which is mode 700. A plain copy removes changes made
# on the VM. Some of those changes are necessary: `gh auth setup-git`
# writes credential settings into ~/.gitconfig at each login.
#
# ucf does a three-way merge between the file in the repo, the file it
# supplied last time, and the file on disk. It keeps its record of the
# supplied files in /var/lib/ucf. If ucf is not installed, this script
# keeps the file on disk and writes the repo version next to it.
#
# Options:
#   --dry-run   Show the changes. Write nothing.
#   --review    Ask what to do with each file that has local changes.
#               Without this option the file on disk stays as it is, and
#               the repo version goes to <file>.ucf-dist for later review.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
USER_NAME="claude"
USER_HOME="/home/${USER_NAME}"
SRC_DIR="${REPO_DIR}/dotfiles-claude"

DRY_RUN=0
REVIEW=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --review)  REVIEW=1 ;;
        -h|--help)
            echo "Usage: sudo $(basename "$0") [--dry-run] [--review]"
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '${arg}'" >&2
            exit 2
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this script as root — sudo $(basename "$0")" >&2
    exit 1
fi
if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: no dotfiles directory at ${SRC_DIR}" >&2
    exit 1
fi
if ! id "$USER_NAME" &>/dev/null; then
    echo "ERROR: user '${USER_NAME}' does not exist — run setup-ai-user.sh first" >&2
    exit 1
fi

UCF_ARGS=(--three-way)
(( DRY_RUN )) && UCF_ARGS+=(--no-action)
# ucf asks its questions through debconf, and only when this option is set.
(( REVIEW )) && UCF_ARGS+=(--debconf-ok)

REVIEW_LIST=()

# ---------------------------------------------------------------------------
# Install one file. ucf does the merge when it is available.
# ---------------------------------------------------------------------------
install_dotfile() {
    local src="$1" dest="$2"

    (( DRY_RUN )) || mkdir -p "$(dirname "$dest")"

    if command -v ucf &>/dev/null; then
        ucf "${UCF_ARGS[@]}" "$src" "$dest"
        return
    fi

    # No ucf. Keep the file on disk, because this script cannot tell a local
    # change from an old version of the repo file.
    if [[ ! -e "$dest" ]]; then
        (( DRY_RUN )) && { echo "    ${dest} (new)"; return; }
        install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$src" "$dest"
        echo "    ${dest} (new)"
    elif cmp -s "$src" "$dest"; then
        echo "    ${dest} (no change)"
    else
        REVIEW_LIST+=("$dest")
        (( DRY_RUN )) && { echo "    ${dest} (differs — would write ${dest}.ucf-dist)"; return; }
        install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$src" "${dest}.ucf-dist"
        echo "    ${dest} (local changes kept — repo version at ${dest}.ucf-dist)"
    fi
}

command -v ucf &>/dev/null \
    || echo "NOTE: ucf is not installed — files with local changes stay as they are."

echo "==> Installing dotfiles for ${USER_NAME}"
while IFS= read -r src; do
    rel="${src#${SRC_DIR}/}"
    install_dotfile "$src" "${USER_HOME}/${rel}"
done < <(find "$SRC_DIR" -type f ! -name "*.example" | sort)

# ---------------------------------------------------------------------------
# Example files hold credentials. Supply them once and never touch them again.
# ---------------------------------------------------------------------------
echo "==> Installing example configs for ${USER_NAME}"
while IFS= read -r src; do
    rel="${src#${SRC_DIR}/}"
    dest="${USER_HOME}/${rel%.example}"
    if [[ -f "$dest" ]]; then
        echo "    ${dest} (already exists, skipping)"
    elif (( DRY_RUN )); then
        echo "    ${dest} (would install from example)"
    else
        mkdir -p "$(dirname "$dest")"
        install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$src" "$dest"
        echo "    ${dest} (from example — fill in your values)"
    fi
done < <(find "$SRC_DIR" -type f -name "*.example" | sort)

if (( ! DRY_RUN )); then
    if ! grep -q 'bashrc.local' "${USER_HOME}/.bashrc" 2>/dev/null; then
        echo 'source ~/.bashrc.local' >> "${USER_HOME}/.bashrc"
    fi
    # mkdir and ucf make the files as root. Give them back to the user.
    chown -R "$USER_NAME:$USER_NAME" "$USER_HOME"
fi

# ---------------------------------------------------------------------------
# Report the files that need a person to look at them.
# ---------------------------------------------------------------------------
mapfile -t DIST_FILES < <(find "$USER_HOME" -name "*.ucf-dist" 2>/dev/null | sort)
if (( ${#DIST_FILES[@]} )); then
    echo
    echo "==> These files have local changes and a newer version in the repo:"
    for f in "${DIST_FILES[@]}"; do
        echo "    ${f%.ucf-dist}"
        echo "        diff ${f%.ucf-dist} ${f}"
    done
    echo
    echo "    Merge the changes you want, then delete the .ucf-dist file."
    echo "    Or run this script again with --review to merge them now."
fi

echo
echo "Done."
