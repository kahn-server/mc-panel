# KT-Anar Minecraft 管理面板 (mcpanel)

KT-Anar 服务器的一体化网页管理面板：实时监控、RCON 控制台、恢复模式、插件管理、赛博面板画面嵌入。

**[English](README.md) | 简体中文**

## 功能特性

- **实时监控**
  - 玩家在线/最大人数：原生 `minecraft:list` 命令（失败自动回退 `list`），宽松正则兼容中英文输出（`X of a max of Y` / `X/Y` / `当前有 X 位玩家在线…`）
  - TPS：Paper 原生 `tps` 命令（不依赖 Essentials 等插件）
  - JVM 堆内存：原生 `/gc` 输出解析（最大 / 已分配 / 空闲）
  - 服务器运行时长：读取 java 进程 `/proc/<pid>/stat` 的 starttime（纯系统级，不依赖任何命令/插件），日志 `Done (` 行作回退
  - 系统 CPU / 内存 / 磁盘
- **RCON 控制台**：网页直接执行任意命令
  - 纯 socket 手搓客户端（内嵌 `RCONClient`），无第三方二进制、无 `signal.alarm` 子线程坑
- **服务器控制**
  - 启动 / 停止 / **⚡ 快速重启** / 状态刷新
  - 快速重启：systemd 直接执行 `systemctl restart`（单事务，**不拆 stop+start**）；screen/tmux 无 restart 命令，合成"停止→等世界保存→启动"
  - 服务端核心升级后：上传新 jar 替换完成，确认框直接走快速重启（同样 `systemctl restart`）
- **恢复模式**：socket 心跳校验，无效连接所有字段返回 `Error`；3 秒实时推送
- **插件目录管理**：浏览 / 上传 / 删除插件（路径越界防护 + 文件魔数校验）
- **备份管理**：列表只显示常见压缩格式（`.zip` / `.gz` / `.tar` / `.tar.gz` / `.tgz` / `.7z` / `.rar` / `.bz2` / `.xz` / `.zst`），其余文件不显示；支持下载备份。**备份目录自动创建**：未设置 `MC_BACKUP_ROOT` 时自动建 `${MC_DIR}/backups`，并在其中自动建 `plugins_bak` / `server_jar_bak` 两个子目录（插件删除备份、服务端核心替换备份）
- **服务端核心管理**：自动识别 MC 目录中任意命名的服务端 jar（`server.jar` / `paper-*.jar` / `spigot.jar` 等），支持上传替换（旧核心自动备份）
- **多启动方式兼容（systemd / screen / tmux）**
  - **检测逻辑全部在安装脚本（preinstall.sh）**：安装时自动检测 MC 管理方式（systemd 服务单元 → screen 会话 → tmux 会话），经用户确认后写入环境变量 `MC_LAUNCH_TYPE` / `MC_SERVICE_NAME`
  - **面板不再执行任何探测命令**（无 `screen -ls` / `tmux ls` / `systemctl list-unit-files` 扫描），直接从环境变量读取
  - screen/tmux 的启动命令由安装脚本询问（`MC_LAUNCH_CMD`，默认沿用 MC_DIR 下的 `start.sh` 或第一个 jar）
- **赛博面板嵌入**：网页内实时查看赛博仪表盘画面（`/vnc-proxy` WebSocket 代理 → 本地 websockify :6080，websockify 由 `dashboard.sh` 脚本管理）
- **审计日志**：记录真实客户端 IP（PROXY protocol 透传）、登录与命令操作
- **HTTPS**：自签名证书（gunicorn 直接 TLS 终止）

## 技术栈

| 组件 | 版本 | 说明 |
|---|---|---|
| Flask | 3.0.3 | Web 框架 |
| Flask-SocketIO | 5.6.1 | 实时推送（async_mode=eventlet） |
| Flask-Limiter | 3.8.0 | 登录限流 |
| gunicorn | 23.0.0 | 生产服务器（eventlet worker，`proxy_protocol=True`） |
| eventlet | 0.39.1 | 协程 worker |
| websockify | 0.13.0 | VNC → WebSocket（赛博面板嵌入） |
| systemd | - | 服务托管 + 环境变量注入（主单元） |

## 架构

```
客户端浏览器 (HTTPS)
      │  <VPS公网IP>:8080 (frp) → 127.0.0.1:8080
      ▼
┌─────────────────────────────┐
│  gunicorn (eventlet)        │
│  ┌───────────────────────┐  │
│  │ app.py (Flask + SIO)  │  │
│  │  RCONClient(纯socket) │──┼──► MC 服务器 RCON 127.0.0.1:25575
│  │  控制: systemctl/screen/tmux │──┼──► MC 进程（按 MC_LAUNCH_TYPE 路由）
│  └───────────────────────┘  │
│  websockify :6080 ──────────┼──► x11vnc :5900 ◄── 赛博面板(Xvfb+dashboard.py)
└─────────────────────────────┘
```

## 目录结构

```
mc-panel/
├── app.py              # 面板主程序（英文版，供海外用户）
├── app_cn.py           # 面板主程序（中文版，国内用户请使用这个）
├── preinstall.sh       # 一键部署脚本（英文版，部署后 ExecStart 指向 app.py）
├── preinstall_cn.sh    # 一键部署脚本（中文版，部署后 ExecStart 指向 app_cn.py）
├── requirements.txt    # Python 依赖
├── gunicorn_config.py  # gunicorn 配置（proxy_protocol / cert）
├── README.md           # 英文版文档
├── README_cn.md        # 本文档（中文）
├── certs/              # HTTPS 证书 (cert.pem / key.pem，部署时生成)
├── data/               # 面板数据
├── static/avatars/     # 玩家头像缓存
├── users.json          # 面板登录用户（哈希存储，部署时生成）
└── websockify.log      # websockify 日志（运行时生成）
```

> ⚠️ **中文用户请使用 `app_cn.py` + `preinstall_cn.sh`**：中文部署脚本会自动创建指向 `app_cn.py` 的 systemd 单元（ExecStart 使用 `app_cn:app`），界面与提示均为中文；英文版仅供海外用户。

## 环境要求

- Ubuntu / Debian（基于 apt）
- Python 3.8+
- 运行用户（生产为 `mcserver`），依赖以 `--user` 安装
- MC 服务器开启 RCON（`server.properties`：`enable-rcon=true`，端口 25575）

## 快速部署

### 一键脚本（中文版）

```bash
cd mc-panel
sudo bash preinstall_cn.sh              # 部署到当前用户（中文交互，ExecStart 指向 app_cn.py）
sudo bash preinstall_cn.sh mcserver     # 指定运行用户
MCRCON_PASS=你的密码 sudo bash preinstall_cn.sh   # 预置 RCON 密码（否则交互输入）
MC_LAUNCH_TYPE=systemd MC_SERVICE_NAME=mc sudo bash preinstall_cn.sh  # 跳过交互，直接指定
```

> 海外用户请使用 `preinstall.sh`（英文版，对应 `app.py`），见 [README.md](README.md)。

脚本自动完成：系统依赖 → Python 依赖（`--user`）→ 目录结构 → HTTPS 自签证书 → **交互询问 frp 反向代理（不用 / PROXY v1 / PROXY v2）** → **询问单独备份目录（可留空）** → 生成 `SECRET_KEY` → **MC 管理方式自动检测 + 用户确认** → 环境变量合并写入 `mcpanel.service` 主单元 → **按 frp 模式生成 gunicorn 配置** → 配置运行用户 sudo 免密（`/etc/sudoers.d/mcpanel-<用户>`）→ 写 `mcpanel.service` → 启动服务。

**MC 管理方式交互流程**：
1. 脚本自动检测：systemd 服务单元（`minecraft`/`paper`/`spigot`/`purpur`/`bukkit`/`mc`）→ screen 会话 → tmux 会话
2. 显示检测结果 `[systemd] 名称: [minecraft]`，询问"确认使用这个结果吗？(Y/n)"
3. 选 `n` 则手动填写：**管理类型（systemd/screen/tmux）** + **服务名/会话名**
4. screen/tmux 类型额外询问**启动命令**（留空自动使用 MC_DIR 下的 `start.sh` 或第一个 jar）

> frp V2 穿透说明：gunicorn 只解析 PROXY v1 文本头。若启用 V2，脚本会生成仅监听 `127.0.0.1:8080` 的 gunicorn 配置，并提示在 frp 与面板之间加 mmproxy（监听 8081 把 V2 转 v1）。**注意：mmproxy 不会随 frp 自动安装**——需自行下载客户端 mmproxy，并提前手动配置好（systemd 开机自启、监听 127.0.0.1:8081、路由/转发规则）。部署方式与默认不同，请先确认 mmproxy 已就绪再启用 V2。

### 手动部署（参考）

```bash
# 依赖
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip python3-dev build-essential libssl-dev libffi-dev xvfb x11vnc
sudo -H -u mcserver python3 -m pip install --user -r requirements.txt

# 证书（没有则生成）
cd certs && openssl req -x509 -newkey rsa:4096 -nodes -out cert.pem -keyout key.pem -days 365 -subj '/CN=kt-anar-panel'

# 环境变量：直接写进 mcpanel.service 主单元 [Service] 段
sudo tee /etc/systemd/system/mcpanel.service >/dev/null <<'EOF'
[Unit]
Description=KT-Anar Minecraft Management Panel
After=network.target

[Service]
User=mcserver
Group=mcserver
WorkingDirectory=/home/mcserver/.mc_panel
Environment="SECRET_KEY=<新生成的密钥>"
Environment="MCRCON_PASS=<RCON密码>"
Environment="MC_DIR=/data/minecraft_server"
Environment="MC_LAUNCH_TYPE=systemd"
Environment="MC_SERVICE_NAME=minecraft"
ExecStart=/home/mcserver/.local/bin/gunicorn -c gunicorn_config.py app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable --now mcpanel.service
```

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `SECRET_KEY` | ✅ | Flask 会话签名密钥（64 位 hex）。**更换后所有已登录 Cookie 失效，需重新登录一次** |
| `MCRCON_PASS` | ✅ | MC 服务器 RCON 密码。缺失时面板拒绝启动（`RuntimeError`） |
| `MC_DIR` | 可选 | MC 服务端目录，默认 `/data/minecraft_server` |
| `MC_BACKUP_ROOT` | 可选 | 备份根目录，默认 `${MC_DIR}/backups` |
| `MC_LOG_DIR` | 可选 | 面板自身日志目录，默认 `/data/mc_panel_logs` |
| `MC_SERVICE_NAME` | 可选 | MC 的 systemd 服务名 / screen / tmux 会话名（**由 preinstall.sh 检测确认后注入**，默认 `minecraft`） |
| `MC_LAUNCH_TYPE` | ✅ | MC 管理方式：`systemd` / `screen` / `tmux`。**由 preinstall.sh 检测确认后注入；面板不再自行探测**。未设置时面板无法判断启动方式 |
| `MC_LAUNCH_CMD` | 可选 | screen/tmux 类型的启动命令（如 `bash start.sh`）。留空自动用 MC_DIR 下 `start.sh` 或第一个 jar |

`SECRET_KEY` / `MCRCON_PASS` 及全部 MC 配置均由 **mcpanel.service 主单元 `[Service]` 段的 `Environment=` 注入**（preinstall.sh 直接写入主单元），代码中**不存在任何明文密钥与硬编码路径**。改路径只需改主单元后 `daemon-reload` + 重启。

## 服务管理

```bash
systemctl status mcpanel.service       # 状态
journalctl -u mcpanel.service -f       # 实时日志
journalctl -u mcpanel.service -n 50    # 最近 50 行
systemctl restart mcpanel.service      # 重启
sudo systemctl show mcpanel.service | grep -i environment   # 确认环境变量
```

## frp 反向代理

**先判断你的情况**：

- **服务器有公网 IP，或不需要审计日志（真实客户端 IP）** → frp / mmproxy 都不需要：安装时 frp 选项直接选 **none**，面板端口直连即可。
- **需要 frp 转发，但不需要真实客户端 IP** → 方式 A 直连。
- **需要 frp 转发 + 审计真实客户端 IP** → 方式 B（mmproxy + PROXY v2）。

**方式 A：直连（无代理）**：

```toml
[[proxies]]
name = "mc_panel"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080     # 面板 gunicorn 监听端口
remotePort = 8080    # 公网端口，按你的 frps 配置填写
```

**方式 B：PROXY v2（透传真实客户端 IP 到审计日志）**：

```toml
[[proxies]]
name = "mc_panel"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8081     # 本机 mmproxy 监听端口
remotePort = 8080    # 公网端口，按你的 frps 配置填写
```

> mmproxy 配置示例：mmproxy 监听 `127.0.0.1:8081`，把收到的 PROXY v2 转成 v1 后连接到面板 `127.0.0.1:8080`。mmproxy **不随 frp 自动安装**，需要自行下载源码编译并配置（systemd 开机自启、监听/转发规则等），详细编译与配置教程请自行搜索（关键词：mmproxy）。

公网访问：`https://<你的VPS公网IP>:8080`。

## 赛博面板联动

赛博仪表盘（独立项目：**[Cyberpunk MC Dashboard](https://github.com/kahn-server/cyber-mc-dashboard)**）由 `dashboard.sh` 脚本管理（`start`/`stop`），运行链：`Xvfb → dashboard.py → x11vnc:5900 → websockify:6080`（CPU 亲和由脚本按核心数自动分配，可用 `DASH_CPU_AFFINITY` 覆盖）。mcpanel 内置 WebSocket 代理（`/vnc-proxy` → 127.0.0.1:6080）在网页内展示画面。赛博面板源码、安装说明与配置模板见其仓库。

## 界面入口（面板底部两个隐藏触发器）

面板底部 footer 有**两个伪装成普通文字的隐藏触发器**，各自**连点 12 次**（间隔超时自动重置）后弹出**超级密码验证框**，验证通过后进入对应界面：

- **“实时状态每10秒自动更新”**（footer 左侧文字）→ 连点 12 次 + 超级密码 → **VNC 远程桌面**（独立功能界面，路由 `/recovery/vnc`，不属于恢复模式）：网页内嵌 noVNC 客户端，实时查看赛博仪表盘画面（链路：`dashboard.sh start` 拉起 Xvfb → dashboard.py → x11vnc:5900 → websockify:6080 → 面板 `/vnc-proxy`）。**这是赛博面板联动的主入口。必须先开启赛博面板**——使用 [Cyberpunk MC Dashboard](https://github.com/kahn-server/cyber-mc-dashboard) 项目中的 `dashboard.sh start`；VNC 打开后若 **10 秒无画面会自动跳回恢复模式**（VNC 必须处于开启状态）。
- **“头像裁剪”**（footer 右侧文字）→ 连点 12 次 + 超级密码 → **恢复模式**（路由 `/recovery`），内含隐藏功能：
  - **Shell 终端**：网页内 xterm，直接在主机上执行命令
  - **世界回档**：从备份恢复世界存档
  - **插件管理**：浏览 / 上传 / 删除插件
  - **服务器图标**：预览 / 上传 / 下载 server-icon
  - **MOTD**：查看 / 修改服务器 motd
  - **重启主机**：远程重启整机（需 sudo 免密配置）

> footer 上这两个文案是**伪装触发器**，并非字面功能：真正的手动刷新/头像裁剪不在这里（头像裁剪位于个人资料弹窗内）。

## 安全说明

- 密钥零硬编码：`SECRET_KEY` / `MCRCON_PASS` 仅存在于 mcpanel.service 主单元（root 可读）
- 登录限流：Flask-Limiter + 超级密码 IP 限流（24h 窗口 5 次失败锁定）
- 插件上传：路径越界防护 + 文件魔数校验
- 会话 Cookie：`SECRET_KEY` 签名，更换密钥即全员下线
- 建议定期轮换 `SECRET_KEY`（换一次，所有人重新登录）

## 故障排查

| 症状 | 排查 |
|---|---|
| 服务起不来，报 `环境变量 MCRCON_PASS 未设置` | mcpanel.service 主单元 Environment 没写对或没 `daemon-reload` |
| 服务起不来，报 `环境变量 SECRET_KEY 未设置` | 同上 |
| 面板显示服务器未运行 / "未检测到 MC 启动方式" | `MC_LAUNCH_TYPE` 未设置或与实际情况不符。查看：`systemctl show mcpanel.service \| grep MC_LAUNCH`；与实际不符时改主单元环境变量后重启，或重跑 `preinstall.sh` 重新检测确认 |
| screen/tmux 启动方式但起不来 | 确认 `MC_SERVICE_NAME` 是实际会话名、`MC_LAUNCH_CMD` 正确（默认 `start.sh` 或第一个 jar）；会话是其他用户启动的面板可能无权限操作 |
| 玩家数 / TPS 显示异常 | `minecraft:list` / `tps` 为原生命令，确认服务端是 Paper/Spigot 系 |
| 备份列表少了文件 | 只显示常见压缩格式（zip/gz/tar/7z 等），非压缩文件不会列出 |
| 网页看不到赛博面板 | `dashboard.sh start`，确认 x11vnc:5900 与 websockify:6080 均在监听 |
| 审计日志 IP 全是 127.0.0.1 | 确认 gunicorn_config.py 的 `proxy_protocol=True` 与 frp mmproxy 配置 |

## 变更记录

- **2026-09-23**：赛博面板联动改为独立脚本 `dashboard.sh` 管理（websockify 不再由面板自动拉起，移除死代码 `start_websockify`）；CPU 亲和改为按核心数自动计算（面板绑定末两位核心），支持 `PANEL_CPU_AFFINITY` / `DASH_CPU_AFFINITY` 环境变量覆盖
- **2026-09-22**：检测逻辑彻底移出面板——`detect_mc_launcher` 改为纯读 `MC_LAUNCH_TYPE` 环境变量（不再执行 systemctl/screen/tmux 任何探测）；preinstall.sh 新增管理方式自动检测（systemd→screen→tmux）+ 用户确认 + 手动填写（类型/服务名/screen·tmux 启动命令 `MC_LAUNCH_CMD`）；新增 **⚡ 快速重启**（systemd 直接 `systemctl restart`，不拆 stop/start）与服务端升级后直接重启；环境变量合并进 mcpanel.service 主单元
- **2026-09-21（四）**：服务名与备份目录兜底——`MC_SERVICE_NAME` 未设置时自动扫描 systemd 服务识别 MC 服务；preinstall.sh 自动检测服务名；备份目录未指定时脚本自动建默认备份目录及 `plugins_bak`/`server_jar_bak` 子目录
- **2026-09-21（三）**：通用化改造——备份列表只显示常见压缩格式；服务端 jar 任意命名识别（`find_server_jar`）；MC 启动方式自动检测（systemd/screen/tmux）；preinstall.sh 新增 frp 反向代理询问（none/v1/v2）与单独备份目录询问，gunicorn 配置按 frp 模式生成
- **2026-09-21（二）**：MC 目录配置化——`MC_DIR`/`MC_BACKUP_ROOT`/`MC_LOG_DIR` 改环境变量读取，preinstall.sh 自动注入并新增 sudo 免密配置段
- **2026-09-21（一）**：RCON 全面重构——移除 `mcrcon` 二进制，内嵌纯 socket `RCONClient`；玩家列表改原生 `minecraft:list`；TPS 改原生命令解析；运行时长改进程级 `/proc` starttime；`SECRET_KEY`/`MCRCON_PASS` 环境变量化
- **2026-09-19**：gunicorn + eventlet 生产化、真实 IP 透传、3 秒轮询、恢复模式 socket 校验、插件目录管理、赛博面板嵌入
