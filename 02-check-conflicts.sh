#!/usr/bin/env bash
# 02-check-conflicts.sh —— 在【目标机】运行，只读。
# 用法：./02-check-conflicts.sh <源机的 inventory-ports.txt 路径>
# 对照源机端口，列出与目标机现有应用的端口冲突。
set -euo pipefail

SRC_PORTS="${1:-}"
if [ -z "$SRC_PORTS" ] || [ ! -f "$SRC_PORTS" ]; then
  echo "用法：$0 <源机生成的 inventory-ports.txt>"
  echo "（先在源机跑 01-inventory.sh，再把 inventory-ports.txt scp 到本机）"
  exit 1
fi
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo ">>> 目标机当前监听的端口："
$SUDO ss -tlnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' \
  | grep -E '^[0-9]+$' | sort -un > /tmp/dst-ports.txt
cat /tmp/dst-ports.txt | tr '\n' ' '; echo

echo
echo ">>> 端口冲突（源机和目标机都在用 —— 必须处理！）："
CONFLICT=$(comm -12 <(sort -u "$SRC_PORTS") /tmp/dst-ports.txt || true)
if [ -z "$CONFLICT" ]; then
  echo "    ✅ 无端口冲突"
else
  for p in $CONFLICT; do
    echo "    ⚠️  端口 $p 冲突 —— 目标机占用方："
    $SUDO ss -tlnp 2>/dev/null | grep ":$p " | sed 's/^/        /' || true
  done
  echo
  echo "    处理建议：改源应用端口，或用反向代理按域名分流（推荐后者）。"
fi

echo
echo ">>> 目标机正在运行的服务（核对是否有同名服务）："
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print "    "$1}'

echo
echo ">>> 提示：再人工核对——"
echo "    - 同名配置目录（如两边都用 /etc/nginx）：只合并 server 块，不覆盖主配置"
echo "    - 同款数据库：往现有实例新建库导入，别碰它现有的库"
echo "    - 应用运行用户：用 'id <用户名>' 确认目标机存在同名用户/UID"
