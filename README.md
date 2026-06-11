# 服务器迁移工具箱（裸机 → 已有应用的目标机）

把一台**裸机部署**服务器上的应用/配置/数据，安全搬到另一台**已经有应用在跑**的服务器。
配套文档：知识库 `docs/tech/devops/server-migration-to-shared-host.md`。

## 设计原则（为什么不是一键全自动）

裸机迁移必须**显式声明搬什么**，脚本绝不瞎猜，否则会搞坏目标机现有应用。所以：

- **配置驱动**：你在 `apps/*.conf` 里逐个声明每个应用的目录/数据库/端口。
- **默认 dry-run**：所有会改动的脚本默认只打印命令、不执行；确认无误后加 `--apply` 才真动手。
- **动手前先备份目标机**：`03-backup-target.sh` 给目标机 `/etc` 和现有应用打包。
- **绝不动源机数据**：脚本只读源机、只写目标机；源机是你的回滚点。

## 运行位置 & 前提

- `01-inventory.sh` → 在**源机**跑（只读盘点）
- `02-check-conflicts.sh` → 在**目标机**跑（只读查冲突）
- `03-backup-target.sh` → 在**目标机**跑（备份现有应用）
- `migrate.sh` → 在**源机**跑（通过 SSH 把数据推到目标机）

前提：源机能**免密 SSH** 到目标机（`ssh-copy-id` 配好密钥）。两台机器发行版/版本/架构一致。

## 使用顺序

```bash
# 0. 配好密钥：源机 → 目标机 免密
ssh-copy-id -p 22 root@目标机IP

# 1. 源机：自动盘点，生成报告 + 应用清单骨架
./01-inventory.sh
#    → 生成 inventory-report.md、inventory-ports.txt，并在 apps/ 下生成 *.conf 骨架

# 2. 编辑配置
cp migration.conf.example migration.conf   # 填目标机地址等
vim migration.conf
#    逐个核对/补全 apps/*.conf（删掉不迁的，补全数据库/数据目录）

# 3. 把源机的 inventory-ports.txt 拷到目标机，在目标机查冲突
scp inventory-ports.txt root@目标机:/tmp/
#    （目标机上）./02-check-conflicts.sh /tmp/inventory-ports.txt

# 4. 目标机：动手前先备份现有应用 + /etc
./03-backup-target.sh /opt/现有应用 /var/lib/现有应用数据

# 5. 源机：预览迁移（dry-run，只打印不执行）
./migrate.sh prepare
#    看清楚每条命令没问题后，真正执行：
./migrate.sh prepare --apply

# 6. 切换窗口：停源应用 → 增量同步 → 目标机启动（逐个应用）
./migrate.sh cutover 应用名 --apply

# 7. 切流量：改 DNS / 反向代理指向目标机，按文档第 4 步验证清单核对
```

## 各脚本说明

| 脚本 | 跑在 | 作用 | 是否会改动 |
| --- | --- | --- | --- |
| `01-inventory.sh` | 源机 | 盘点服务/端口/cron/nginx，生成报告和 `apps/*.conf` 骨架 | 只读 |
| `02-check-conflicts.sh` | 目标机 | 对照源机端口，列出端口/服务/用户冲突 | 只读 |
| `03-backup-target.sh` | 目标机 | 给 `/etc` 和指定目录打 tar 备份 | 只写备份 |
| `migrate.sh prepare` | 源机 | 全量同步文件 + 导入数据库（业务可继续跑） | dry-run，默认不改 |
| `migrate.sh cutover` | 源机 | 停源应用→增量同步→目标机启用 service | dry-run，默认不改 |

## 重要提醒

- 任何带 `--apply` 的执行前，**先不带 `--apply` 跑一遍看清单**。
- `migrate.sh` 的 rsync **默认不带 `--delete`**，不会删目标机文件，适合共享主机。
- 数据库走 **dump → import 到目标机现有实例的新库**，不拷 data 目录。
- 源机在目标机稳定运行**几天**前不要关机、不要删数据。
