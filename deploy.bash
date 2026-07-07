#!/usr/bin/env bash
set -Eeuo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-Raymoun17}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
SSH_KEY_PATH="${STASH_SSH_KEY_PATH:-$HOME/.ssh/stash_build}"
KEY_MARKER="${SSH_KEY_PATH}.github-registered"
REPOSITORIES=(stash-db stash-bff stash-ui stash-scraper-worker)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n[stash-deploy] %s\n' "$*"; }
fail() { printf '\n[stash-deploy] ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

[[ -f "$SCRIPT_DIR/.env" ]] || fail "Missing $SCRIPT_DIR/.env. Copy .env.example to .env and replace all change-me values."
if grep -q 'change-me' "$SCRIPT_DIR/.env"; then
    fail ".env still contains change-me placeholder secrets."
fi

install_ubuntu_requirements() {
    local packages=()
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v gh >/dev/null 2>&1 || packages+=(gh)
    command -v ssh >/dev/null 2>&1 || packages+=(openssh-client)
    command -v ssh-keygen >/dev/null 2>&1 || packages+=(openssh-client)
    command -v ssh-add >/dev/null 2>&1 || packages+=(openssh-client)
    command -v ssh-agent >/dev/null 2>&1 || packages+=(openssh-client)
    command -v ssh-keyscan >/dev/null 2>&1 || packages+=(openssh-client)

    local docker_missing=false
    command -v docker >/dev/null 2>&1 || docker_missing=true
    local compose_missing=false
    if [[ "$docker_missing" == false ]] && ! docker compose version >/dev/null 2>&1; then
        compose_missing=true
    fi

    [[ ${#packages[@]} -eq 0 && "$docker_missing" == false && "$compose_missing" == false ]] && return

    command -v apt-get >/dev/null 2>&1 \
        || fail "Automatic dependency installation supports Ubuntu/Debian apt hosts only."
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to install deployment dependencies."

    log "Installing Ubuntu deployment requirements"
    sudo apt-get update
    if [[ ${#packages[@]} -gt 0 ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${packages[@]}"
    fi

    if [[ "$docker_missing" == true ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
    fi

    if [[ "$compose_missing" == true ]] || ! docker compose version >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin \
            || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
    fi

    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
}

install_ubuntu_requirements

require_command docker
require_command git
require_command ssh
require_command ssh-keygen
require_command ssh-add
require_command ssh-agent
require_command ssh-keyscan
require_command gh

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo docker info >/dev/null 2>&1; then
    # Newly granted docker-group membership takes effect at the next login.
    DOCKER=(sudo --preserve-env=SSH_AUTH_SOCK docker)
else
    fail "Docker is unavailable. Start the Docker service and rerun this script."
fi
"${DOCKER[@]}" compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required."
gh auth status --hostname github.com >/dev/null 2>&1 || {
    log "GitHub authentication is required once. Follow the prompts."
    gh auth login --hostname github.com --git-protocol ssh --web
}

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/known_hosts"
if ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    log "Adding GitHub to known_hosts"
    ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log "Generating deployment SSH key at $SSH_KEY_PATH"
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -C "stash-build@$(hostname)" -N ""
fi
chmod 600 "$SSH_KEY_PATH"
chmod 644 "${SSH_KEY_PATH}.pub"

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT
ssh-add "$SSH_KEY_PATH" >/dev/null

if [[ ! -f "$KEY_MARKER" ]]; then
    log "Registering deployment key with GitHub account $GITHUB_OWNER"
    gh auth refresh --hostname github.com --scopes admin:public_key
    if gh ssh-key add "${SSH_KEY_PATH}.pub" --title "stash-build-$(hostname)"; then
        touch "$KEY_MARKER"
        chmod 600 "$KEY_MARKER"
    else
        fail "Could not register the SSH key. If the key already exists on GitHub, run: touch '$KEY_MARKER'"
    fi
fi

log "Verifying private repository access"
for repository in "${REPOSITORIES[@]}"; do
    git ls-remote "git@github.com:${GITHUB_OWNER}/${repository}.git" HEAD >/dev/null \
        || fail "Cannot read ${GITHUB_OWNER}/${repository} with $SSH_KEY_PATH"
done

cd "$SCRIPT_DIR"

if [[ -d .git ]]; then
    log "Updating stash-infra"
    git pull --ff-only
fi

export DB_BUILD_CONTEXT="git@github.com:${GITHUB_OWNER}/stash-db.git#${DEPLOY_BRANCH}"
export BFF_BUILD_CONTEXT="git@github.com:${GITHUB_OWNER}/stash-bff.git#${DEPLOY_BRANCH}"
export UI_BUILD_CONTEXT="git@github.com:${GITHUB_OWNER}/stash-ui.git#${DEPLOY_BRANCH}"
export SCRAPER_BUILD_CONTEXT="git@github.com:${GITHUB_OWNER}/stash-scraper-worker.git#${DEPLOY_BRANCH}"

log "Building the latest ${DEPLOY_BRANCH} sources"
"${DOCKER[@]}" compose build --pull --ssh default

log "Applying the deployment"
"${DOCKER[@]}" compose up -d --remove-orphans

log "Deployment status"
"${DOCKER[@]}" compose ps
