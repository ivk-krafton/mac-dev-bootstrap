#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE_PATH="${SCRIPT_DIR}/Brewfile.mac-ai-apps"
HOMEBREW_PKG_URL="https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg"
CLAUDE_CODE_INSTALL_URL="https://claude.ai/install.sh"
CLAUDE_CODE_CHANNEL="stable"
BREW_BIN=""
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
  - Installs Claude Code CLI from Anthropic's official stable installer

Default Brewfile:
  ${BREWFILE_PATH}

Installed tools:
  - Homebrew
  - Claude Code CLI (stable)
  - Google Chrome
  - Claude Desktop
  - ChatGPT Desktop
  - Codex Desktop
  - Visual Studio Code
  - Cursor

Notes:
  - Claude Desktop, Claude Code, ChatGPT, Codex, Cursor, and VS Code sign-in remains manual

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

detect_claude_bin() {
  local candidate

  if command -v claude >/dev/null 2>&1; then
    command -v claude
    return 0
  fi

  for candidate in \
    "$HOME/.local/bin/claude" \
    "/usr/local/bin/claude" \
    "/opt/homebrew/bin/claude"
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

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
  local tmp_dir
  local pkg_file

  if brew_bin="$(detect_brew_bin)"; then
    printf '%s\n' "$brew_bin"
    return 0
  fi

  log "Homebrew not found. Installing it now"
  log "Administrator privileges may be requested once to install the official Homebrew package"

  tmp_dir="$(mktemp -d)"
  pkg_file="${tmp_dir}/Homebrew.pkg"

  log "Downloading ${HOMEBREW_PKG_URL}"
  curl -fL "${HOMEBREW_PKG_URL}" -o "$pkg_file"

  log "Installing Homebrew package"
  sudo /usr/sbin/installer -pkg "$pkg_file" -target /

  brew_bin="$(wait_for_brew_bin)" || fail "Homebrew installation finished, but brew was not found in /opt/homebrew/bin or /usr/local/bin"
  rm -rf "$tmp_dir"
  printf '%s\n' "$brew_bin"
}

load_brew_env() {
  local brew_bin="$1"
  eval "$("$brew_bin" shellenv)"
  export PATH="$(dirname "$brew_bin"):$PATH"
}

brew_cmd() {
  [[ -n "$BREW_BIN" ]] || fail "internal error: BREW_BIN is not set"
  "$BREW_BIN" "$@"
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
  brew_cmd update --quiet
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

  brew_cmd "${bundle_args[@]}"
}

install_claude_code() {
  local claude_bin

  if [[ "$RUN_BREW_UPGRADE" -eq 0 ]] && claude_bin="$(detect_claude_bin)"; then
    log "Claude Code CLI already present at ${claude_bin}; skipping reinstall"
    return 0
  fi

  log "Installing Claude Code CLI (${CLAUDE_CODE_CHANNEL}) from ${CLAUDE_CODE_INSTALL_URL}"
  curl -fsSL "${CLAUDE_CODE_INSTALL_URL}" | bash -s "${CLAUDE_CODE_CHANNEL}"
  export PATH="$HOME/.local/bin:$PATH"
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

verify_installation() {
  local app_name
  local app_path
  local claude_bin

  log "Verifying installed tools and apps"
  brew_cmd bundle check "--file=${BREWFILE_PATH}" >/dev/null
  [[ -x "$BREW_BIN" ]] || fail "expected brew binary not found: $BREW_BIN"

  if claude_bin="$(detect_claude_bin)"; then
    log "Verified Claude Code CLI at ${claude_bin}"
  else
    warn "Claude Code CLI was not found in PATH, ~/.local/bin, /usr/local/bin, or /opt/homebrew/bin yet"
  fi

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
  2. Open Claude, Claude Code, ChatGPT, Codex, Cursor, and VS Code once to complete sign-in
  3. If this is your standard baseline, copy this script and Brewfile to the other Macs and run the same command
EOF
}

main() {
  parse_args "$@"
  ensure_macos
  ensure_brewfile_exists

  BREW_BIN="$(install_homebrew_if_needed)"
  load_brew_env "$BREW_BIN"
  persist_brew_shellenv "$BREW_BIN"
  run_brew_update
  install_from_brewfile
  install_claude_code
  verify_installation
  print_next_steps
}

main "$@"
