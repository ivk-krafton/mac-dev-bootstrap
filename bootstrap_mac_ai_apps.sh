#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE_PATH="${SCRIPT_DIR}/Brewfile.mac-ai-apps"
RUN_BREW_UPDATE=1
RUN_BREW_UPGRADE=0

usage() {
  cat <<EOF
Usage:
  ./${SCRIPT_NAME} [--upgrade] [--no-brew-update] [--brewfile <path>]

What it does:
  - Installs Homebrew if it is missing
  - Persists Homebrew shellenv to ~/.zprofile
  - Installs macOS apps listed in the Brewfile

Default Brewfile:
  ${BREWFILE_PATH}

Installed tools:
  - Homebrew
  - Google Chrome
  - Claude Desktop
  - ChatGPT Desktop
  - Codex Desktop
  - Visual Studio Code
  - Cursor

Notes:
  - Claude, ChatGPT, Codex, Cursor, and VS Code sign-in remains manual

Options:
  --upgrade         Upgrade already installed casks to the latest version
  --no-brew-update  Skip 'brew update' before installation
  --brewfile PATH   Use a custom Brewfile instead of the default
  -h, --help        Show this help message
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2
}

warn() {
  printf '[%s] warning: %s\n' "$SCRIPT_NAME" "$*" >&2
}

fail() {
  printf '[%s] error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upgrade)
        RUN_BREW_UPGRADE=1
        shift
        ;;
      --no-brew-update)
        RUN_BREW_UPDATE=0
        shift
        ;;
      --brewfile)
        [[ $# -ge 2 ]] || fail "--brewfile requires a value"
        BREWFILE_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "this script supports macOS only"
}

ensure_brewfile_exists() {
  [[ -f "$BREWFILE_PATH" ]] || fail "Brewfile not found: $BREWFILE_PATH"
}

detect_brew_bin() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi

  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '%s\n' /opt/homebrew/bin/brew
    return 0
  fi

  if [[ -x /usr/local/bin/brew ]]; then
    printf '%s\n' /usr/local/bin/brew
    return 0
  fi

  return 1
}

preferred_brew_bin() {
  case "$(uname -m)" in
    arm64)
      printf '%s\n' /opt/homebrew/bin/brew
      ;;
    x86_64)
      printf '%s\n' /usr/local/bin/brew
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_brew_bin() {
  local attempt=0
  local max_attempts=30
  local brew_bin
  local preferred_bin

  preferred_bin="$(preferred_brew_bin 2>/dev/null || true)"

  while [[ "$attempt" -lt "$max_attempts" ]]; do
    if brew_bin="$(detect_brew_bin)"; then
      printf '%s\n' "$brew_bin"
      return 0
    fi

    if [[ -n "$preferred_bin" && -x "$preferred_bin" ]]; then
      printf '%s\n' "$preferred_bin"
      return 0
    fi

    sleep 2
    attempt=$((attempt + 1))
  done

  return 1
}

install_homebrew_if_needed() {
  local brew_bin

  if brew_bin="$(detect_brew_bin)"; then
    printf '%s\n' "$brew_bin"
    return 0
  fi

  log "Homebrew not found. Installing it now"
  log "Administrator privileges may be requested once by the official installer"

  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  brew_bin="$(wait_for_brew_bin)" || fail "Homebrew installation finished, but brew was not found in /opt/homebrew/bin or /usr/local/bin"
  printf '%s\n' "$brew_bin"
}

load_brew_env() {
  local brew_bin="$1"
  eval "$("$brew_bin" shellenv)"
}

upsert_managed_block() {
  local target_file="$1"
  local block_start="$2"
  local block_end="$3"
  local content_file="$4"
  local tmp_file

  touch "$target_file"
  tmp_file="$(mktemp)"

  awk -v start="$block_start" -v end="$block_end" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$target_file" > "$tmp_file"

  {
    cat "$tmp_file"
    printf '\n%s\n' "$block_start"
    cat "$content_file"
    printf '%s\n' "$block_end"
  } > "$target_file"

  rm -f "$tmp_file"
}

persist_brew_shellenv() {
  local brew_bin="$1"
  local target_file="$HOME/.zprofile"
  local block_start="# >>> homebrew shellenv managed by ${SCRIPT_NAME} >>>"
  local block_end="# <<< homebrew shellenv managed by ${SCRIPT_NAME} <<<"
  local managed_block_file

  managed_block_file="$(mktemp)"
  printf 'eval "$(%s shellenv)"\n' "$brew_bin" > "$managed_block_file"
  upsert_managed_block "$target_file" "$block_start" "$block_end" "$managed_block_file"
  rm -f "$managed_block_file"
}

run_brew_update() {
  if [[ "$RUN_BREW_UPDATE" -eq 0 ]]; then
    log "Skipping brew update"
    export HOMEBREW_NO_AUTO_UPDATE=1
    return 0
  fi

  log "Updating Homebrew metadata"
  brew update --quiet
  export HOMEBREW_NO_AUTO_UPDATE=1
}

install_from_brewfile() {
  local bundle_args=(bundle install "--file=${BREWFILE_PATH}" --verbose)

  if [[ "$RUN_BREW_UPGRADE" -eq 1 ]]; then
    log "Installing and upgrading apps from ${BREWFILE_PATH}"
    bundle_args+=(--upgrade)
  else
    log "Installing apps from ${BREWFILE_PATH} without upgrading existing installs"
    bundle_args+=(--no-upgrade)
  fi

  brew "${bundle_args[@]}"
}

find_app_path() {
  local app_name="$1"

  if [[ -d "/Applications/${app_name}" ]]; then
    printf '%s\n' "/Applications/${app_name}"
    return 0
  fi

  if [[ -d "${HOME}/Applications/${app_name}" ]]; then
    printf '%s\n' "${HOME}/Applications/${app_name}"
    return 0
  fi

  return 1
}

assert_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "expected command not found in PATH: $command_name"
}

verify_installation() {
  local app_name
  local app_path

  log "Verifying installed tools and apps"
  brew bundle check "--file=${BREWFILE_PATH}" >/dev/null
  assert_command brew

  for app_name in \
    "Google Chrome.app" \
    "Claude.app" \
    "ChatGPT.app" \
    "Codex.app" \
    "Visual Studio Code.app" \
    "Cursor.app"
  do
    if app_path="$(find_app_path "$app_name")"; then
      log "Verified ${app_name} at ${app_path}"
    else
      warn "${app_name} was installed by Homebrew, but the app bundle was not found in /Applications or ~/Applications yet"
    fi
  done
}

print_next_steps() {
  cat <<'EOF'

Next steps:
  1. Restart Terminal or run: source ~/.zprofile
  2. Open Claude, ChatGPT, Codex, Cursor, and VS Code once to complete sign-in
  3. If this is your standard baseline, copy this script and Brewfile to the other Macs and run the same command
EOF
}

main() {
  local brew_bin

  parse_args "$@"
  ensure_macos
  ensure_brewfile_exists

  brew_bin="$(install_homebrew_if_needed)"
  load_brew_env "$brew_bin"
  persist_brew_shellenv "$brew_bin"
  run_brew_update
  install_from_brewfile
  verify_installation
  print_next_steps
}

main "$@"
