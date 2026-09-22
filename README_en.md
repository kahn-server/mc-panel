# KT-Anar Minecraft Management Panel (mcpanel)

All-in-one web management panel for the KT-Anar server: live monitoring, RCON console, recovery mode, plugin management, and Cyber-panel screen embedding.

## Features

- **Live monitoring**
  - Online/max players: native `minecraft:list` command (auto-fallback to `list`), loose regex handles both Chinese and English output (`X of a max of Y` / `X/Y` / `当前有 X 位玩家在线…`)
  - TPS: Paper native `tps` command (no Essentials dependency)
  - JVM heap: native `/gc` output parsing (max / allocated / free)
  - Server uptime: reads `/proc/<pid>/stat` starttime of the java process (pure system-level, no commands/plugins), falls back to the `Done (` line in logs
  - System CPU / memory / disk
- **RCON console**: run any command from the web page
  - Pure socket hand-written client (embedded `RCONClient`), no third-party binary, no `signal.alarm` sub-thread pitfalls
- **Server control**
  - Start / Stop / **⚡ Quick Restart** / Refresh status
  - Quick restart: systemd executes `systemctl restart` directly (single transaction, **not stop+start**); screen/tmux has no restart command, so it composites stop → wait for world save → start
  - After server-core upgrade: once the new jar is uploaded and replaced, the confirm dialog triggers quick restart directly (same `systemctl restart`)
- **Recovery mode**: socket heartbeat validation, invalid connections return `Error` for all fields; 3-second real-time push
- **Plugin management**: browse / upload / delete plugins (path-traversal protection + file magic-number validation)
- **Backup management**: list only shows common archive formats (`.zip` / `.gz` / `.tar` / `.tar.gz` / `.tgz` / `.7z` / `.rar` / `.bz2` / `.xz` / `.zst`); other files hidden; download supported. **Backup dir auto-created**: when `MC_BACKUP_ROOT` is unset, creates `${MC_DIR}/backups` with `plugins_bak` / `server_jar_bak` subdirs (plugin-delete backups, server-jar-replacement backups)
- **Server core management**: auto-detects any server jar name in the MC dir (`server.jar` / `paper-*.jar` / `spigot.jar` etc.), supports upload-replace (old core auto-backed up)
- **Multi-launcher compatibility (systemd / screen / tmux)**
  - **All detection lives in the installer (preinstall.sh)**: at install time it auto-detects the MC management type (systemd unit → screen session → tmux session), asks the user to confirm, then injects `MC_LAUNCH_TYPE` / `MC_SERVICE_NAME` env vars
  - **The panel runs zero probe commands** (no `screen -ls` / `tmux ls` / `systemctl list-unit-files` scans), it only reads the env vars
  - screen/tmux launch command is asked by the installer (`MC_LAUNCH_CMD`, defaults to `start.sh` under MC_DIR or the first jar)
- **Cyber-panel embedding**: built-in websockify (127.0.0.1:6080 → x11vnc 5900) streams the Cyber dashboard into the page in real time
- **Audit log**: records real client IP (PROXY protocol passthrough), logins and command operations
- **HTTPS**: self-signed cert (gunicorn terminates TLS directly)

## Tech Stack

| Component | Version | Note |
|---|---|---|
| Flask | 3.0.3 | Web framework |
| Flask-SocketIO | 5.6.1 | Real-time push (async_mode=eventlet) |
| Flask-Limiter | 3.8.0 | Login rate limiting |
| gunicorn | 23.0.0 | Production server (eventlet worker, `proxy_protocol=True`) |
| eventlet | 0.39.1 | Coroutine worker |
| websockify | 0.13.0 | VNC → WebSocket (Cyber panel) |
| systemd | - | Service hosting + env injection (main unit) |

## Architecture

```
Client browser (HTTPS)
      │  <VPS_PUBLIC_IP>:2224 (frp) → 127.0.0.1:8080
      ▼
┌─────────────────────────────┐
│  gunicorn (eventlet, CPU 6-7)│
│  ┌───────────────────────┐  │
│  │ app.py (Flask + SIO)  │  │
│  │  RCONClient(socket)   │──┼──► MC RCON 127.0.0.1:25575
│  │  control: systemctl/  │──┼──► MC process (routed by MC_LAUNCH_TYPE)
│  │    screen/tmux        │  │
│  └───────────────────────┘  │
│  websockify :6080 ──────────┼──► x11vnc :5900 ◄── Cyber panel (Xvfb+dashboard.py)
└─────────────────────────────┘
```

## Directory Layout

```
/home/mcserver/.mc_panel/
├── app.py              # Main program (single file, includes frontend template)
├── preinstall.sh       # One-click installer (incl. MC management-type detection/confirm)
├── requirements.txt    # Python deps
├── gunicorn_config.py  # gunicorn config (proxy_protocol / cert)
├── README.md           # This document
├── README_en.md        # English version
├── certs/              # HTTPS certs (cert.pem / key.pem)
├── data/               # Panel data
├── static/avatars/     # Player avatar cache
├── users.json          # Panel users (hashed)
└── websockify.log      # websockify log
```

## Requirements

- Ubuntu / Debian (apt-based)
- Python 3.8+
- Runtime user (production: `mcserver`), deps installed with `--user`
- MC server must enable RCON (`server.properties`: `enable-rcon=true`, port 25575)

## Quick Deploy

### One-click script

```bash
cd /home/mcserver/.mc_panel
sudo bash preinstall.sh              # deploy to current user
sudo bash preinstall.sh mcserver     # specify runtime user
MCRCON_PASS=your_password sudo bash preinstall.sh   # preset RCON password (interactive otherwise)
MC_LAUNCH_TYPE=systemd MC_SERVICE_NAME=mc sudo bash preinstall.sh  # skip prompts, set directly
```

The script does: system deps → Python deps (`--user`) → directory layout → self-signed HTTPS cert → **frp reverse-proxy prompt (none / PROXY v1 / PROXY v2)** → **separate backup-dir prompt (may leave empty)** → generate `SECRET_KEY` → **MC management-type auto-detect + user confirm** → env vars merged into the `mcpanel.service` main unit → **gunicorn config per frp mode** → sudoers no-password rules (`/etc/sudoers.d/mcpanel-<user>`) → write `mcpanel.service` → start.

**MC management-type flow**:
1. Auto-detect: systemd units (`minecraft`/`paper`/`spigot`/`purpur`/`bukkit`/`mc`) → screen sessions → tmux sessions
2. Show result `[systemd] name: [minecraft]`, ask "confirm this result? (Y/n)"
3. Answer `n` to enter manually: **type (systemd/screen/tmux)** + **service/session name**
4. screen/tmux types additionally ask for the **launch command** (empty = auto-use `start.sh` in MC_DIR or the first jar)

> frp V2 passthrough: gunicorn only parses PROXY v1 text headers. With V2, the script generates a gunicorn config bound to `127.0.0.1:8080` and prints mmproxy instructions (listen 8081, convert V2→v1).

### Manual Deploy (reference)

```bash
# deps
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip python3-dev build-essential libssl-dev libffi-dev xvfb x11vnc
sudo -H -u mcserver python3 -m pip install --user -r requirements.txt

# cert (generate if missing)
cd certs && openssl req -x509 -newkey rsa:4096 -nodes -out cert.pem -keyout key.pem -days 365 -subj '/CN=kt-anar-panel'

# Env vars go directly into the mcpanel.service main unit [Service] section
sudo tee /etc/systemd/system/mcpanel.service >/dev/null <<'EOF'
[Unit]
Description=KT-Anar Minecraft Management Panel
After=network.target

[Service]
User=mcserver
Group=mcserver
WorkingDirectory=/home/mcserver/.mc_panel
Environment="SECRET_KEY=<generated key>"
Environment="MCRCON_PASS=<RCON password>"
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

## Environment Variables

| Variable | Required | Note |
|---|---|---|
| `SECRET_KEY` | ✅ | Flask session signing key (64-hex). **Changing it invalidates all logged-in cookies once** |
| `MCRCON_PASS` | ✅ | MC RCON password. Panel refuses to start if missing (`RuntimeError`) |
| `MC_DIR` | optional | MC server dir, default `/data/minecraft_server` |
| `MC_BACKUP_ROOT` | optional | Backup root, default `${MC_DIR}/backups` |
| `MC_LOG_DIR` | optional | Panel log dir, default `/data/mc_panel_logs` |
| `MC_SERVICE_NAME` | optional | MC systemd service / screen / tmux session name (**detected+confirmed by preinstall.sh**, default `minecraft`) |
| `MC_LAUNCH_TYPE` | ✅ | MC management type: `systemd` / `screen` / `tmux`. **Injected by preinstall.sh after detection+confirm; the panel never probes itself**. Unset ⇒ panel cannot determine launch method |
| `MC_LAUNCH_CMD` | optional | Launch command for screen/tmux (e.g. `bash start.sh`). Empty ⇒ auto-use `start.sh` or the first jar under MC_DIR |

`SECRET_KEY` / `MCRCON_PASS` and all MC config are injected via `Environment=` in the **mcpanel.service main unit `[Service]` section** (preinstall.sh writes directly to the main unit). The code contains **no plaintext keys or hardcoded paths**. To change paths, edit the main unit, then `daemon-reload` + restart.

## Service Management

```bash
systemctl status mcpanel.service       # status
journalctl -u mcpanel.service -f       # live logs
journalctl -u mcpanel.service -n 50    # last 50 lines
systemctl restart mcpanel.service      # restart
sudo systemctl show mcpanel.service | grep -i environment   # verify env vars
```

## frp Reverse Proxy

`/usr/local/frp/frpc.toml`:

```toml
[[proxies]]
name = "mc_panel"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 2224
```

Public access: `https://<YOUR_VPS_PUBLIC_IP>:2224`. gunicorn uses `proxy_protocol=True` (with mmproxy) to pass real client IPs to the audit log.

## Cyber Panel Integration

The Cyber dashboard (separate project: **[Cyberpunk MC Dashboard](https://github.com/kahn-server/cyber-mc-dashboard)**, managed by `dashboard.sh`) runs: `Xvfb → dashboard.py(CPU 6,7) → x11vnc:5900 → websockify:6080`. mcpanel auto-starts websockify via `start_websockify()`; the dashboard is embedded in the page. Source code, setup guide and config template live in its repository.

## Security Notes

- Zero hardcoded keys: `SECRET_KEY` / `MCRCON_PASS` live only in the mcpanel.service main unit (root-readable)
- Login rate limiting: Flask-Limiter + super-password IP limiting (5 failures locked for 24h)
- Plugin upload: path-traversal protection + file magic-number validation
- Session cookie: signed with `SECRET_KEY`; rotating the key logs everyone out
- Rotate `SECRET_KEY` periodically (one change = everyone re-logins)

## Troubleshooting

| Symptom | Check |
|---|---|
| Service won't start, `环境变量 MCRCON_PASS 未设置` | Environment lines in mcpanel.service wrong, or no `daemon-reload` |
| Service won't start, `环境变量 SECRET_KEY 未设置` | Same as above |
| Panel shows server not running / "未检测到 MC 启动方式" | `MC_LAUNCH_TYPE` unset or mismatched. Check: `systemctl show mcpanel.service \| grep MC_LAUNCH`; fix the main unit env and restart, or re-run `preinstall.sh` |
| screen/tmux type but won't start | Verify `MC_SERVICE_NAME` is the real session name and `MC_LAUNCH_CMD` is correct (default `start.sh` or first jar); a session owned by another user may not be controllable by the panel user |
| Player count / TPS looks wrong | `minecraft:list` / `tps` are native commands; confirm the server is Paper/Spigot-based |
| Backups list missing files | Only common archives are shown (zip/gz/tar/7z etc.); non-archives are hidden |
| Cyber panel not visible | `dashboard.sh start`; confirm x11vnc:5900 and websockify:6080 are listening |
| Audit log shows only 127.0.0.1 | Confirm `proxy_protocol=True` in gunicorn_config.py and the frp mmproxy setup |

## Changelog

- **2026-09-22**: Detection moved out of the panel — `detect_mc_launcher` now only reads `MC_LAUNCH_TYPE` (zero systemctl/screen/tmux probes); preinstall.sh added management-type auto-detect (systemd→screen→tmux) + user confirm + manual entry (type/name/screen·tmux launch cmd `MC_LAUNCH_CMD`); added **⚡ Quick Restart** (systemd `systemctl restart` directly, not stop+start) and direct restart after server-core upgrade; env vars merged into the mcpanel.service main unit
- **2026-09-21 (4)**: Service-name & backup-dir fallbacks — auto-scan systemd services when `MC_SERVICE_NAME` unset; preinstall.sh auto-detects the service name; auto-creates default backup dir with `plugins_bak`/`server_jar_bak` subdirs
- **2026-09-21 (3)**: Generalization — backup list shows only common archives; any-named server jar detection (`find_server_jar`); MC launcher auto-detect (systemd/screen/tmux); preinstall.sh frp prompt (none/v1/v2) and separate backup-dir prompt, gunicorn config per frp mode
- **2026-09-21 (2)**: MC dirs configurable — `MC_DIR`/`MC_BACKUP_ROOT`/`MC_LOG_DIR` as env vars, preinstall.sh injects them and adds sudoers no-password rules
- **2026-09-21 (1)**: RCON rewrite — removed `mcrcon` binary, embedded pure-socket `RCONClient`; native `minecraft:list` player list; native TPS parsing; process-level `/proc` uptime; `SECRET_KEY`/`MCRCON_PASS` env-var-ized
- **2026-09-19**: gunicorn + eventlet production, real-IP passthrough, 3s polling, recovery-mode socket validation, plugin management, Cyber-panel embedding
