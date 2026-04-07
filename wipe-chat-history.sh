cat << 'EOF' > ~/wipe-ai-history.sh
#!/usr/bin/env bash
set -e

echo "== Cursor history =="
rm -rf "$HOME/Library/Application Support/Cursor/User/History" || true
rm -rf "$HOME/Library/Application Support/Cursor/User/workspaceStorage" || true

echo "== Claude Code CLI =="
rm -rf "$HOME/.claude/projects" || true

echo "== Codex sessions =="
rm -rf "$HOME/.codex/sessions" || true

echo "Done (local history folders deleted)."
EOF

chmod +x ~/wipe-ai-history.sh
