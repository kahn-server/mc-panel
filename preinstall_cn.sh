#!/bin/bash
# =====================================================================
# KT-Anar 管理面板 (mcpanel) 一键部署脚本
# 适用系统: Ubuntu / Debian (基于 apt)
#
# 用法:
#   sudo bash preinstall.sh                     # 部署到调用 sudo 的用户
#   sudo bash preinstall.sh mcserver            # 指定运行用户
#   MC_DIR=/path/to/mc sudo bash preinstall.sh  # 指定 MC 服务端目录（默认自动检测 + 交互确认）
#   MCRCON_PASS=xxx sudo bash preinstall.sh     # 指定 RCON 密码（否则交互输入）
#   MC_SERVICE_NAME=mc sudo bash preinstall.sh  # 指定 MC 服务名/screen/tmux 会话名（默认自动检测）
#   MC_LAUNCH_TYPE=systemd sudo bash preinstall.sh  # 指定管理方式 systemd/screen/tmux（默认自动检测）
#   PANEL_PROTO=http sudo bash preinstall.sh  # HTTP 模式（不安全，强烈建议 HTTPS；默认 https）
#   MC_LAUNCH_CMD='bash start.sh' sudo bash preinstall.sh  # screen/tmux 时的启动命令（默认自动）
#
# 部署内容:
#   1. 系统依赖 (python3/pip/编译工具/Xvfb/x11vnc)
#   2. Python 依赖 (requirements.txt, --user 安装到运行用户)
#   3. 目录结构与 HTTPS 自签证书
#   4. frp 反向代理询问（none / PROXY v1 / PROXY v2）
#   5. MC 服务端目录检测（自动检测 + 交互确认，可用 MC_DIR 预指定）
#   6. 备份目录询问（指定则建两个子目录；留空自动建默认备份目录+两个子目录）
#   7. MC 管理方式检测 + 环境变量注入 (SECRET_KEY/MCRCON_PASS/MC_DIR 等，合并进主单元)
#   8. sudo 免密 (systemctl MC / chattr / reboot)
#   9. systemd 服务 (mcpanel.service) + gunicorn 配置（按 frp 模式生成）
# =====================================================================

set -e

RUN_USER="${1:-$SUDO_USER}"
RUN_USER="${RUN_USER:-$(whoami)}"

# ---------- CPU 亲和（面板绑定末两位核心，MC 服务用前部核心） ----------
# 自动按机器核心数计算，可用 PANEL_CPU_AFFINITY 环境变量覆盖
CPU_AFFINITY="${PANEL_CPU_AFFINITY:-}"
if [ -z "$CPU_AFFINITY" ]; then
    NCORES_TOTAL="$(nproc 2>/dev/null || echo 1)"
    if [ "$NCORES_TOTAL" -ge 2 ]; then
        CPU_AFFINITY="$((NCORES_TOTAL-2)) $((NCORES_TOTAL-1))"
    else
        CPU_AFFINITY="0"
    fi
fi
echo "  [INFO] CPU 核心数: ${NCORES_TOTAL:-$(nproc)}，面板亲和: ${CPU_AFFINITY}（可用 PANEL_CPU_AFFINITY 覆盖）"

# ---------- MC 管理方式检测（systemd / screen / tmux） ----------
detect_mc_manage_type() {
    local svc sname tname
    svc="$(systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -iE '^(minecraft|paper|spigot|purpur|bukkit|mc)\.service$' | head -1 | sed 's/\.service//')"
    if [ -n "$svc" ]; then
        echo "systemd $svc"; return
    fi
    sname="$(screen -ls 2>/dev/null | grep -oE '[0-9]+\.[A-Za-z0-9_.-]+' | head -1 | sed 's/^[0-9]*\.//')"
    if [ -n "$sname" ]; then
        echo "screen $sname"; return
    fi
    tname="$(tmux ls 2>/dev/null | awk -F: '{print $1}' | head -1)"
    if [ -n "$tname" ]; then
        echo "tmux $tname"; return
    fi
    echo "none none"
}

# 自动检测 MC 管理方式，并经用户确认；选否则手动填写
MC_LAUNCH_TYPE="${MC_LAUNCH_TYPE:-}"
if [ -z "${MC_SERVICE_NAME:-}" ] || [ -z "$MC_LAUNCH_TYPE" ]; then
    DETECTED="$(detect_mc_manage_type)"
    DETECT_TYPE="${DETECTED%% *}"; DETECT_NAME="${DETECTED#* }"
    if [ "$DETECT_TYPE" = "none" ]; then
        echo "  未自动检测到 MC 管理方式，请手动填写："
        read -r -p "  管理类型 (systemd / screen / tmux，默认 systemd): " MC_LAUNCH_TYPE
        MC_LAUNCH_TYPE="${MC_LAUNCH_TYPE:-systemd}"
        read -r -p "  服务名 / screen 会话名 / tmux 会话名 (默认 minecraft): " MC_SERVICE_NAME
        MC_SERVICE_NAME="${MC_SERVICE_NAME:-minecraft}"
    else
        echo "  自动检测到 MC 管理方式: [${DETECT_TYPE}]  名称: [${DETECT_NAME}]"
        read -r -p "  确认使用这个结果吗？(Y/n): " CONFIRM_MC
        if [[ "$CONFIRM_MC" =~ ^[Nn]$ ]]; then
            echo "  请手动填写（将覆盖自动检测结果）："
            read -r -p "  管理类型 (systemd / screen / tmux，默认 ${DETECT_TYPE}): " MC_LAUNCH_TYPE
            MC_LAUNCH_TYPE="${MC_LAUNCH_TYPE:-$DETECT_TYPE}"
            read -r -p "  服务名 / 会话名 (默认 ${DETECT_NAME}): " MC_SERVICE_NAME
            MC_SERVICE_NAME="${MC_SERVICE_NAME:-$DETECT_NAME}"
        else
            MC_LAUNCH_TYPE="$DETECT_TYPE"; MC_SERVICE_NAME="$DETECT_NAME"
        fi
    fi
fi
# screen/tmux：启动命令（默认沿用 MC_DIR 下的 start.sh，否则自动用第一个 jar）
MC_LAUNCH_CMD="${MC_LAUNCH_CMD:-}"
if [ "$MC_LAUNCH_TYPE" != "systemd" ] && [ -z "$MC_LAUNCH_CMD" ]; then
    echo "  [${MC_LAUNCH_TYPE}] MC 启动命令（留空则自动使用 MC_DIR 下的 start.sh 或第一个 jar）:"
    read -r -p "  > " MC_LAUNCH_CMD
fi

if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 sudo 运行: sudo bash preinstall.sh [运行用户]"
  exit 1
fi
if ! id "$RUN_USER" >/dev/null 2>&1; then
  echo "错误: 用户 $RUN_USER 不存在，请先创建: useradd -m -s /bin/bash $RUN_USER"
  exit 1
fi

# ---------- MC 服务端目录检测（自动检测 + 交互确认，可用 MC_DIR 预指定） ----------
detect_mc_dir() {
    local pid dir rh
    # 优先：运行中的 MC java 进程工作目录（识别 paper/spigot/purpur/bukkit/fabric/forge 等）
    pid="$(pgrep -f '\.jar.*(nogui|server|spigot|paper|purpur|fabric|forge)' 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
        dir="$(readlink "/proc/${pid}/cwd" 2>/dev/null || echo '')"
        if [ -n "$dir" ] && [ -f "$dir/server.properties" ]; then
            echo "$dir"; return
        fi
    fi
    # 兜底：常见目录
    rh="$(sudo -H -u "$RUN_USER" python3 -c 'import os;print(os.path.expanduser("~"))' 2>/dev/null || echo '')"
    for c in /data/minecraft_server "$rh/minecraft_server" "$rh/mc" /opt/minecraft_server; do
        if [ -f "$c/server.properties" ]; then
            echo "$c"; return
        fi
    done
    echo ""
}
MC_DIR="${MC_DIR:-}"
if [ -z "$MC_DIR" ]; then
    DETECT_MC_DIR="$(detect_mc_dir)"
    if [ -z "$DETECT_MC_DIR" ]; then
        echo "  未自动检测到 MC 服务端目录，请手动填写："
        read -r -p "  MC 服务端目录（含 server.jar / server.properties）: " MC_DIR
        while [ -z "$MC_DIR" ]; do
            read -r -p "  MC 服务端目录不能为空，请重新输入: " MC_DIR
        done
    else
        echo "  自动检测到 MC 服务端目录: [$DETECT_MC_DIR]"
        read -r -p "  确认使用这个目录吗？(Y/n): " CONFIRM_MC_DIR
        if [[ "$CONFIRM_MC_DIR" =~ ^[Nn]$ ]]; then
            read -r -p "  请手动填写 MC 服务端目录: " MC_DIR
            while [ -z "$MC_DIR" ]; do
                read -r -p "  MC 服务端目录不能为空，请重新输入: " MC_DIR
            done
        else
            MC_DIR="$DETECT_MC_DIR"
        fi
    fi
fi
if [ ! -d "$MC_DIR" ]; then
    echo "  [警告] MC 目录 $MC_DIR 不存在（面板仍会安装，但插件/日志/备份相关功能需要该目录存在才能工作）"
fi

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_HOME="$(sudo -H -u "$RUN_USER" python3 -c 'import os; print(os.path.expanduser("~"))')"
GUNICORN_BIN="$RUN_HOME/.local/bin/gunicorn"

echo "============================================="
echo "  KT-Anar 管理面板 - 一键部署"
echo "  运行用户 : $RUN_USER"
echo "  面板目录 : $PANEL_DIR"
echo "  gunicorn : $GUNICORN_BIN"
echo "  MC 服务名: $MC_SERVICE_NAME (systemd/screen/tmux 会话名)"
echo "============================================="

# ---------- 1. 系统依赖 ----------
echo "[1/10] 更新软件源并安装系统依赖..."
apt-get update -y
apt-get install -y \
    python3 python3-pip python3-dev python3-venv \
    build-essential libssl-dev libffi-dev \
    xvfb x11vnc \
    curl wget git openssl

# ---------- 2. Python 依赖 ----------
echo "[2/10] 安装 Python 依赖..."
if [[ "$USE_VENV" =~ ^[Yy]$ ]]; then
    echo "  >> 正在创建虚拟环境：$PANEL_DIR/venv"
    sudo -H -u "$RUN_USER" python3 -m venv "$PANEL_DIR/venv"
    sudo -H -u "$RUN_USER" "$PANEL_DIR/venv/bin/pip" install --upgrade pip
    sudo -H -u "$RUN_USER" "$PANEL_DIR/venv/bin/pip" install -r "$PANEL_DIR/requirements.txt"
    GUNICORN_BIN="$PANEL_DIR/venv/bin/gunicorn"
else
    echo "  >> 使用 --user 安装（不使用虚拟环境）"
    sudo -H -u "$RUN_USER" python3 -m pip install --upgrade pip
    sudo -H -u "$RUN_USER" python3 -m pip install --user -r "$PANEL_DIR/requirements.txt"
    GUNICORN_BIN="$RUN_HOME/.local/bin/gunicorn"
fi
echo "  >> gunicorn：$GUNICORN_BIN"

# ---------- 3. 目录结构 ----------
echo "[3/10] 创建目录结构..."
mkdir -p "$PANEL_DIR/certs" "$PANEL_DIR/data" "$PANEL_DIR/static/avatars"
mkdir -p /data/mc_panel_logs
chown -R "$RUN_USER":"$RUN_USER" "$PANEL_DIR"

# ---------- 4. 面板访问协议（默认 HTTPS，可选 HTTP）----------
PANEL_PROTO="${PANEL_PROTO:-}"
if [ -z "$PANEL_PROTO" ]; then
    echo "[4/10] 面板访问协议？[https/http]（默认 https）："
    read -r PANEL_PROTO
    [ -z "$PANEL_PROTO" ] && PANEL_PROTO="https"
fi
case "$PANEL_PROTO" in
    http)
        echo "  >> 警告：HTTP 不加密，密码和流量以明文传输，强烈建议使用 HTTPS！"
        echo "     按你的选择继续使用 HTTP。"
        ;;
    *)
        PANEL_PROTO="https"
        echo "[4/10] 检查 HTTPS 证书..."
        if [ ! -f "$PANEL_DIR/certs/cert.pem" ] || [ ! -f "$PANEL_DIR/certs/key.pem" ]; then
            openssl req -x509 -newkey rsa:4096 -nodes \
                -out "$PANEL_DIR/certs/cert.pem" \
                -keyout "$PANEL_DIR/certs/key.pem" \
                -days 365 -subj "/CN=kt-anar-panel"
        fi
        chown -R "$RUN_USER":"$RUN_USER" "$PANEL_DIR/certs"
        ;;
esac

# ---------- 5. RCON 密码 ----------
echo "[5/10] 配置 RCON 密码 (MCRCON_PASS)..."
if [ -z "$MCRCON_PASS" ]; then
    read -r -s -p "请输入 MC 服务器 RCON 密码: " MCRCON_PASS
    echo
    if [ -z "$MCRCON_PASS" ]; then
        echo "错误: 未提供 RCON 密码。可改用: MCRCON_PASS=xxx sudo bash preinstall.sh"
        exit 1
    fi
fi

# ---------- 6. frp 反向代理询问 ----------
echo "[6/10] 询问 frp 反向代理配置..."
FRP_MODE="none"
read -r -p "是否使用 frp 反向代理面板？(y/N): " USE_FRP
if [[ "$USE_FRP" =~ ^[Yy]$ ]]; then
    read -r -p "frp 是否启用（或打算启用）PROXY protocol V2 IP 穿透？(y/N): " FRP_V2
    if [[ "$FRP_V2" =~ ^[Yy]$ ]]; then
        FRP_MODE="v2"
        echo "  >> 启用 V2 IP 穿透: 面板将监听 127.0.0.1:8080，需 mmproxy 前置转换（见下方说明）"
    else
        FRP_MODE="v1"
        echo "  >> frp 以 PROXY v1 文本头转发，面板监听 0.0.0.0:8080"
    fi
else
    echo "  >> 不使用 frp，面板直接监听 0.0.0.0:8080"
fi

# ---------- 7. 备份目录 + SECRET_KEY + 环境变量（合并进主单元） ----------
echo "[7/10] 配置备份目录，生成 SECRET_KEY 并准备环境变量（合并进主单元）..."
read -r -p "设置单独的备份目录（留空则使用默认 ${MC_DIR}/backups）: " BACKUP_ROOT_INPUT
if [ -n "$BACKUP_ROOT_INPUT" ]; then
    ENV_BACKUP_ROOT="Environment=\"MC_BACKUP_ROOT=${BACKUP_ROOT_INPUT}\""
    echo "  >> 备份目录: $BACKUP_ROOT_INPUT"
    mkdir -p "$BACKUP_ROOT_INPUT/plugins_bak" "$BACKUP_ROOT_INPUT/server_jar_bak"
    chown -R "$RUN_USER":"$RUN_USER" "$BACKUP_ROOT_INPUT"
    echo "  >> 已创建 plugins_bak / server_jar_bak 子目录"
else
    ENV_BACKUP_ROOT=""
    echo "  >> 未设置单独备份目录（将使用默认）。注意：没有备份目录时，备份/恢复相关功能可能无法使用"
    mkdir -p "$MC_DIR/backups/plugins_bak" "$MC_DIR/backups/server_jar_bak"
    chown -R "$RUN_USER":"$RUN_USER" "$MC_DIR/backups"
    echo "  >> 已自动创建默认备份目录 $MC_DIR/backups/{plugins_bak,server_jar_bak}"
fi
SECRET_KEY="$(sudo -H -u "$RUN_USER" python3 -c 'import secrets; print(secrets.token_hex(32))')"
mkdir -p /etc/systemd/system/mcpanel.service.d
ENV_LINES="Environment=\"SECRET_KEY=${SECRET_KEY}\""
ENV_LINES="${ENV_LINES}
Environment=\"MCRCON_PASS=${MCRCON_PASS}\""
ENV_LINES="${ENV_LINES}
Environment=\"MC_DIR=${MC_DIR}\""
ENV_LINES="${ENV_LINES}
Environment=\"MC_SERVICE_NAME=${MC_SERVICE_NAME}\""
ENV_LINES="${ENV_LINES}
Environment=\"MC_LAUNCH_TYPE=${MC_LAUNCH_TYPE}\""
[ -n "$ENV_BACKUP_ROOT" ] && ENV_LINES="${ENV_LINES}
${ENV_BACKUP_ROOT}"
ENV_LINES="${ENV_LINES}
Environment=\"MC_LOG_DIR=/data/mc_panel_logs\""
if [ -n "$MC_LAUNCH_CMD" ]; then
    ENV_LINES="${ENV_LINES}
Environment=\"MC_LAUNCH_CMD=${MC_LAUNCH_CMD}\""
fi
echo "  >> 环境变量将合并写入主单元 mcpanel.service（见第 9 步）"

# ---------- 8. gunicorn 配置（按 frp 模式）+ sudo 免密 ----------
echo "[8/10] 生成 gunicorn 配置（frp 模式: $FRP_MODE）..."
if [ -f "$PANEL_DIR/gunicorn_config.py" ]; then
    mv "$PANEL_DIR/gunicorn_config.py" "$PANEL_DIR/gunicorn_config.py.bak-$(date +%Y%m%d%H%M%S)"
fi
if [ "$FRP_MODE" = "v2" ]; then
    GUNI_BIND="127.0.0.1:8080"
else
    GUNI_BIND="0.0.0.0:8080"
fi
cat > "$PANEL_DIR/gunicorn_config.py" <<EOF
# KT-Anar mcpanel gunicorn 配置（由 preinstall.sh 按 frp 模式生成）
bind = "$GUNI_BIND"
workers = 1
worker_class = "eventlet"
accesslog = "-"
EOF
if [ "$PANEL_PROTO" = "https" ]; then
cat >> "$PANEL_DIR/gunicorn_config.py" <<EOF
certfile = "certs/cert.pem"
keyfile = "certs/key.pem"
EOF
fi
if [ "$FRP_MODE" != "none" ]; then
cat >> "$PANEL_DIR/gunicorn_config.py" <<EOF
# PROXY protocol（透传真实客户端 IP 到审计日志）
proxy_protocol = True
proxy_allow_ips = ["127.0.0.1"]
EOF
fi
chown "$RUN_USER":"$RUN_USER" "$PANEL_DIR/gunicorn_config.py"
echo "  >> 已生成 $PANEL_DIR/gunicorn_config.py (bind=$GUNI_BIND, proxy=$FRP_MODE)"

if [ "$FRP_MODE" = "v2" ]; then
    echo
    echo "  !! [V2 穿透] 部署方式与默认不同："
    echo "     gunicorn 仅支持 PROXY v1 文本头，V2 二进制头需要 mmproxy 前置转换。"
    echo "     1. 安装 mmproxy: github.com/cloudflare/mmproxy (make && cp mmproxy /usr/local/bin/)"
    echo "     2. mmproxy 监听 0.0.0.0:8081，转发到面板 127.0.0.1:8080："
    echo "        mmproxy -l 0.0.0.0:8081 -r 127.0.0.1:8080 -p 127.0.0.1:8080"
    echo "     3. frp 侧 frpc.toml 配置 transport.proxyProtocolVersion = \"v2\"，remotePort 指向 8081"
    echo "     4. 面板 systemd 单元不变（绑定 127.0.0.1:8080，由 mmproxy 喂入 PROXY 头）"
    echo
fi

echo "[8/10] 配置 sudo 免密..."
SUDOERS_FILE="/etc/sudoers.d/mcpanel-${RUN_USER}"
if [ "$MC_LAUNCH_TYPE" = "systemd" ]; then
    MC_SYSTEMCTL_LINE="${RUN_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start ${MC_SERVICE_NAME}, /usr/bin/systemctl stop ${MC_SERVICE_NAME}, /usr/bin/systemctl is-active ${MC_SERVICE_NAME}, /usr/bin/systemctl restart ${MC_SERVICE_NAME}"
else
    MC_SYSTEMCTL_LINE="# MC 由 ${MC_LAUNCH_TYPE} 管理，无需 systemctl 免密"
fi
cat > "$SUDOERS_FILE" <<EOF
# mcpanel 运行所需命令免密（由 preinstall.sh 自动生成）
${MC_SYSTEMCTL_LINE}
${RUN_USER} ALL=(root) NOPASSWD: /usr/bin/chattr, /usr/bin/lsattr
${RUN_USER} ALL=(root) NOPASSWD: /usr/sbin/reboot, /sbin/reboot
EOF
chmod 440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE" && echo "  sudoers 语法校验通过: $SUDOERS_FILE"

# ---------- 9. systemd 服务 ----------
echo "[9/10] 写入 systemd 服务 (mcpanel.service)..."
cat > /etc/systemd/system/mcpanel.service <<EOF
[Unit]
Description=KT-Anar Minecraft Management Panel
After=network.target

[Service]
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${PANEL_DIR}
${ENV_LINES}
ExecStart=${GUNICORN_BIN} -c gunicorn_config.py app_cn:app
Restart=always
RestartSec=5
# MC 服务占用前部核心，面板绑定末两位核心（按核心数自动计算，可用 PANEL_CPU_AFFINITY 覆盖）
CPUAffinity=${CPU_AFFINITY}

[Install]
WantedBy=multi-user.target
EOF

# ---------- 10. 启动服务 ----------
echo "[10/10] 启动服务..."
systemctl daemon-reload
systemctl enable mcpanel.service
systemctl restart mcpanel.service
sleep 3
systemctl status mcpanel.service --no-pager | head -10

PROTO_URL="https"
[ "$PANEL_PROTO" = "http" ] && PROTO_URL="http"

case "$FRP_MODE" in
    none) ACCESS_NOTE="$PROTO_URL://<服务器IP>:8080 直接访问" ;;
    v1)   ACCESS_NOTE="frp 映射 -> 面板 8080（PROXY v1，真实 IP 透传）" ;;
    v2)   ACCESS_NOTE="frp + mmproxy -> 面板 127.0.0.1:8080（PROXY v2）" ;;
esac

echo
echo "============================================="
echo " 部署完成!"
echo "  访问方式 : $ACCESS_NOTE"
echo "  查看日志 : journalctl -u mcpanel.service -f"
echo "  环境变量 : SECRET_KEY / MCRCON_PASS / MC_DIR / MC_LOG_DIR 已合并写入 mcpanel.service 主单元"
[ -n "$ENV_BACKUP_ROOT" ] && echo "  备份目录 : 已设置单独目录（见 drop-in 的 MC_BACKUP_ROOT）"
echo "  sudo 免密 : /etc/sudoers.d/mcpanel-${RUN_USER} (systemctl ${MC_SERVICE_NAME} / chattr / reboot)"
echo "  MC 管理   : ${MC_LAUNCH_TYPE} / ${MC_SERVICE_NAME}"
[ -n "$MC_LAUNCH_CMD" ] && echo "  MC 启动命令: ${MC_LAUNCH_CMD}"
echo "============================================="
