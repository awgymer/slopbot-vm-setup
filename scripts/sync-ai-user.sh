#!/usr/bin/env bash
#
# Installs an agent user's dotfiles and keeps local changes.
# Run as root from the root of this repo:
#   sudo ./scripts/sync-ai-user.sh [--dry-run] [--review] <username>
#
# The agent user gets copies, not symlinks, because this repo is in the
# ubuntu home, which is mode 700. A plain copy removes changes made on the
# VM. Some of those changes are necessary: `gh auth setup-git` writes
# credential settings into ~/.gitconfig at each login.
#
# ucf holds the version it supplied last, and that is what tells a local
# change from a file that is only out of date. On a VM set up before ucf
# was used there is no such record for the first run. The file on disk is
# then kept, whether it was changed or only old, and the repo version goes
# to <file>.ucf-dist for you to look at. That happens once per file.
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
USER_NAME=""   # required; set from the arguments below
USER_HOME=""
SRC_DIR="${REPO_DIR}/dotfiles-ai"

DRY_RUN=0
REVIEW=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --review)  REVIEW=1 ;;
        -h|--help)
            echo "Usage: sudo $(basename "$0") [--dry-run] [--review] <username>"
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option '${arg}'" >&2
            exit 2
            ;;
        *)
            if [[ -n "$USER_NAME" ]]; then
                echo "ERROR: give one user name, not '${USER_NAME}' and '${arg}'" >&2
                exit 2
            fi
            USER_NAME="$arg"
            ;;
    esac
done
if [[ -z "$USER_NAME" ]]; then
    echo "ERROR: give the user name — $(basename "$0") [--dry-run] [--review] <username>" >&2
    exit 2
fi

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
# Take the home directory from the account, rather than assume /home/<name>.
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "ERROR: no home directory for '${USER_NAME}'" >&2
    exit 1
fi

UCF_ARGS=(--three-way)
(( DRY_RUN )) && UCF_ARGS+=(--no-action)
# --debconf-ok lets ucf use a debconf instance that is already running.
(( REVIEW )) && UCF_ARGS+=(--debconf-ok)

# Where ucf keeps its records. --state-dir moves it; this must agree.
UCF_STATE_DIR="${UCF_STATE_DIR:-/var/lib/ucf}"
FAILED=0

# ---------------------------------------------------------------------------

# The md5sum ucf recorded when it last supplied this file, if it has one.
ucf_lastsum() {
    [[ -f "${UCF_STATE_DIR}/hashfile" ]] || return 1
    awk -v d="$1" '$2 == d { print $1; found = 1 } END { exit !found }' \
        "${UCF_STATE_DIR}/hashfile"
}


# ---------------------------------------------------------------------------
# Install one file. ucf keeps local changes when it is available.
# ---------------------------------------------------------------------------
install_dotfile() {
    local src="$1" dest="$2" rc=0 changed=0 unrecorded=0 last
    local -a force=()

    (( DRY_RUN )) || mkdir -p "$(dirname "$dest")"

    if last="$(ucf_lastsum "$dest")"; then
        # ucf holds the version it supplied last, so it can tell a file with
        # local changes from one that is only out of date.
        if [[ -e "$dest" ]]; then
            if [[ "$(md5sum < "$dest" | cut -d" " -f1)" != "$last" ]]; then
                changed=1
            fi
        fi
    elif [[ -e "$dest" ]] && ! cmp -s "$src" "$dest"; then
        # No record. This script cannot tell a local change from an old
        # version, so keep the file and leave the repo version for review.
        # This happens once per file, on a VM set up before ucf was used.
        changed=1
        unrecorded=1
    fi

    # Only answer for the user when the file may hold local changes.
    if (( ! REVIEW && changed )); then
        force=(env UCF_FORCE_CONFFOLD=1)
    fi

    if command -v ucf &>/dev/null; then
        "${force[@]}" ucf "${UCF_ARGS[@]}" "$src" "$dest" || rc=$?
        if (( rc )); then
            echo "    ${dest} (ERROR: ucf exited ${rc} — file untouched)" >&2
            FAILED=1
            return
        fi
        # ucf writes no .ucf-dist for a file it had no record of. Write one,
        # or the difference is kept but never reported.
        if (( unrecorded && ! REVIEW && ! DRY_RUN )); then
            install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$src" "${dest}.ucf-dist"
            echo "    ${dest} (no ucf record — repo version at ${dest}.ucf-dist)"
        fi
        return
    fi

    # No ucf. Same decision, without the option of a merge.
    if (( ! changed )); then
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
