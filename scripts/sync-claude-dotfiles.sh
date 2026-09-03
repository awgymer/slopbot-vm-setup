#!/usr/bin/env bash
#
# Installs the claude user's dotfiles and keeps local changes.
# Run as root from the root of this repo:
#   sudo ./scripts/sync-claude-dotfiles.sh [--dry-run] [--review]
#
# The claude user gets copies, not symlinks, because this repo is in the
# ubuntu home, which is mode 700. A plain copy removes changes made on the
# VM. Some of those changes are necessary: `gh auth setup-git` writes
# credential settings into ~/.gitconfig at each login.
#
# To tell a local change from an old version, the file on disk is compared
# with every version of it in the git history of this repo. A file that
# matches one of them holds no local changes, whether or not ucf has a
# record of it, so a VM set up before this script existed still gets the
# new version on the first run.
#
#   No local change      The repo version goes in.
#   Local change         The file on disk stays. The repo version goes to
#                        <file>.ucf-dist. UCF_FORCE_CONFFOLD gives this
#                        answer without a prompt, so a run never blocks.
#   Local change,        ucf asks what to do. The choices include a
#     with --review      three-way merge through diff3. A merge is never
#                        automatic: the default answer is to keep the
#                        local file. A merge that does not apply cleanly
#                        goes to <file>.merge-error, and the file on disk
#                        stays.
#
# Options:
#   --dry-run   Report the changes without changing the dotfiles. Note
#               that ucf still writes the <file>.ucf-dist copies.
#   --review    Ask what to do with each file that has local changes.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
USER_NAME="claude"
USER_HOME="/home/${USER_NAME}"
SRC_DIR="${REPO_DIR}/dotfiles-claude"
# The repo belongs to the ubuntu user and this script runs as root, so git
# needs to be told that the checkout is a safe one to read.
GIT_ARGS=(-C "$REPO_DIR" -c 'safe.directory=*')

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
# --debconf-ok lets ucf use a debconf instance that is already running.
(( REVIEW )) && UCF_ARGS+=(--debconf-ok)

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILED=0

# ---------------------------------------------------------------------------
# Collect the md5sum of every version of one dotfile that this repo holds:
# the one in the working tree, and each one in the git history. ucf reads
# this list through --sum-file and takes a match as "not changed on the VM".
# ---------------------------------------------------------------------------
historical_sums() {
    local rel="$1" out="$2" sha
    local path="dotfiles-claude/${rel}"

    md5sum < "${SRC_DIR}/${rel}" > "$out"
    [[ -d "${REPO_DIR}/.git" ]] || return 0

    while IFS= read -r sha; do
        # A commit that deleted the file has no blob to read.
        if git "${GIT_ARGS[@]}" show "${sha}:${path}" > "${WORK_DIR}/blob" 2>/dev/null; then
            md5sum < "${WORK_DIR}/blob" >> "$out"
        fi
    done < <(git "${GIT_ARGS[@]}" log --format='%H' -- "$path" 2>/dev/null)
}

# Is the file on disk one of the versions this repo has shipped?
is_unchanged() {
    local dest="$1" sums="$2"
    [[ -e "$dest" ]] || return 0
    grep -q "^$(md5sum < "$dest" | cut -d' ' -f1)" "$sums"
}

# ---------------------------------------------------------------------------
# Install one file. ucf keeps local changes when it is available.
# ---------------------------------------------------------------------------
install_dotfile() {
    local src="$1" dest="$2" rc=0
    local rel="${src#"${SRC_DIR}"/}"
    local sums="${WORK_DIR}/sums"
    local -a force=()

    (( DRY_RUN )) || mkdir -p "$(dirname "$dest")"
    historical_sums "$rel" "$sums"

    # Only answer for the user when the file holds changes this repo has
    # never shipped. Anything else is safe for ucf to replace on its own.
    if (( ! REVIEW )) && ! is_unchanged "$dest" "$sums"; then
        force=(env UCF_FORCE_CONFFOLD=1)
    fi

    if command -v ucf &>/dev/null; then
        "${force[@]}" ucf "${UCF_ARGS[@]}" --sum-file "$sums" "$src" "$dest" || rc=$?
        if (( rc )); then
            echo "    ${dest} (ERROR: ucf exited ${rc} — file untouched)" >&2
            FAILED=1
        fi
        return
    fi

    # No ucf. Same decision, without the option of a merge.
    if is_unchanged "$dest" "$sums"; then
        if cmp -s "$src" "$dest" 2>/dev/null; then
            echo "    ${dest} (no change)"
        elif (( DRY_RUN )); then
            echo "    ${dest} (would install the repo version)"
        else
            install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$src" "$dest"
            echo "    ${dest} (updated)"
        fi
    elif (( DRY_RUN )); then
        echo "    ${dest} (local changes — would write ${dest}.ucf-dist)"
    else
        install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$src" "${dest}.ucf-dist"
        echo "    ${dest} (local changes kept — repo version at ${dest}.ucf-dist)"
    fi
}

command -v ucf &>/dev/null \
    || echo "NOTE: ucf is not installed — files with local changes stay as they are."

echo "==> Installing dotfiles for ${USER_NAME}"
while IFS= read -r src; do
    rel="${src#"${SRC_DIR}"/}"
    install_dotfile "$src" "${USER_HOME}/${rel}"
done < <(find "$SRC_DIR" -type f ! -name "*.example" | sort)

# ---------------------------------------------------------------------------
# Example files hold credentials. Supply them once and never touch them again.
# ---------------------------------------------------------------------------
echo "==> Installing example configs for ${USER_NAME}"
while IFS= read -r src; do
    rel="${src#"${SRC_DIR}"/}"
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
mapfile -t LEFTOVERS < <(
    find "$USER_HOME" \( -name "*.ucf-dist" -o -name "*.merge-error" \) 2>/dev/null | sort
)
if (( ${#LEFTOVERS[@]} )); then
    echo
    echo "==> These files have local changes and a newer version in the repo:"
    for f in "${LEFTOVERS[@]}"; do
        echo "    diff ${f%.*} ${f}"
    done
    echo
    echo "    Take the changes you want, then delete the extra file."
    echo "    Or run this script again with --review to merge them now."
fi

echo
if (( FAILED )); then
    echo "Done, with errors above."
    exit 1
fi
echo "Done."
