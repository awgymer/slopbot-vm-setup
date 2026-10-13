#!/usr/bin/env bash
#
# Installs an agent user's dotfiles and keeps local changes.
# Run as root, from a terminal, from the root of this repo:
#   sudo ./scripts/sync-ai-user.sh [--dry-run] <username>
#
# The agent user gets copies, not symlinks, because this repo is in the
# ubuntu home, which is mode 700. A plain copy removes changes made on the
# VM. Some of those changes are necessary: `gh auth setup-git` writes
# credential settings into ~/.gitconfig at each login.
#
# ucf installs each file. It holds the version it supplied last, and that is
# what tells a local change from a file that is only out of date.
#
#   No local change      The repo version goes in.
#   Deleted on the VM    The repo version goes back in. UCF_FORCE_CONFFMISS
#                        gives this answer without a prompt.
#   Local change, and    ucf asks what to do: keep the local file, install
#     a new repo         the repo version, show the difference, or make a
#     version            three-way merge through diff3. Whatever you answer
#                        is recorded, and ucf does not ask again until the
#                        repo version changes again.
#
# The prompt is why this script needs a terminal. On a VM set up before ucf
# was used there is no record yet, so the first prompt for each file has no
# merge choice.
#
# Options:
#   --dry-run   Report what would happen. Changes nothing and asks nothing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
USER_NAME=""   # required; set from the arguments below
USER_HOME=""
SRC_DIR="${REPO_DIR}/dotfiles-ai"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: sudo $(basename "$0") [--dry-run] <username>"
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
    echo "ERROR: give the user name — $(basename "$0") [--dry-run] <username>" >&2
    exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this script as root — sudo $(basename "$0")" >&2
    exit 1
fi
if (( ! DRY_RUN )) && [[ ! -t 0 ]]; then
    echo "ERROR: run this script from a terminal — ucf may ask about files with local changes" >&2
    exit 1
fi
if ! command -v ucf &>/dev/null; then
    echo "ERROR: ucf is not installed — run install-system-tools.sh first" >&2
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

# The noninteractive frontend answers every prompt with its default, which
# keeps the local file. That is the choice this script exists to offer.
if [[ "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
    unset DEBIAN_FRONTEND
fi

# --debconf-ok lets ucf use a debconf instance that is already running.
UCF_ARGS=(--three-way --debconf-ok)

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
# --dry-run: say what ucf would do with one file. ucf's own --no-action is
# no use here, because it still asks, and its answer to keep the local file
# still writes <file>.ucf-dist.
# ---------------------------------------------------------------------------
report_dotfile() {
    local src="$1" dest="$2" last srcsum

    if [[ ! -e "$dest" ]]; then
        if ucf_lastsum "$dest" >/dev/null; then
            echo "    ${dest} (deleted — would put the repo version back)"
        else
            echo "    ${dest} (would install)"
        fi
        return
    fi
    if cmp -s "$src" "$dest"; then
        echo "    ${dest} (no change)"
        return
    fi
    if ! last="$(ucf_lastsum "$dest")"; then
        echo "    ${dest} (no ucf record — would ask, without a merge choice)"
        return
    fi
    srcsum="$(md5sum < "$src" | cut -d" " -f1)"
    if [[ "$srcsum" == "$last" ]]; then
        echo "    ${dest} (local changes, and no new repo version — no change)"
    elif [[ "$(md5sum < "$dest" | cut -d" " -f1)" == "$last" ]]; then
        echo "    ${dest} (would install the repo version)"
    else
        echo "    ${dest} (local changes, and a new repo version — would ask)"
    fi
}

# ---------------------------------------------------------------------------
# Install one file. ucf keeps local changes, and asks about them.
# ---------------------------------------------------------------------------
install_dotfile() {
    local src="$1" dest="$2" rc=0
    local -a force=()

    if (( DRY_RUN )); then
        report_dotfile "$src" "$dest"
        return
    fi

    mkdir -p "$(dirname "$dest")"

    # A file deleted on the VM gets the repo version back. Without this, ucf
    # asks about it when the repo version has changed.
    if [[ ! -e "$dest" ]]; then
        force=(env UCF_FORCE_CONFFMISS=1)
    fi

    "${force[@]}" ucf "${UCF_ARGS[@]}" "$src" "$dest" || rc=$?
    if (( rc )); then
        echo "    ${dest} (ERROR: ucf exited ${rc} — file untouched)" >&2
        FAILED=1
    fi
}

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
# List the files ucf leaves behind, so they get cleared up.
# ---------------------------------------------------------------------------
mapfile -t LEFTOVERS < <(
    find "$USER_HOME" \( -name "*.ucf-dist" -o -name "*.ucf-old" -o -name "*.merge-error" \) \
        2>/dev/null | sort
)
if (( ${#LEFTOVERS[@]} )); then
    echo
    echo "==> ucf left these files for reference. Delete each one when you are done with it:"
    for f in "${LEFTOVERS[@]}"; do
        echo "    ${f}"
    done
fi

echo
if (( FAILED )); then
    echo "Done, with errors above."
    exit 1
fi
echo "Done."
