#!/usr/bin/env bash
# migrate.sh —— 在【源机】运行，通过 SSH 把应用推到目标机。
#
# 用法：
#   ./migrate.sh prepare              预览全量同步+导库（dry-run，只打印）
#   ./migrate.sh prepare --apply      真正执行全量同步（业务可继续跑）
#   ./migrate.sh prepare 应用名 --apply   只处理某个应用
#   ./migrate.sh cutover 应用名 --apply   切换：停源应用→增量同步→目标机启用 service
#
# 默认 dry-run：不加 --apply 时所有命令只打印不执行。
set -euo pipefail
cd "$(dirname "$0")"

# ---- 加载全局配置 ----
[ -f migration.conf ] || { echo "缺少 migration.conf，请先 cp migration.conf.example migration.conf 并填写"; exit 1; }
# shellcheck disable=SC1091
source migration.conf

# ---- 解析参数 ----
PHASE="${1:-}"; shift || true
APPLY=0; APP_FILTER=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -*) echo "未知选项：$a"; exit 1 ;;
    *) APP_FILTER="$a" ;;
  esac
done
[ "$PHASE" = prepare ] || [ "$PHASE" = cutover ] || {
  echo "用法：$0 {prepare|cutover} [应用名] [--apply]"; exit 1; }

SSH="ssh -p ${TARGET_SSH_PORT:-22} ${TARGET_HOST}"
RSH="ssh -p ${TARGET_SSH_PORT:-22}"
mkdir -p "${WORK_DIR:-/tmp/migration}"

if [ "$APPLY" = 1 ]; then
  echo "########## 模式：真正执行（--apply） ##########"
else
  echo "########## 模式：dry-run 预览（命令只打印不执行；加 --apply 才执行） ##########"
fi
echo "目标机：$TARGET_HOST"; echo

# ---- 执行包装：dry-run 只打印，--apply 才真跑 ----
run()   { printf '    $ %s\n' "$*"; [ "$APPLY" = 1 ] && "$@"; return 0; }
runsh() { printf '    $ %s\n' "$1"; [ "$APPLY" = 1 ] && bash -c "$1"; return 0; }

# ---- 同步一组目录（rsync，不带 --delete，不会删目标机文件）----
sync_dirs() {
  local label="$1"; shift
  for d in "$@"; do
    [ -z "$d" ] && continue
    if [ ! -e "$d" ]; then echo "    ⚠️  源机不存在，跳过 $label：$d"; continue; fi
    run rsync -az -e "$RSH" "$d/" "${TARGET_HOST}:$d/"
  done
}

# ---- 拷贝单个文件到目标机同路径 ----
copy_file() {
  for f in "$@"; do
    [ -z "$f" ] && continue
    if [ ! -e "$f" ]; then echo "    ⚠️  源机不存在，跳过：$f"; continue; fi
    run rsync -az -e "$RSH" "$f" "${TARGET_HOST}:$f"
  done
}

# ---- MySQL：源机 dump 通过管道直接导入目标机现有实例的新库 ----
migrate_mysql() {
  for db in "$@"; do
    [ -z "$db" ] && continue
    echo "    -- MySQL 库：$db （目标机新建库后导入，不碰其现有库）"
    runsh "$SSH \"mysql ${DST_MYSQL_OPTS} -e 'CREATE DATABASE IF NOT EXISTS \\\`$db\\\` CHARACTER SET utf8mb4'\""
    runsh "mysqldump ${SRC_MYSQL_OPTS} --single-transaction --routines --triggers '$db' | $SSH \"mysql ${DST_MYSQL_OPTS} '$db'\""
  done
}

# ---- Postgres：dump 文件后导入 ----
migrate_pg() {
  for db in "$@"; do
    [ -z "$db" ] && continue
    echo "    -- Postgres 库：$db"
    local dump="${WORK_DIR}/${db}.dump"
    run pg_dump -Fc "$db" -f "$dump"
    run rsync -az -e "$RSH" "$dump" "${TARGET_HOST}:${dump}"
    runsh "$SSH \"sudo -u ${PG_SUPERUSER:-postgres} createdb '$db' 2>/dev/null; sudo -u ${PG_SUPERUSER:-postgres} pg_restore -d '$db' '${dump}'\""
  done
}

# ---- 在目标机启用 systemd 服务 ----
enable_units() {
  for u in "$@"; do
    [ -z "$u" ] && continue
    local path="/etc/systemd/system/$u"
    [ -e "$path" ] || path="/lib/systemd/system/$u"
    if [ ! -e "$path" ]; then echo "    ⚠️  源机找不到 unit：$u"; continue; fi
    run rsync -az -e "$RSH" "$path" "${TARGET_HOST}:/etc/systemd/system/$u"
    runsh "$SSH 'systemctl daemon-reload && systemctl enable --now $u && systemctl --no-pager status $u | head -5'"
  done
}

# ===================== 主流程 =====================
shopt -s nullglob
CONFS=(apps/*.conf)
[ ${#CONFS[@]} -eq 0 ] && { echo "apps/ 下没有应用配置。先 cp apps/example-app.conf apps/<应用>.conf"; exit 1; }

for conf in "${CONFS[@]}"; do
  appname=$(basename "$conf" .conf)
  [ "$appname" = "example-app" ] && continue
  [ -n "$APP_FILTER" ] && [ "$appname" != "$APP_FILTER" ] && continue

  # 清空上一轮变量后再加载
  BIN_DIRS=""; CONF_DIRS=""; DATA_DIRS=""; UNIT_FILES=""; CRON_FILES=""; ENV_FILES=""; MYSQL_DBS=""; PG_DBS=""; PORTS=""
  # shellcheck disable=SC1090
  source "$conf"

  echo "==================================================================="
  echo "应用：$appname   （端口 ${PORTS:-?}）"
  echo "==================================================================="

  if [ "$PHASE" = prepare ]; then
    echo "[1/5] 程序本体"; sync_dirs "本体" $BIN_DIRS
    echo "[2/5] 配置";     sync_dirs "配置" $CONF_DIRS; copy_file $ENV_FILES $CRON_FILES
    echo "[3/5] 数据目录"; sync_dirs "数据" $DATA_DIRS
    echo "[4/5] MySQL";    migrate_mysql $MYSQL_DBS
    echo "[5/5] Postgres"; migrate_pg $PG_DBS
    echo "    ✓ $appname 全量同步完成（数据库/上传文件之后 cutover 时会再增量补一次）"

  elif [ "$PHASE" = cutover ]; then
    [ -z "$APP_FILTER" ] && { echo "cutover 必须指定应用名：$0 cutover $appname --apply"; exit 1; }
    if [ "$APPLY" = 1 ]; then
      read -r -p "    ⚠️  即将【停止源机 $appname】并切换，确认？(yes/no) " ok
      [ "$ok" = yes ] || { echo "已取消"; exit 1; }
    fi
    echo "[1/4] 停止源机服务（数据不再变化）"
    for u in $UNIT_FILES; do run sudo systemctl stop "$u"; done
    echo "[2/4] 增量同步数据目录 + 配置"
    sync_dirs "数据" $DATA_DIRS; sync_dirs "配置" $CONF_DIRS; copy_file $ENV_FILES $CRON_FILES
    echo "[3/4] 重新导一次最新数据库（覆盖前面的全量，保证最新）"
    migrate_mysql $MYSQL_DBS; migrate_pg $PG_DBS
    echo "[4/4] 在目标机启用服务"
    enable_units $UNIT_FILES
    echo "    ✓ $appname 切换完成。接下来改 DNS/反代指向目标机，并按验证清单核对。"
  fi
  echo
done

echo "全部处理完毕。"
[ "$APPLY" = 0 ] && echo "（这是 dry-run 预览。确认无误后加 --apply 重新执行。）"
