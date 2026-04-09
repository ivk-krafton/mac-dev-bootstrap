#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_BACKUP_ROOT="${HOME}/Downloads"
DEFAULT_WORKSPACE_ROOT="${FDE_WORKSPACE_ROOT:-${HOME}/Desktop}"
TS="$(date +%Y%m%d-%H%M%S)"
TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
USER_SAFE="$(whoami 2>/dev/null || echo unknown-user)"

NAME=""
DISPLAY_NAME_SAFE=""
CANDIDATE_SAFE=""
COMMAND="${1:-}"
FORCE=0
RESTORE_FROM=""

BACKUP_DIR=""
AGENT_LOGS_DIR=""
WORK_PRODUCTS_DIR=""
SUBMISSIONS_DIR=""
MANIFEST_PATH=""
REPORT_PATH=""

WORKSPACE_ROOT=""
WORKSPACE_FOLDER_NAME=""
WORKSPACE_STAMP=""
EXAM_DATE=""
WORKSPACE_DISCOVERY_NOTE=""
PROJECT_SUBMISSIONS_PATH="${PROJECT_ROOT}/.artifacts/submissions"

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

SNAPSHOT_FILE=""

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

cleanup_tmp() {
  [[ -n "${SNAPSHOT_FILE:-}" && -f "${SNAPSHOT_FILE:-}" ]] && rm -f "$SNAPSHOT_FILE"
}
trap cleanup_tmp EXIT

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION

시험 종료 후 로컬 AI 에이전트 로그와 시험 작업 폴더를 백업하고 초기화하는 스크립트입니다.
결과는 ~/Downloads 아래 최종 폴더 1개로 생성됩니다.

Usage:
  $SCRIPT_NAME inspect --name "<지원자명>"
  $SCRIPT_NAME backup --name "<지원자명>"
  $SCRIPT_NAME reset --name "<지원자명>" --force
  $SCRIPT_NAME restore --from /absolute/path/to/backup-dir --force

Commands:
  inspect      현재 탐지 경로, 파일 수, 용량, 생성될 최종 폴더 확인
  backup       ~/Downloads 아래 최종 백업 폴더 생성
  reset        backup + verify 후 원본 삭제/초기화
  restore      특정 백업 디렉터리에서 복원

Options:
  --name NAME  지원자 이름 (inspect / backup / reset에서 필수)
  --from DIR   restore 할 백업 디렉터리
  --force      실제 reset / restore 수행
USAGE
}

[[ "$(uname -s)" == "Darwin" ]] || die "This script is fixed for macOS only."
[[ -n "$COMMAND" ]] && shift || true

load_env_file() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file_path"
    set +a
  fi
}

load_project_env() {
  load_env_file "$PROJECT_ROOT/.env.local"
  load_env_file "$PROJECT_ROOT/.env"
}

expand_path() {
  local value="$1"
  if [[ "$value" == ~* ]]; then
    eval printf '%s' "$value"
  else
    printf '%s' "$value"
  fi
}

sanitize_segment() {
  local value="${1:-}"
  local fallback="${2:-item}"
  python3 - "$value" "$fallback" <<'PY'
import re
import sys
import unicodedata

value = unicodedata.normalize("NFKC", sys.argv[1] or "")
fallback = sys.argv[2]
value = re.sub(r'[\\/:*?"<>|]', "_", value)
value = re.sub(r"\s+", "-", value).strip("-_ ")
print(value or fallback)
PY
}

sanitize_display_name() {
  local value="${1:-}"
  local fallback="${2:-지원자}"
  python3 - "$value" "$fallback" <<'PY'
import re
import sys
import unicodedata

value = unicodedata.normalize("NFKC", sys.argv[1] or "")
fallback = sys.argv[2]
value = re.sub(r'[\\/:*?"<>|]', "_", value).strip()
print(value or fallback)
PY
}

json_get() {
  local json_input="$1"
  local json_path="$2"
  python3 - "$json_path" <<'PY' <<<"$json_input"
import json
import sys

path = sys.argv[1]
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)

value = json.loads(raw)
for part in path.split("."):
    if value is None:
        break
    if isinstance(value, list):
        try:
            value = value[int(part)]
        except Exception:
            value = None
    elif isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
if value is None:
    sys.exit(0)
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

path_size_bytes() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    echo 0
    return
  fi
  du -sk "$target" 2>/dev/null | awk '{print $1 * 1024}'
}

human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'function human(x){s="B KB MB GB TB"; split(s,a," "); i=1; while (x>=1024 && i<5){x/=1024;i++} return sprintf(i==1?"%d %s":"%.2f %s", x, a[i])} BEGIN{print human(b)}'
}

file_count() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    echo 0
    return
  fi
  if [[ -f "$target" ]]; then
    echo 1
    return
  fi
  find "$target" -type f 2>/dev/null | wc -l | tr -d ' '
}

append_snapshot() {
  local label="$1"
  local path_value="$2"
  local kind="$3"
  local stored_path="$path_value"
  local exists="no"
  local files="0"
  local bytes="0"

  if [[ -n "$path_value" && -e "$path_value" ]]; then
    exists="yes"
    files="$(file_count "$path_value")"
    bytes="$(path_size_bytes "$path_value")"
  fi

  [[ -n "$stored_path" ]] || stored_path="<not found>"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$kind" "$stored_path" "$exists" "$files" "$bytes" >> "$SNAPSHOT_FILE"
}

capture_snapshot() {
  SNAPSHOT_FILE="$(mktemp)"

  append_snapshot "Cursor workspaceStorage" "$CURSOR_WORKSPACE_STORAGE" "agent"
  append_snapshot "Cursor globalStorage" "$CURSOR_GLOBAL_STORAGE" "agent"
  append_snapshot "Claude history" "$CLAUDE_HISTORY" "agent"
  append_snapshot "Claude projects" "$CLAUDE_PROJECTS" "agent"
  append_snapshot "Claude todos" "$CLAUDE_TODOS" "agent"
  append_snapshot "Claude ide" "$CLAUDE_IDE" "agent"
  append_snapshot "Codex history" "$CODEX_HISTORY" "agent"
  append_snapshot "Codex sessions" "$CODEX_SESSIONS" "agent"
  append_snapshot "Codex config" "$CODEX_CONFIG" "config"
  append_snapshot "Codex AGENTS" "$CODEX_AGENTS" "config"
  append_snapshot "Codex AGENTS override" "$CODEX_AGENTS_OVERRIDE" "config"
  append_snapshot "Antigravity conversations" "$ANTIGRAVITY_CONVERSATIONS" "agent"
  append_snapshot "Antigravity brain" "$ANTIGRAVITY_BRAIN" "agent"
  append_snapshot "Antigravity implicit" "$ANTIGRAVITY_IMPLICIT" "agent"
  append_snapshot "Antigravity code tracker" "$ANTIGRAVITY_CODE_TRACKER" "agent"
  append_snapshot "Antigravity browser recordings" "$ANTIGRAVITY_BROWSER_RECORDINGS" "agent"
  append_snapshot "Antigravity knowledge" "$ANTIGRAVITY_KNOWLEDGE" "agent"
  append_snapshot "Antigravity context state" "$ANTIGRAVITY_CONTEXT_STATE" "agent"
  append_snapshot "Antigravity globalStorage" "$ANTIGRAVITY_GLOBAL_STORAGE" "agent"
  append_snapshot "Candidate workspace" "$WORKSPACE_ROOT" "work"
  append_snapshot "Project submissions" "$PROJECT_SUBMISSIONS_PATH" "submission"
}

print_snapshot_table() {
  printf '%-28s %-6s %-10s %-10s %s\n' "TARGET" "EXIST" "FILES" "SIZE" "PATH"
  while IFS=$'\t' read -r label _kind path_value exists files bytes; do
    printf '%-28s %-6s %-10s %-10s %s\n' "$label" "$exists" "$files" "$(human_size "$bytes")" "$path_value"
  done < "$SNAPSHOT_FILE"
}

format_exam_date_from_stamp() {
  local stamp="$1"
  if [[ "$stamp" =~ ^[0-9]{8}$ ]]; then
    printf '%s-%s-%s' "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}"
  else
    date +%F
  fi
}

discover_workspace() {
  local workspace_root="${FDE_WORKSPACE_ROOT:-$DEFAULT_WORKSPACE_ROOT}"
  local latest_path=""
  local latest_mtime="0"
  local candidates=()

  shopt -s nullglob
  for candidate in "$workspace_root"/fde-test_*_"$CANDIDATE_SAFE"_*; do
    [[ -d "$candidate" ]] || continue
    candidates+=("$candidate")
  done
  shopt -u nullglob

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    WORKSPACE_ROOT=""
    WORKSPACE_FOLDER_NAME=""
    WORKSPACE_STAMP=""
    EXAM_DATE="$(date +%F)"
    WORKSPACE_DISCOVERY_NOTE="No matching workspace found under ${workspace_root}"
    return 0
  fi

  for candidate in "${candidates[@]}"; do
    local mtime
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if [[ -z "$latest_path" || "$mtime" -gt "$latest_mtime" ]]; then
      latest_path="$candidate"
      latest_mtime="$mtime"
    fi
  done

  WORKSPACE_ROOT="$latest_path"
  WORKSPACE_FOLDER_NAME="$(basename "$latest_path")"
  WORKSPACE_STAMP="$(printf '%s\n' "$WORKSPACE_FOLDER_NAME" | awk -F'_' '{print $2}')"
  EXAM_DATE="$(format_exam_date_from_stamp "$WORKSPACE_STAMP")"

  if [[ "${#candidates[@]}" -gt 1 ]]; then
    WORKSPACE_DISCOVERY_NOTE="Matched ${#candidates[@]} workspaces; selected latest modified path"
  else
    WORKSPACE_DISCOVERY_NOTE="Matched 1 workspace"
  fi
}

prepare_runtime() {
  load_project_env
  DISPLAY_NAME_SAFE="$(sanitize_display_name "$NAME" "지원자")"
  CANDIDATE_SAFE="$(sanitize_segment "$NAME" "candidate")"
  discover_workspace
  BACKUP_DIR="${DEFAULT_BACKUP_ROOT}/${DISPLAY_NAME_SAFE}_시험종료정리_${TS}"
  AGENT_LOGS_DIR="${BACKUP_DIR}/${DISPLAY_NAME_SAFE}_에이전트채팅로그"
  WORK_PRODUCTS_DIR="${BACKUP_DIR}/${DISPLAY_NAME_SAFE}_작업물"
  SUBMISSIONS_DIR="${BACKUP_DIR}/${DISPLAY_NAME_SAFE}_제출물"
  MANIFEST_PATH="${BACKUP_DIR}/manifest.txt"
  REPORT_PATH="${BACKUP_DIR}/report.json"
}

stop_processes() {
  local names=(Cursor cursor claude codex Antigravity antigravity)
  for name in "${names[@]}"; do
    pkill -x "$name" >/dev/null 2>&1 || true
  done
  sleep 1
}

copy_if_exists() {
  local src="$1"
  local dst_parent="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$dst_parent"
    rsync -a "$src" "$dst_parent"
    log "Backed up: $src"
  else
    warn "Skipping missing path: $src"
  fi
}

copy_workspace_without_submissions() {
  local src="$1"
  local dst_parent="$2"
  [[ -n "$src" && -d "$src" ]] || return 0

  mkdir -p "$dst_parent"
  rsync -a --exclude='.artifacts/submissions' "$src" "$dst_parent"
  log "Backed up workspace without submissions: $src"
}

write_manifest() {
  {
    printf 'created_at=%s\n' "$TS_ISO"
    printf 'user=%s\n' "$USER_SAFE"
    printf 'candidate_name=%s\n' "$NAME"
    printf 'display_name_safe=%s\n' "$DISPLAY_NAME_SAFE"
    printf 'candidate_safe=%s\n' "$CANDIDATE_SAFE"
    printf 'project_root=%s\n' "$PROJECT_ROOT"
    printf 'workspace_root=%s\n' "$WORKSPACE_ROOT"
    printf 'workspace_note=%s\n' "$WORKSPACE_DISCOVERY_NOTE"
    printf 'backup_dir=%s\n' "$BACKUP_DIR"
    printf 'agent_logs_dir=%s\n' "$AGENT_LOGS_DIR"
    printf 'work_products_dir=%s\n' "$WORK_PRODUCTS_DIR"
    printf 'submissions_dir=%s\n' "$SUBMISSIONS_DIR"
    printf '\n[snapshot]\n'
    while IFS=$'\t' read -r label kind path_value exists files bytes; do
      printf '%s | %s | %s | files=%s | bytes=%s | %s\n' "$label" "$kind" "$exists" "$files" "$bytes" "$path_value"
    done < "$SNAPSHOT_FILE"
  } > "$MANIFEST_PATH"
}

write_report_json() {
  local mode="$1"
  local status="$2"
  local report_path="$3"

  python3 - "$SNAPSHOT_FILE" "$report_path" "$mode" "$status" "$TS_ISO" "$NAME" "$DISPLAY_NAME_SAFE" "$CANDIDATE_SAFE" "$PROJECT_ROOT" "$WORKSPACE_ROOT" "$WORKSPACE_DISCOVERY_NOTE" "$BACKUP_DIR" "$AGENT_LOGS_DIR" "$WORK_PRODUCTS_DIR" "$SUBMISSIONS_DIR" "$EXAM_DATE" <<'PY'
import json
import sys

(snapshot_path, report_path, mode, status, created_at, candidate_name, display_name_safe, candidate_safe, project_root,
 workspace_root, workspace_note, backup_dir, agent_logs_dir, work_products_dir, submissions_dir, exam_date) = sys.argv[1:]

sources = []
with open(snapshot_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.rstrip("\n")
        if not raw_line:
            continue
        label, kind, path_value, exists, files, bytes_value = raw_line.split("\t")
        sources.append(
            {
                "label": label,
                "kind": kind,
                "path": path_value,
                "exists": exists == "yes",
                "fileCount": int(files),
                "bytes": int(bytes_value),
            }
        )

payload = {
    "createdAt": created_at,
    "mode": mode,
    "status": status,
    "candidate": {
        "name": candidate_name,
        "displayNameSafe": display_name_safe,
        "safeName": candidate_safe,
    },
    "projectRoot": project_root,
    "workspace": {
        "root": workspace_root or None,
        "note": workspace_note,
    },
    "backup": {
        "directory": backup_dir,
        "agentLogsDir": agent_logs_dir,
        "workProductsDir": work_products_dir,
        "submissionsDir": submissions_dir,
    },
    "examDate": exam_date,
    "sources": sources,
}

with open(report_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

verify_expected_copy() {
  local source_path="$1"
  local backup_path="$2"
  if [[ -e "$source_path" && ! -e "$backup_path" ]]; then
    warn "Expected backup missing: $backup_path"
    return 1
  fi
  return 0
}

verify_backup() {
  local ok=1

  [[ -d "$BACKUP_DIR" ]] || { warn "Backup directory missing"; ok=0; }
  [[ -d "$AGENT_LOGS_DIR" ]] || { warn "Agent logs directory missing"; ok=0; }
  [[ -d "$WORK_PRODUCTS_DIR" ]] || { warn "Work products directory missing"; ok=0; }
  [[ -d "$SUBMISSIONS_DIR" ]] || { warn "Submissions directory missing"; ok=0; }
  [[ -f "$MANIFEST_PATH" ]] || { warn "Manifest missing"; ok=0; }
  [[ -f "$REPORT_PATH" ]] || { warn "Report missing"; ok=0; }

  verify_expected_copy "$CURSOR_WORKSPACE_STORAGE" "$AGENT_LOGS_DIR/cursor/User/workspaceStorage" || ok=0
  verify_expected_copy "$CURSOR_GLOBAL_STORAGE" "$AGENT_LOGS_DIR/cursor/User/globalStorage" || ok=0
  verify_expected_copy "$CLAUDE_HISTORY" "$AGENT_LOGS_DIR/claude/history.jsonl" || ok=0
  verify_expected_copy "$CLAUDE_PROJECTS" "$AGENT_LOGS_DIR/claude/projects" || ok=0
  verify_expected_copy "$CLAUDE_TODOS" "$AGENT_LOGS_DIR/claude/todos" || ok=0
  verify_expected_copy "$CLAUDE_IDE" "$AGENT_LOGS_DIR/claude/ide" || ok=0
  verify_expected_copy "$CODEX_HISTORY" "$AGENT_LOGS_DIR/codex/history.jsonl" || ok=0
  verify_expected_copy "$CODEX_SESSIONS" "$AGENT_LOGS_DIR/codex/sessions" || ok=0
  verify_expected_copy "$CODEX_CONFIG" "$AGENT_LOGS_DIR/codex/config.toml" || ok=0
  verify_expected_copy "$CODEX_AGENTS" "$AGENT_LOGS_DIR/codex/AGENTS.md" || ok=0
  verify_expected_copy "$CODEX_AGENTS_OVERRIDE" "$AGENT_LOGS_DIR/codex/AGENTS.override.md" || ok=0
  verify_expected_copy "$ANTIGRAVITY_CONVERSATIONS" "$AGENT_LOGS_DIR/antigravity/conversations" || ok=0
  verify_expected_copy "$ANTIGRAVITY_BRAIN" "$AGENT_LOGS_DIR/antigravity/brain" || ok=0
  verify_expected_copy "$ANTIGRAVITY_IMPLICIT" "$AGENT_LOGS_DIR/antigravity/implicit" || ok=0
  verify_expected_copy "$ANTIGRAVITY_CODE_TRACKER" "$AGENT_LOGS_DIR/antigravity/code_tracker" || ok=0
  verify_expected_copy "$ANTIGRAVITY_BROWSER_RECORDINGS" "$AGENT_LOGS_DIR/antigravity/browser_recordings" || ok=0
  verify_expected_copy "$ANTIGRAVITY_KNOWLEDGE" "$AGENT_LOGS_DIR/antigravity/knowledge" || ok=0
  verify_expected_copy "$ANTIGRAVITY_CONTEXT_STATE" "$AGENT_LOGS_DIR/antigravity/context_state" || ok=0
  verify_expected_copy "$ANTIGRAVITY_GLOBAL_STORAGE" "$AGENT_LOGS_DIR/antigravity/globalStorage" || ok=0

  if [[ -n "$WORKSPACE_ROOT" && -n "$WORKSPACE_FOLDER_NAME" ]]; then
    verify_expected_copy "$WORKSPACE_ROOT" "$WORK_PRODUCTS_DIR/$WORKSPACE_FOLDER_NAME" || ok=0
  fi
  verify_expected_copy "$PROJECT_SUBMISSIONS_PATH" "$SUBMISSIONS_DIR/submissions" || ok=0

  [[ "$ok" -eq 1 ]] || die "Backup verification failed. Nothing will be reset."

  log "Backup verification passed"
  log "Backup dir: $BACKUP_DIR"
}

print_final_folder_preview() {
  echo "Final folder     : $BACKUP_DIR"
  echo "1. Agent logs    : $AGENT_LOGS_DIR"
  echo "2. Work products : $WORK_PRODUCTS_DIR"
  echo "3. Submissions   : $SUBMISSIONS_DIR"
}

run_inspect() {
  capture_snapshot

  echo "Candidate       : $NAME"
  echo "Candidate safe  : $DISPLAY_NAME_SAFE"
  echo "Project root    : $PROJECT_ROOT"
  echo "Workspace root  : ${WORKSPACE_ROOT:-<not found>}"
  echo "Workspace note  : $WORKSPACE_DISCOVERY_NOTE"
  echo "Exam date       : $EXAM_DATE"
  print_final_folder_preview
  echo ""
  print_snapshot_table
}

do_backup() {
  require_cmd rsync
  require_cmd python3
  mkdir -p "$BACKUP_DIR" "$AGENT_LOGS_DIR" "$WORK_PRODUCTS_DIR" "$SUBMISSIONS_DIR"

  stop_processes
  capture_snapshot

  copy_if_exists "$CURSOR_WORKSPACE_STORAGE" "$AGENT_LOGS_DIR/cursor/User/"
  copy_if_exists "$CURSOR_GLOBAL_STORAGE" "$AGENT_LOGS_DIR/cursor/User/"
  copy_if_exists "$CLAUDE_HISTORY" "$AGENT_LOGS_DIR/claude/"
  copy_if_exists "$CLAUDE_PROJECTS" "$AGENT_LOGS_DIR/claude/"
  copy_if_exists "$CLAUDE_TODOS" "$AGENT_LOGS_DIR/claude/"
  copy_if_exists "$CLAUDE_IDE" "$AGENT_LOGS_DIR/claude/"
  copy_if_exists "$CODEX_HISTORY" "$AGENT_LOGS_DIR/codex/"
  copy_if_exists "$CODEX_SESSIONS" "$AGENT_LOGS_DIR/codex/"
  copy_if_exists "$CODEX_CONFIG" "$AGENT_LOGS_DIR/codex/"
  copy_if_exists "$CODEX_AGENTS" "$AGENT_LOGS_DIR/codex/"
  copy_if_exists "$CODEX_AGENTS_OVERRIDE" "$AGENT_LOGS_DIR/codex/"
  copy_if_exists "$ANTIGRAVITY_CONVERSATIONS" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_BRAIN" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_IMPLICIT" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_CODE_TRACKER" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_BROWSER_RECORDINGS" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_KNOWLEDGE" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_CONTEXT_STATE" "$AGENT_LOGS_DIR/antigravity/"
  copy_if_exists "$ANTIGRAVITY_GLOBAL_STORAGE" "$AGENT_LOGS_DIR/antigravity/"

  copy_workspace_without_submissions "$WORKSPACE_ROOT" "$WORK_PRODUCTS_DIR/"

  copy_if_exists "$PROJECT_SUBMISSIONS_PATH" "$SUBMISSIONS_DIR/"

  write_manifest
  write_report_json "backup" "backup_completed" "$REPORT_PATH"
  verify_backup
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

remove_dir_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    rm -rf "$target"
    log "Removed directory: $target"
  fi
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

  remove_dir_if_exists "$WORKSPACE_ROOT"
  remove_contents "$PROJECT_SUBMISSIONS_PATH"

  write_report_json "reset" "reset_completed" "$REPORT_PATH"
  log "Reset completed after verified local backup"
}

do_restore() {
  [[ "$FORCE" -eq 1 ]] || die "restore requires --force"
  [[ -n "$RESTORE_FROM" ]] || die "restore requires --from DIR"
  RESTORE_FROM="$(expand_path "$RESTORE_FROM")"
  [[ -d "$RESTORE_FROM" ]] || die "Backup directory not found: $RESTORE_FROM"
  require_cmd rsync

  local agent_dir work_dir submission_dir
  agent_dir="$(find "$RESTORE_FROM" -maxdepth 1 -type d -name '*_에이전트채팅로그' | head -n 1)"
  work_dir="$(find "$RESTORE_FROM" -maxdepth 1 -type d -name '*_작업물' | head -n 1)"
  submission_dir="$(find "$RESTORE_FROM" -maxdepth 1 -type d -name '*_제출물' | head -n 1)"

  stop_processes

  if [[ -d "$agent_dir/cursor/User/workspaceStorage" ]]; then
    rm -rf "$CURSOR_WORKSPACE_STORAGE"
    mkdir -p "$(dirname "$CURSOR_WORKSPACE_STORAGE")"
    rsync -a "$agent_dir/cursor/User/workspaceStorage" "$(dirname "$CURSOR_WORKSPACE_STORAGE")/"
  fi
  if [[ -d "$agent_dir/cursor/User/globalStorage" ]]; then
    rm -rf "$CURSOR_GLOBAL_STORAGE"
    mkdir -p "$(dirname "$CURSOR_GLOBAL_STORAGE")"
    rsync -a "$agent_dir/cursor/User/globalStorage" "$(dirname "$CURSOR_GLOBAL_STORAGE")/"
  fi

  mkdir -p "$CLAUDE_ROOT"
  [[ -f "$agent_dir/claude/history.jsonl" ]] && rsync -a "$agent_dir/claude/history.jsonl" "$CLAUDE_ROOT/"
  [[ -d "$agent_dir/claude/projects" ]] && { rm -rf "$CLAUDE_PROJECTS"; rsync -a "$agent_dir/claude/projects" "$CLAUDE_ROOT/"; }
  [[ -d "$agent_dir/claude/todos" ]] && { rm -rf "$CLAUDE_TODOS"; rsync -a "$agent_dir/claude/todos" "$CLAUDE_ROOT/"; }
  [[ -d "$agent_dir/claude/ide" ]] && { rm -rf "$CLAUDE_IDE"; rsync -a "$agent_dir/claude/ide" "$CLAUDE_ROOT/"; }

  mkdir -p "$CODEX_ROOT"
  [[ -f "$agent_dir/codex/history.jsonl" ]] && rsync -a "$agent_dir/codex/history.jsonl" "$CODEX_ROOT/"
  [[ -d "$agent_dir/codex/sessions" ]] && { rm -rf "$CODEX_SESSIONS"; rsync -a "$agent_dir/codex/sessions" "$CODEX_ROOT/"; }
  [[ -f "$agent_dir/codex/config.toml" ]] && rsync -a "$agent_dir/codex/config.toml" "$CODEX_ROOT/"
  [[ -f "$agent_dir/codex/AGENTS.md" ]] && rsync -a "$agent_dir/codex/AGENTS.md" "$CODEX_ROOT/"
  [[ -f "$agent_dir/codex/AGENTS.override.md" ]] && rsync -a "$agent_dir/codex/AGENTS.override.md" "$CODEX_ROOT/"

  mkdir -p "$ANTIGRAVITY_ROOT" "$ANTIGRAVITY_CONFIG_ROOT"
  [[ -d "$agent_dir/antigravity/conversations" ]] && { rm -rf "$ANTIGRAVITY_CONVERSATIONS"; rsync -a "$agent_dir/antigravity/conversations" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/brain" ]] && { rm -rf "$ANTIGRAVITY_BRAIN"; rsync -a "$agent_dir/antigravity/brain" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/implicit" ]] && { rm -rf "$ANTIGRAVITY_IMPLICIT"; rsync -a "$agent_dir/antigravity/implicit" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/code_tracker" ]] && { rm -rf "$ANTIGRAVITY_CODE_TRACKER"; rsync -a "$agent_dir/antigravity/code_tracker" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/browser_recordings" ]] && { rm -rf "$ANTIGRAVITY_BROWSER_RECORDINGS"; rsync -a "$agent_dir/antigravity/browser_recordings" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/knowledge" ]] && { rm -rf "$ANTIGRAVITY_KNOWLEDGE"; rsync -a "$agent_dir/antigravity/knowledge" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/context_state" ]] && { rm -rf "$ANTIGRAVITY_CONTEXT_STATE"; rsync -a "$agent_dir/antigravity/context_state" "$ANTIGRAVITY_ROOT/"; }
  [[ -d "$agent_dir/antigravity/globalStorage" ]] && { rm -rf "$ANTIGRAVITY_GLOBAL_STORAGE"; mkdir -p "$ANTIGRAVITY_CONFIG_ROOT"; rsync -a "$agent_dir/antigravity/globalStorage" "$ANTIGRAVITY_CONFIG_ROOT/"; }

  if [[ -d "$work_dir" ]]; then
    local restored_workspace
    restored_workspace="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -n "$restored_workspace" ]]; then
      mkdir -p "${FDE_WORKSPACE_ROOT:-$DEFAULT_WORKSPACE_ROOT}"
      rsync -a "$restored_workspace" "${FDE_WORKSPACE_ROOT:-$DEFAULT_WORKSPACE_ROOT}/"
    fi
  fi

  if [[ -d "$submission_dir/submissions" ]]; then
    mkdir -p "$PROJECT_ROOT/.artifacts"
    rm -rf "$PROJECT_SUBMISSIONS_PATH"
    rsync -a "$submission_dir/submissions" "$PROJECT_ROOT/.artifacts/"
  fi

  log "Restore completed from: $RESTORE_FROM"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        NAME="${2:-}"
        shift 2
        ;;
      --from)
        RESTORE_FROM="${2:-}"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  load_project_env

  case "$COMMAND" in
    inspect|backup|reset)
      [[ -n "$NAME" ]] || die "--name is required for $COMMAND"
      prepare_runtime
      ;;
    restore)
      :
      ;;
    ""|-h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "Unknown command: $COMMAND"
      ;;
  esac

  case "$COMMAND" in
    inspect)
      run_inspect
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
  esac
}

main "$@"

