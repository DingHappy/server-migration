#!/usr/bin/env bash
# 03-backup-target.sh —— 在【目标机】运行。动手迁移前，先备份现有应用和 /etc，留回滚保险。
# 用法：./03-backup-target.sh [要额外备份的目录...]
# 例：  ./03-backup-target.sh /opt/oldapp /var/lib/oldapp
set -euo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
STAMP=$(date +%F-%H%M)
DEST="/root/migration-backups"
$SUDO mkdir -p "$DEST"

echo ">>> 备份目标机 /etc ..."
$SUDO tar -czf "$DEST/etc-$STAMP.tar.gz" /etc 2>/dev/null && \
  echo "    ✅ $DEST/etc-$STAMP.tar.gz"

for d in "$@"; do
  if [ -e "$d" ]; then
    name=$(echo "$d" | tr '/' '_' | sed 's/^_//')
    echo ">>> 备份 $d ..."
    $SUDO tar -czf "$DEST/$name-$STAMP.tar.gz" "$d" 2>/dev/null && \
      echo "    ✅ $DEST/$name-$STAMP.tar.gz"
  else
    echo "    ⚠️  跳过不存在的路径：$d"
  fi
done

echo
echo ">>> 备份现有数据库（如有 MySQL，强烈建议）："
if command -v mysqldump >/dev/null; then
  echo "    $SUDO mysqldump -u root -p --all-databases --single-transaction > $DEST/mysql-all-$STAMP.sql"
  echo "    （上面这条按需手动执行，需输入 root 密码）"
fi

echo
echo ">>> 完成。备份都在 $DEST/"
echo "    若是云服务器，再打一个整机快照最稳妥。确认有备份后再开始迁移。"
