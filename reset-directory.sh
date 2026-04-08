#!/bin/zsh
set -euo pipefail

TARGETS=(
  "$HOME/Downloads"
  "$HOME/Documents"
)

echo "다음 폴더를 비웁니다:"
printf ' - %s\n' "${TARGETS[@]}"
echo

read "confirm?정말 진행할까요? [y/N]: "
echo
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "취소되었습니다."
  exit 0
fi

for dir in "${TARGETS[@]}"; do
  if [[ -d "$dir" ]]; then
    echo "비우는 중: $dir"
    rm -rf -- "$dir"/* "$dir"/.[!.]* "$dir"/..?* 2>/dev/null || true
  else
    echo "폴더 없음, 새로 생성: $dir"
    mkdir -p -- "$dir"
  fi
done

echo
echo "완료:"
for dir in "${TARGETS[@]}"; do
  echo " - $dir"
  ls -la "$dir"
  echo
done
