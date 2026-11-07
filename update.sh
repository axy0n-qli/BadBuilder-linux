#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"

REMOTE="origin"
BRANCH="main"
EXIT_UP_TO_DATE=0
EXIT_UPDATED=10
EXIT_SKIPPED=20

info() { echo -e "\033[1;33m[*]\033[0m $*" >&2; }
ok()   { echo -e "\033[0;32m[+]\033[0m $*" >&2; }
warn() { echo -e "\033[38;5;208m[!]\033[0m $*" >&2; }

run_git() {
    local -a cmd=(env GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 git -c "safe.directory=${PWD}" "$@")
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        sudo -u "$SUDO_USER" -H "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

if ! command -v git &>/dev/null; then
    warn "git not found, skipping update check."
    exit $EXIT_SKIPPED
fi

if [[ ! -d .git ]]; then
    warn "Not a git repository, skipping update check."
    exit $EXIT_SKIPPED
fi

remote_url="$(run_git remote get-url "$REMOTE" 2>/dev/null || true)"
if [[ -z "$remote_url" ]]; then
    warn "Remote '${REMOTE}' not found, skipping update check."
    exit $EXIT_SKIPPED
fi

info "Checking for updates: ${remote_url} (${BRANCH})"

if ! run_git fetch --quiet "$REMOTE" "$BRANCH"; then
    warn "Unable to reach ${remote_url}, continuing with the local version."
    exit $EXIT_SKIPPED
fi

local_rev="$(run_git rev-parse HEAD)"
remote_rev="$(run_git rev-parse FETCH_HEAD)"

if [[ "$local_rev" == "$remote_rev" ]] || run_git merge-base --is-ancestor "$remote_rev" "$local_rev" 2>/dev/null; then
    ok "BadBuilder is up to date (${local_rev:0:7})."
    exit $EXIT_UP_TO_DATE
fi

info "New version available (${local_rev:0:7} -> ${remote_rev:0:7}), updating..."

if run_git pull --rebase --autostash --quiet "$REMOTE" "$BRANCH"; then
    ok "Update applied."
    exit $EXIT_UPDATED
fi

warn "Update failed, continuing with the local version."
exit $EXIT_SKIPPED
