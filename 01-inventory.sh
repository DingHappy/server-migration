#!/usr/bin/env bash
# 01-inventory.sh —— 在【源机】运行，只读盘点。
# 生成：inventory-report.md（给人看）、inventory-ports.txt（给 02 用）、apps/_skeleton-*.conf（清单骨架）
set -euo pipefail

cd "$(dirname "$0")"
REPORT="inventory-report.md"
PORTS_FILE="inventory-ports.txt"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo ">>> 正在盘点源机（只读，不改任何东西）..."

{
  echo "# 源机盘点报告"
  echo
  echo "- 主机名：\`$(hostname)\`"
  echo "- 系统：\`$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -a)\`"
  echo "- 架构：\`$(uname -m)\`"
  echo "- 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo

  echo "## 1. 正在运行的服务"
  echo '```'
  systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' || true
  echo '```'
  echo

  echo "## 2. 监听端口（冲突重点）"
  echo '```'
  $SUDO ss -tlnp 2>/dev/null || $SUDO netstat -tlnp 2>/dev/null || true
  echo '```'
  echo

  echo "## 3. 开机自启服务"
  echo '```'
  systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' || true
  echo '```'
  echo

  echo "## 4. 定时任务"
  echo '```'
  echo "# crontab (root):"; $SUDO crontab -l 2>/dev/null || echo "(无)"
  echo; echo "# /etc/cron.d/:"; $SUDO ls -1 /etc/cron.d/ 2>/dev/null || echo "(无)"
  echo '```'
  echo

  echo "## 5. nginx 站点配置（如有）"
  echo '```'
  $SUDO ls -1 /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null || echo "(无 nginx)"
  echo '```'
  echo

  echo "## 6. 数据库实例（如有）"
  echo '```'
  command -v mysql >/dev/null && { echo "MySQL 库列表:"; $SUDO mysql -e "SHOW DATABASES;" 2>/dev/null || echo "  (需手动连)"; }
  command -v psql  >/dev/null && { echo "Postgres 库列表:"; $SUDO -u postgres psql -l 2>/dev/null | awk 'NR>3{print $1}' || echo "  (需手动连)"; }
  echo '```'
} > "$REPORT"

# 给 02-check-conflicts 用：只提取监听的端口号
$SUDO ss -tlnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' \
  | grep -E '^[0-9]+$' | sort -un > "$PORTS_FILE" || true

echo ">>> 完成。"
echo "    - 盘点报告：$REPORT"
echo "    - 端口清单：$PORTS_FILE （拷到目标机给 02-check-conflicts.sh 用）"
echo
echo ">>> 下一步：阅读 $REPORT，为每个要迁的应用 cp apps/example-app.conf apps/<应用名>.conf 并填写。"
