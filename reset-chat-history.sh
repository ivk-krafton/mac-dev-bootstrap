#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.3.0"
DEFAULT_BACKUP_ROOT="${HOME}/Downloads"
TS="$(date +%Y%m%d-%H%M%S)"
USER_SAFE="$(whoami 2>/dev/null || echo unknown-user)"
BACKUP_DIR="${DEFAULT_BACKUP_ROOT}/ai-exam-backup-${TS}"
ARCHIVE_PATH="${BACKUP_DIR}.tar.gz"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION

macOS 시험용 로컬 AI 환경(Cursor / Claude Code / Codex / Antigravity) 백업 및 초기화 스크립트
- 백업 위치는 항상 ~/Downloads 고정
- 백업이 정상적으로 검증된 경우에만 원본 삭제
- 라벨/백업 경로 등 추가 인자를 받지 않음

Usage:
  $SCRIPT_NAME inspect
  $SCRIPT_NAME backup
  $SCRIPT_NAME reset --force
  $SCRIPT_NAME restore --from /absolute/or/tilde/path --force

Commands:
  inspect      현재 경로 탐지 및 파일 개수/용량 점검
  backup       ~/Downloads 아래에 백업 생성 및 검증
  reset        백업 + 검증 성공 후 원본 삭제/초기화
  restore      특정 백업본 복원

Options:
  --from DIR   restore 할 백업 디렉터리
  --force      실제 삭제/복원 수행
USAGE
}

[[ "$(uname -s)" == "Darwin" ]] || die "This script is fixed for macOS only."

CURSOR_BASE="${HOME}/Library/Application Support/Cursor/User"
CURSOR_WORKSPACE_STORAGE="${CURSOR_BASE}/workspaceStorage"
CURSOR_GLOBAL_STORAGE="${CURSOR_BASE}/globalStorage"
CLAUDE_ROOT="${HOME}/.claude"
CLAUDE_HISTORY="${CLAUDE_ROOT}/history.jsonl"
CLAUDE_PROJECTS="${CLAUDE_ROOT}/projects"
CLAUDE_TODOS="${CLAUDE_ROOT}/todos"
CLAUDE_IDE="${CLAUDE_ROOT}/ide"
CODEX_ROOT="${HOME}/.codex"
CODEX_HISTORY="${CODEX_ROOT}/history.jsonl"
CODEX_SESSIONS="${CODEX_ROOT}/sessions"
CODEX_CONFIG="${CODEX_ROOT}/config.toml"
CODEX_AGENTS="${CODEX_ROOT}/AGENTS.md"
CODEX_AGENTS_OVERRIDE="${CODEX_ROOT}/AGENTS.override.md"
ANTIGRAVITY_ROOT="${HOME}/.gemini/antigravity"
ANTIGRAVITY_CONVERSATIONS="${ANTIGRAVITY_ROOT}/conversations"
ANTIGRAVITY_BRAIN="${ANTIGRAVITY_ROOT}/brain"
ANTIGRAVITY_IMPLICIT="${ANTIGRAVITY_ROOT}/implicit"
ANTIGRAVITY_CODE_TRACKER="${ANTIGRAVITY_ROOT}/code_tracker"
ANTIGRAVITY_BROWSER_RECORDINGS="${ANTIGRAVITY_ROOT}/browser_recordings"
ANTIGRAVITY_KNOWLEDGE="${ANTIGRAVITY_ROOT}/knowledge"
ANTIGRAVITY_CONTEXT_STATE="${ANTIGRAVITY_ROOT}/context_state"
ANTIGRAVITY_CONFIG_ROOT="${HOME}/Library/Application Support/Antigravity/User"
ANTIGRAVITY_GLOBAL_STORAGE="${ANTIGRAVITY_CONFIG_ROOT}/globalStorage"

FORCE=0
RESTORE_FROM=""
COMMAND="${1:-}"
[[ -n "$COMMAND" ]] && shift || true

expand_path() {
  local p="$1"
  if [[ "$p" == ~* ]]; then
    eval printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1; shift ;;
    --from)
      RESTORE_FROM="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage; exit 1; }
[[ -n "$RESTORE_FROM" ]] && RESTORE_FROM="$(expand_path "$RESTORE_FROM")"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

path_size_bytes() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    echo 0; return
  fi
  du -sk "$p" 2>/dev/null | awk '{print $1*1024}'
}

human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'function human(x){s="B KB MB GB TB"; split(s,a," "); i=1; while (x>=1024 && i<5){x/=1024;i++} return sprintf(i==1?"%d %s":"%.2f %s", x, a[i])} BEGIN{print human(b)}'
}

file_count() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    echo 0; return
  fi
  if [[ -f "$p" ]]; then
    echo 1; return
  fi
  find "$p" -type f 2>/dev/null | wc -l | tr -d ' '
}

stop_processes() {
  local names=(Cursor cursor claude codex)
  for name in "${names[@]}"; do
    pkill -x "$name" >/dev/null 2>&1 || true
  done
  sleep 1
}

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    rsync -a "$src" "$dst"
    log "Backed up: $src"
  else
    warn "Skipping missing path: $src"
  fi
}

safe_remove_file() {
  local target="$1"
  if [[ -f "$target" ]]; then
    rm -f "$target"
    log "Removed file: $target"
  fi
}

remove_contents() {
  local target="$1"
  if [[ -e "$target" ]]; then
    rm -rf "$target"
    mkdir -p "$target"
    log "Reset path: $target"
  else
    mkdir -p "$target"
    log "Created empty path: $target"
  fi
}

write_manifest() {
  local manifest="$1"
  cat > "$manifest" <<EOF_MANIFEST
created_at=$TS
user=$USER_SAFE
backup_dir=$BACKUP_DIR
archive_path=$ARCHIVE_PATH

[cursor]
workspace_path=$CURSOR_WORKSPACE_STORAGE
workspace_exists=$( [[ -e "$CURSOR_WORKSPACE_STORAGE" ]] && echo yes || echo no )
workspace_files=$(file_count "$CURSOR_WORKSPACE_STORAGE")
workspace_bytes=$(path_size_bytes "$CURSOR_WORKSPACE_STORAGE")
global_path=$CURSOR_GLOBAL_STORAGE
global_exists=$( [[ -e "$CURSOR_GLOBAL_STORAGE" ]] && echo yes || echo no )
global_files=$(file_count "$CURSOR_GLOBAL_STORAGE")
global_bytes=$(path_size_bytes "$CURSOR_GLOBAL_STORAGE")

[claude_code]
history_path=$CLAUDE_HISTORY
history_exists=$( [[ -e "$CLAUDE_HISTORY" ]] && echo yes || echo no )
history_files=$(file_count "$CLAUDE_HISTORY")
history_bytes=$(path_size_bytes "$CLAUDE_HISTORY")
projects_path=$CLAUDE_PROJECTS
projects_exists=$( [[ -e "$CLAUDE_PROJECTS" ]] && echo yes || echo no )
projects_files=$(file_count "$CLAUDE_PROJECTS")
projects_bytes=$(path_size_bytes "$CLAUDE_PROJECTS")
todos_path=$CLAUDE_TODOS
todos_exists=$( [[ -e "$CLAUDE_TODOS" ]] && echo yes || echo no )
todos_files=$(file_count "$CLAUDE_TODOS")
todos_bytes=$(path_size_bytes "$CLAUDE_TODOS")
ide_path=$CLAUDE_IDE
ide_exists=$( [[ -e "$CLAUDE_IDE" ]] && echo yes || echo no )
ide_files=$(file_count "$CLAUDE_IDE")
ide_bytes=$(path_size_bytes "$CLAUDE_IDE")

[codex]
history_path=$CODEX_HISTORY
history_exists=$( [[ -e "$CODEX_HISTORY" ]] && echo yes || echo no )
history_files=$(file_count "$CODEX_HISTORY")
history_bytes=$(path_size_bytes "$CODEX_HISTORY")
sessions_path=$CODEX_SESSIONS
sessions_exists=$( [[ -e "$CODEX_SESSIONS" ]] && echo yes || echo no )
sessions_files=$(file_count "$CODEX_SESSIONS")
sessions_bytes=$(path_size_bytes "$CODEX_SESSIONS")
config_path=$CODEX_CONFIG
config_exists=$( [[ -e "$CODEX_CONFIG" ]] && echo yes || echo no )
config_files=$(file_count "$CODEX_CONFIG")
config_bytes=$(path_size_bytes "$CODEX_CONFIG")

[antigravity]
conversations_path=$ANTIGRAVITY_CONVERSATIONS
conversations_exists=$( [[ -e "$ANTIGRAVITY_CONVERSATIONS" ]] && echo yes || echo no )
conversations_files=$(file_count "$ANTIGRAVITY_CONVERSATIONS")
conversations_bytes=$(path_size_bytes "$ANTIGRAVITY_CONVERSATIONS")
brain_path=$ANTIGRAVITY_BRAIN
brain_exists=$( [[ -e "$ANTIGRAVITY_BRAIN" ]] && echo yes || echo no )
brain_files=$(file_count "$ANTIGRAVITY_BRAIN")
brain_bytes=$(path_size_bytes "$ANTIGRAVITY_BRAIN")
implicit_path=$ANTIGRAVITY_IMPLICIT
implicit_exists=$( [[ -e "$ANTIGRAVITY_IMPLICIT" ]] && echo yes || echo no )
implicit_files=$(file_count "$ANTIGRAVITY_IMPLICIT")
implicit_bytes=$(path_size_bytes "$ANTIGRAVITY_IMPLICIT")
code_tracker_path=$ANTIGRAVITY_CODE_TRACKER
code_tracker_exists=$( [[ -e "$ANTIGRAVITY_CODE_TRACKER" ]] && echo yes || echo no )
code_tracker_files=$(file_count "$ANTIGRAVITY_CODE_TRACKER")
code_tracker_bytes=$(path_size_bytes "$ANTIGRAVITY_CODE_TRACKER")
browser_recordings_path=$ANTIGRAVITY_BROWSER_RECORDINGS
browser_recordings_exists=$( [[ -e "$ANTIGRAVITY_BROWSER_RECORDINGS" ]] && echo yes || echo no )
browser_recordings_files=$(file_count "$ANTIGRAVITY_BROWSER_RECORDINGS")
browser_recordings_bytes=$(path_size_bytes "$ANTIGRAVITY_BROWSER_RECORDINGS")
knowledge_path=$ANTIGRAVITY_KNOWLEDGE
knowledge_exists=$( [[ -e "$ANTIGRAVITY_KNOWLEDGE" ]] && echo yes || echo no )
knowledge_files=$(file_count "$ANTIGRAVITY_KNOWLEDGE")
knowledge_bytes=$(path_size_bytes "$ANTIGRAVITY_KNOWLEDGE")
context_state_path=$ANTIGRAVITY_CONTEXT_STATE
context_state_exists=$( [[ -e "$ANTIGRAVITY_CONTEXT_STATE" ]] && echo yes || echo no )
context_state_files=$(file_count "$ANTIGRAVITY_CONTEXT_STATE")
context_state_bytes=$(path_size_bytes "$ANTIGRAVITY_CONTEXT_STATE")
global_storage_path=$ANTIGRAVITY_GLOBAL_STORAGE
global_storage_exists=$( [[ -e "$ANTIGRAVITY_GLOBAL_STORAGE" ]] && echo yes || echo no )
global_storage_files=$(file_count "$ANTIGRAVITY_GLOBAL_STORAGE")
global_storage_bytes=$(path_size_bytes "$ANTIGRAVITY_GLOBAL_STORAGE")
EOF_MANIFEST
}

verify_backup() {
  local ok=1
  [[ -d "$BACKUP_DIR" ]] || { warn "Backup directory missing"; ok=0; }
  [[ -f "$BACKUP_DIR/manifest.txt" ]] || { warn "Manifest missing"; ok=0; }

  if [[ -e "$CURSOR_WORKSPACE_STORAGE" && ! -e "$BACKUP_DIR/cursor/User/workspaceStorage" ]]; then
    warn "Cursor workspaceStorage backup missing"
    ok=0
  fi
  if [[ -e "$CURSOR_GLOBAL_STORAGE" && ! -e "$BACKUP_DIR/cursor/User/globalStorage" ]]; then
    warn "Cursor globalStorage backup missing"
    ok=0
  fi
  if [[ -e "$CLAUDE_HISTORY" && ! -e "$BACKUP_DIR/claude/history.jsonl" ]]; then
    warn "Claude history backup missing"
    ok=0
  fi
  if [[ -e "$CLAUDE_PROJECTS" && ! -e "$BACKUP_DIR/claude/projects" ]]; then
    warn "Claude projects backup missing"
    ok=0
  fi
  if [[ -e "$CODEX_HISTORY" && ! -e "$BACKUP_DIR/codex/history.jsonl" ]]; then
    warn "Codex history backup missing"
    ok=0
  fi
  if [[ -e "$CODEX_SESSIONS" && ! -e "$BACKUP_DIR/codex/sessions" ]]; then
    warn "Codex sessions backup missing"
    ok=0
  fi
  if [[ -e "$ANTIGRAVITY_CONVERSATIONS" && ! -e "$BACKUP_DIR/antigravity/conversations" ]]; then
    warn "Antigravity conversations backup missing"
    ok=0
  fi
  if [[ -e "$ANTIGRAVITY_BRAIN" && ! -e "$BACKUP_DIR/antigravity/brain" ]]; then
    warn "Antigravity brain backup missing"
    ok=0
  fi
  if [[ -e "$ANTIGRAVITY_GLOBAL_STORAGE" && ! -e "$BACKUP_DIR/antigravity/globalStorage" ]]; then
    warn "Antigravity globalStorage backup missing"
    ok=0
  fi

  tar -C "$DEFAULT_BACKUP_ROOT" -czf "$ARCHIVE_PATH" "$(basename "$BACKUP_DIR")"
  [[ -s "$ARCHIVE_PATH" ]] || { warn "Archive was not created correctly"; ok=0; }

  if [[ "$ok" -ne 1 ]]; then
    die "Backup verification failed. Nothing will be deleted."
  fi

  log "Backup verification passed"
  log "Backup dir: $BACKUP_DIR"
  log "Archive   : $ARCHIVE_PATH"
}

print_inspect() {
  printf '%-14s %-6s %-10s %-10s %s\n' "PRODUCT" "EXIST" "FILES" "SIZE" "PATH"
  printf '%-14s %-6s %-10s %-10s %s\n' "Cursor WS" "$( [[ -e "$CURSOR_WORKSPACE_STORAGE" ]] && echo yes || echo no )" "$(file_count "$CURSOR_WORKSPACE_STORAGE")" "$(human_size "$(path_size_bytes "$CURSOR_WORKSPACE_STORAGE")")" "$CURSOR_WORKSPACE_STORAGE"
  printf '%-14s %-6s %-10s %-10s %s\n' "Cursor Global" "$( [[ -e "$CURSOR_GLOBAL_STORAGE" ]] && echo yes || echo no )" "$(file_count "$CURSOR_GLOBAL_STORAGE")" "$(human_size "$(path_size_bytes "$CURSOR_GLOBAL_STORAGE")")" "$CURSOR_GLOBAL_STORAGE"
  printf '%-14s %-6s %-10s %-10s %s\n' "Claude hist" "$( [[ -e "$CLAUDE_HISTORY" ]] && echo yes || echo no )" "$(file_count "$CLAUDE_HISTORY")" "$(human_size "$(path_size_bytes "$CLAUDE_HISTORY")")" "$CLAUDE_HISTORY"
  printf '%-14s %-6s %-10s %-10s %s\n' "Claude proj" "$( [[ -e "$CLAUDE_PROJECTS" ]] && echo yes || echo no )" "$(file_count "$CLAUDE_PROJECTS")" "$(human_size "$(path_size_bytes "$CLAUDE_PROJECTS")")" "$CLAUDE_PROJECTS"
  printf '%-14s %-6s %-10s %-10s %s\n' "Claude todos" "$( [[ -e "$CLAUDE_TODOS" ]] && echo yes || echo no )" "$(file_count "$CLAUDE_TODOS")" "$(human_size "$(path_size_bytes "$CLAUDE_TODOS")")" "$CLAUDE_TODOS"
  printf '%-14s %-6s %-10s %-10s %s\n' "Claude ide" "$( [[ -e "$CLAUDE_IDE" ]] && echo yes || echo no )" "$(file_count "$CLAUDE_IDE")" "$(human_size "$(path_size_bytes "$CLAUDE_IDE")")" "$CLAUDE_IDE"
  printf '%-14s %-6s %-10s %-10s %s\n' "Codex hist" "$( [[ -e "$CODEX_HISTORY" ]] && echo yes || echo no )" "$(file_count "$CODEX_HISTORY")" "$(human_size "$(path_size_bytes "$CODEX_HISTORY")")" "$CODEX_HISTORY"
  printf '%-14s %-6s %-10s %-10s %s\n' "Codex sess" "$( [[ -e "$CODEX_SESSIONS" ]] && echo yes || echo no )" "$(file_count "$CODEX_SESSIONS")" "$(human_size "$(path_size_bytes "$CODEX_SESSIONS")")" "$CODEX_SESSIONS"
  printf '%-14s %-6s %-10s %-10s %s\n' "Antigrav conv" "$( [[ -e "$ANTIGRAVITY_CONVERSATIONS" ]] && echo yes || echo no )" "$(file_count "$ANTIGRAVITY_CONVERSATIONS")" "$(human_size "$(path_size_bytes "$ANTIGRAVITY_CONVERSATIONS")")" "$ANTIGRAVITY_CONVERSATIONS"
  printf '%-14s %-6s %-10s %-10s %s\n' "Antigrav brain" "$( [[ -e "$ANTIGRAVITY_BRAIN" ]] && echo yes || echo no )" "$(file_count "$ANTIGRAVITY_BRAIN")" "$(human_size "$(path_size_bytes "$ANTIGRAVITY_BRAIN")")" "$ANTIGRAVITY_BRAIN"
  printf '%-14s %-6s %-10s %-10s %s\n' "Antigrav gdb" "$( [[ -e "$ANTIGRAVITY_GLOBAL_STORAGE" ]] && echo yes || echo no )" "$(file_count "$ANTIGRAVITY_GLOBAL_STORAGE")" "$(human_size "$(path_size_bytes "$ANTIGRAVITY_GLOBAL_STORAGE")")" "$ANTIGRAVITY_GLOBAL_STORAGE"
  printf '\nBackup destination is fixed to: %s\n' "$DEFAULT_BACKUP_ROOT"
}

do_backup() {
  require_cmd rsync
  require_cmd tar
  mkdir -p "$BACKUP_DIR"
  stop_processes

  copy_if_exists "$CURSOR_WORKSPACE_STORAGE" "$BACKUP_DIR/cursor/User/"
  copy_if_exists "$CURSOR_GLOBAL_STORAGE" "$BACKUP_DIR/cursor/User/"
  copy_if_exists "$CLAUDE_HISTORY" "$BACKUP_DIR/claude/"
  copy_if_exists "$CLAUDE_PROJECTS" "$BACKUP_DIR/claude/"
  copy_if_exists "$CLAUDE_TODOS" "$BACKUP_DIR/claude/"
  copy_if_exists "$CLAUDE_IDE" "$BACKUP_DIR/claude/"
  copy_if_exists "$CODEX_HISTORY" "$BACKUP_DIR/codex/"
  copy_if_exists "$CODEX_SESSIONS" "$BACKUP_DIR/codex/"
  copy_if_exists "$CODEX_CONFIG" "$BACKUP_DIR/codex/"
  copy_if_exists "$CODEX_AGENTS" "$BACKUP_DIR/codex/"
  copy_if_exists "$CODEX_AGENTS_OVERRIDE" "$BACKUP_DIR/codex/"

  copy_if_exists "$ANTIGRAVITY_CONVERSATIONS" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_BRAIN" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_IMPLICIT" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_CODE_TRACKER" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_BROWSER_RECORDINGS" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_KNOWLEDGE" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_CONTEXT_STATE" "$BACKUP_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_GLOBAL_STORAGE" "$BACKUP_DIR/antigravity/"

  write_manifest "$BACKUP_DIR/manifest.txt"
  verify_backup
}

do_reset() {
  [[ "$FORCE" -eq 1 ]] || die "reset requires --force"
  do_backup

  remove_contents "$CURSOR_WORKSPACE_STORAGE"
  remove_contents "$CURSOR_GLOBAL_STORAGE"
  safe_remove_file "$CLAUDE_HISTORY"
  remove_contents "$CLAUDE_PROJECTS"
  remove_contents "$CLAUDE_TODOS"
  remove_contents "$CLAUDE_IDE"
  safe_remove_file "$CODEX_HISTORY"
  remove_contents "$CODEX_SESSIONS"

  remove_contents "$ANTIGRAVITY_CONVERSATIONS"
  remove_contents "$ANTIGRAVITY_BRAIN"
  remove_contents "$ANTIGRAVITY_IMPLICIT"
  remove_contents "$ANTIGRAVITY_CODE_TRACKER"
  remove_contents "$ANTIGRAVITY_BROWSER_RECORDINGS"
  remove_contents "$ANTIGRAVITY_KNOWLEDGE"
  remove_contents "$ANTIGRAVITY_CONTEXT_STATE"
  remove_contents "$ANTIGRAVITY_GLOBAL_STORAGE"

  log "Reset completed only after verified backup"
}

do_restore() {
  [[ "$FORCE" -eq 1 ]] || die "restore requires --force"
  [[ -n "$RESTORE_FROM" ]] || die "restore requires --from DIR"
  [[ -d "$RESTORE_FROM" ]] || die "Backup directory not found: $RESTORE_FROM"
  require_cmd rsync
  stop_processes

  if [[ -d "$RESTORE_FROM/cursor/User/workspaceStorage" ]]; then
    rm -rf "$CURSOR_WORKSPACE_STORAGE"
    mkdir -p "$(dirname "$CURSOR_WORKSPACE_STORAGE")"
    rsync -a "$RESTORE_FROM/cursor/User/workspaceStorage" "$(dirname "$CURSOR_WORKSPACE_STORAGE")/"
  fi
  if [[ -d "$RESTORE_FROM/cursor/User/globalStorage" ]]; then
    rm -rf "$CURSOR_GLOBAL_STORAGE"
    mkdir -p "$(dirname "$CURSOR_GLOBAL_STORAGE")"
    rsync -a "$RESTORE_FROM/cursor/User/globalStorage" "$(dirname "$CURSOR_GLOBAL_STORAGE")/"
  fi

  mkdir -p "$CLAUDE_ROOT"
  [[ -f "$RESTORE_FROM/claude/history.jsonl" ]] && rsync -a "$RESTORE_FROM/claude/history.jsonl" "$CLAUDE_ROOT/"
  [[ -d "$RESTORE_FROM/claude/projects" ]] && { rm -rf "$CLAUDE_PROJECTS"; rsync -a "$RESTORE_FROM/claude/projects" "$CLAUDE_ROOT/"; }
  [[ -d "$RESTORE_FROM/claude/todos" ]] && { rm -rf "$CLAUDE_TODOS"; rsync -a "$RESTORE_FROM/claude/todos" "$CLAUDE_ROOT/"; }
  [[ -d "$RESTORE_FROM/claude/ide" ]] && { rm -rf "$CLAUDE_IDE"; rsync -a "$RESTORE_FROM/claude/ide" "$CLAUDE_ROOT/"; }

  mkdir -p "$CODEX_ROOT"
  [[ -f "$RESTORE_FROM/codex/history.jsonl" ]] && rsync -a "$RESTORE_FROM/codex/history.jsonl" "$CODEX_ROOT/"
  [[ -d "$RESTORE_FROM/codex/sessions" ]] && { rm -rf "$CODEX_SESSIONS"; rsync -a "$RESTORE_FROM/codex/sessions" "$CODEX_ROOT/"; }
  [[ -f "$RESTORE_FROM/codex/config.toml" ]] && rsync -a "$RESTORE_FROM/codex/config.toml" "$CODEX_ROOT/"
  [[ -f "$RESTORE_FROM/codex/AGENTS.md" ]] && rsync -a "$RESTORE_FROM/codex/AGENTS.md" "$CODEX_ROOT/"
  [[ -f "$RESTORE_FROM/codex/AGENTS.override.md" ]] && rsync -a "$RESTORE_FROM/codex/AGENTS.override.md" "$CODEX_ROOT/"

  mkdir -p "$ANTIGRAVITY_ROOT" "$ANTIGRAVITY_CONFIG_ROOT"
  [[ -d "$RESTORE_FROM/antigravity/conversations" ]] && { rm -rf "$ANTIGRAVITY_CONVERSATIONS"; rsync -a "$RESTORE_FROM/antigravity/conversations" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/brain" ]] && { rm -rf "$ANTIGRAVITY_BRAIN"; rsync -a "$RESTORE_FROM/antigravity/brain" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/implicit" ]] && { rm -rf "$ANTIGRAVITY_IMPLICIT"; rsync -a "$RESTORE_FROM/antigravity/implicit" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/code_tracker" ]] && { rm -rf "$ANTIGRAVITY_CODE_TRACKER"; rsync -a "$RESTORE_FROM/antigravity/code_tracker" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/browser_recordings" ]] && { rm -rf "$ANTIGRAVITY_BROWSER_RECORDINGS"; rsync -a "$RESTORE_FROM/antigravity/browser_recordings" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/knowledge" ]] && { rm -rf "$ANTIGRAVITY_KNOWLEDGE"; rsync -a "$RESTORE_FROM/antigravity/knowledge" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/context_state" ]] && { rm -rf "$ANTIGRAVITY_CONTEXT_STATE"; rsync -a "$RESTORE_FROM/antigravity/context_state" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$RESTORE_FROM/antigravity/globalStorage" ]] && { rm -rf "$ANTIGRAVITY_GLOBAL_STORAGE"; mkdir -p "$ANTIGRAVITY_CONFIG_ROOT"; rsync -a "$RESTORE_FROM/antigravity/globalStorage" "$ANTIGRAVITY_CONFIG_ROOT/"; }

  log "Restore completed from: $RESTORE_FROM"
}

case "$COMMAND" in
  inspect)
    print_inspect
    ;;
  backup)
    do_backup
    ;;
  reset)
    do_reset
    ;;
  restore)
    do_restore
    ;;
  *)
    usage
    die "Unknown command: $COMMAND"
    ;;
esac
