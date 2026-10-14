#!/usr/bin/env bash
#
# Installs an agent user's dotfiles, and backs up any local changes first.
# Run as root from the root of this repo:
#   sudo ./scripts/sync-ai-user.sh [--dry-run] <username>
#
# The agent user gets copies, not symlinks, because this repo is in the
# ubuntu home, which is mode 700.
#
# Every run installs the repo version. A copy of each version installed is
# kept in STATE_DIR, and that is what tells a local change from a file that
# is only out of date:
#
#   No local change      The repo version goes in.
#   Local change         The file on disk moves to a dated folder in
#                        ~/.dotfile-backups, next to <file>.base, the version
#                        it was changed from. The repo version goes in.
#   No copy kept yet     As for a local change, since the two cannot be told
#                        apart. This happens once per file.
#
# Only the newest BACKUP_KEEP backup folders are kept.
#
# Every read and write inside the home runs as the agent user, not as root.
# The agent owns the home, and can put a symlink there that points outside
# it. Root would follow the link. The agent cannot, because the kernel
# checks its permissions. The agent cannot read the repo or STATE_DIR, so
# the copies that go from root into the home arrive on stdin.
#
# ~/.gitconfig belongs to the VM, not the repo: `gh auth setup-git` writes
# credential settings into it at each login. The repo's git settings go to
# ~/.config/git/config, which git also reads.
#
# Options:
#   --dry-run   Report what would happen, and change nothing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
USER_NAME=""   # required; set from the arguments below
USER_HOME=""
SRC_DIR="${REPO_DIR}/dotfiles-ai"
BACKUP_KEEP=2

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

# The versions installed last. Root's, so the agent user cannot change them.
STATE_DIR="/var/lib/slopbot/dotfiles/${USER_NAME}"
BACKUP_ROOT="${USER_HOME}/.dotfile-backups"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y-%m-%dT%H-%M-%S)"
BACKED_UP=()

# ---------------------------------------------------------------------------
# Run a command as the agent user. runuser keeps the rest of the environment,
# so HOME is set here and every path below is explicit.
# ---------------------------------------------------------------------------
as_user() {
    runuser -u "$USER_NAME" -- env HOME="$USER_HOME" "$@"
}

# ---------------------------------------------------------------------------
# Write stdin to a file in the home, as the agent user. The file is made
# new, so a symlink in its place is removed and not followed.
#   write_as_user <dest> <mode> < <source>
# ---------------------------------------------------------------------------
write_as_user() {
    as_user sh -c 'rm -f -- "$1" && umask 077 && cat > "$1" && chmod "$2" "$1"' _ "$1" "$2"
}

# ---------------------------------------------------------------------------
# Move a file into this run's backup folder, with the version it came from.
# ---------------------------------------------------------------------------
backup_file() {
    local rel="$1"

    BACKED_UP+=("$rel")
    (( DRY_RUN )) && return
    as_user mkdir -p "$(dirname "${BACKUP_DIR}/${rel}")"
    as_user mv "${USER_HOME}/${rel}" "${BACKUP_DIR}/${rel}"
    if [[ -f "${STATE_DIR}/${rel}" ]]; then
        write_as_user "${BACKUP_DIR}/${rel}.base" 644 < "${STATE_DIR}/${rel}"
    fi
}

# ---------------------------------------------------------------------------
# Install one file, and back up the file on disk if it has local changes.
# ---------------------------------------------------------------------------
install_dotfile() {
    local src="$1" rel="$2"
    local dest="${USER_HOME}/${rel}" last="${STATE_DIR}/${rel}" note dry

    if ! as_user test -e "$dest"; then
        note="installed"
        dry="would install"
    elif as_user cmp -s - "$dest" < "$src"; then
        note="no change"
        dry="no change"
    elif [[ -f "$last" ]] && as_user cmp -s - "$dest" < "$last"; then
        note="updated"
        dry="would update"
    elif [[ -f "$last" ]]; then
        note="local changes backed up, then updated"
        dry="local changes — would back up, then update"
        backup_file "$rel"
    else
        note="no record of the last version — backed up, then updated"
        dry="no record of the last version — would back up, then update"
        backup_file "$rel"
    fi

    if (( DRY_RUN )); then
        echo "    ${dest} (${dry})"
        return
    fi
    if [[ "$note" != "no change" ]]; then
        as_user mkdir -p "$(dirname "$dest")"
        write_as_user "$dest" 644 < "$src"
    fi
    install -D -m 600 "$src" "$last"
    echo "    ${dest} (${note})"
}

# ---------------------------------------------------------------------------
# The repo's git settings moved from ~/.gitconfig to ~/.config/git/config. On
# the first run after that, ~/.gitconfig still holds the old repo settings,
# which would override the new file. Back it up and start it empty;
# `gh auth setup-git` puts its settings back at the next login.
# ---------------------------------------------------------------------------
if as_user test -f "${USER_HOME}/.gitconfig" \
      && [[ -f "${SRC_DIR}/.config/git/config" && ! -f "${STATE_DIR}/.config/git/config" ]]; then
    echo "==> Moving the git settings to ~/.config/git/config"
    backup_file ".gitconfig"
    if (( DRY_RUN )); then
        echo "    ${USER_HOME}/.gitconfig (would be backed up and emptied)"
    else
        echo "    ${USER_HOME}/.gitconfig (backed up and emptied)"
    fi
fi

echo "==> Installing dotfiles for ${USER_NAME}"
while IFS= read -r src; do
    install_dotfile "$src" "${src#"${SRC_DIR}"/}"
done < <(find "$SRC_DIR" -type f ! -name "*.example" | sort)

# ---------------------------------------------------------------------------
# Example files hold credentials. Supply them once and never touch them again.
# ---------------------------------------------------------------------------
echo "==> Installing example configs for ${USER_NAME}"
while IFS= read -r src; do
    rel="${src#"${SRC_DIR}"/}"
    dest="${USER_HOME}/${rel%.example}"
    if as_user test -f "$dest"; then
        echo "    ${dest} (already exists, skipping)"
    elif (( DRY_RUN )); then
        echo "    ${dest} (would install from example)"
    else
        as_user mkdir -p "$(dirname "$dest")"
        write_as_user "$dest" 600 < "$src"
        echo "    ${dest} (from example — fill in your values)"
    fi
done < <(find "$SRC_DIR" -type f -name "*.example" | sort)

if (( ! DRY_RUN )); then
    # git config --global writes to ~/.config/git/config when ~/.gitconfig
    # does not exist. Make sure it exists, so gh writes there instead.
    as_user sh -c '[ -e "$1" ] || touch "$1"' _ "${USER_HOME}/.gitconfig"
    if ! as_user grep -q 'bashrc.local' "${USER_HOME}/.bashrc" 2>/dev/null; then
        as_user sh -c 'echo "source ~/.bashrc.local" >> "$1"' _ "${USER_HOME}/.bashrc"
    fi

    # Keep only the newest backup folders. Their names sort by date.
    if as_user test -d "$BACKUP_ROOT"; then
        while IFS= read -r old; do
            as_user rm -rf -- "$old"
            echo "    ${old} (old backup removed)"
        done < <(as_user find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n -"$BACKUP_KEEP")
    fi
fi

# ---------------------------------------------------------------------------
# Report what was backed up, and how to compare it.
# ---------------------------------------------------------------------------
if (( ${#BACKED_UP[@]} )); then
    echo
    if (( DRY_RUN )); then
        echo "==> These files would be backed up to ${BACKUP_DIR}:"
        for rel in "${BACKED_UP[@]}"; do
            echo "    ~/${rel}"
        done
    else
        echo "==> Local changes were backed up to ${BACKUP_DIR}"
        echo "    To compare with the new version:"
        for rel in "${BACKED_UP[@]}"; do
            new="${USER_HOME}/${rel}"
            # ~/.gitconfig starts empty. The repo's settings are elsewhere.
            [[ "$rel" == ".gitconfig" ]] && new="${USER_HOME}/.config/git/config"
            echo "    diff ${BACKUP_DIR}/${rel} ${new}"
        done
        if [[ -n "$(as_user find "$BACKUP_DIR" -name "*.base" -print -quit)" ]]; then
            echo "    Each <file>.base is the version your changes were made to."
        fi
    fi
fi

echo
echo "Done."
