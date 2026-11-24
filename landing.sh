#!/bin/sh
# 仅用于合法、授权、合规的环境。使用前请阅读 README 的“免责声明与合规提示”。
set -eu
umask 077

# ============================================================
# 落地机代理脚本：SOCKS5 / HTTP（给 sbox.sh 的中转节点当落地）
# 只依赖 sing-box 的 mixed 入站，一个端口同时支持 SOCKS5 和 HTTP
# ============================================================

BASE_DIR="/etc/landing-proxy"
CONFIG_FILE="$BASE_DIR/config.json"
STATE_FILE="$BASE_DIR/state.env"
LOG_FILE="$BASE_DIR/info.log"

SB_BIN="/usr/local/bin/sing-box-landing"
SB_LIB_DIR="/usr/local/lib"
SYSTEMD_UNIT="/etc/systemd/system/landing-proxy.service"
OPENRC_INIT="/etc/init.d/landing-proxy"
SERVICE_NAME="landing-proxy"

LISTEN_PORT=""
PROXY_USER=""
PROXY_PASS=""
EXTERNAL_HOST=""
EXTERNAL_PORT=""
ALLOW_IP=""

PUBLIC_IPV4=""
PUBLIC_IPV6=""

INIT_STYLE=""
SERVICE_FILE=""
TMPDIR_LANDING=""
ARCH=""
HOST_ARCH=""
OS_NAME=""
IS_CONTAINER=0

log() { printf '%s\n' "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

read_or_exit() {
  if ! IFS= read -r "$1"; then
    log "[ERROR] 输入已结束（stdin 已关闭）"
    exit 1
  fi
}

fmt_hostport() {
  h="$1"
  p="$2"
  case "$h" in
    *:*) printf '[%s]:%s' "$h" "$p" ;;
    *)   printf '%s:%s' "$h" "$p" ;;
  esac
}

shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cleanup_tmp() {
  [ -n "${TMPDIR_LANDING:-}" ] && [ -d "${TMPDIR_LANDING:-}" ] && rm -rf "$TMPDIR_LANDING" >/dev/null 2>&1 || true
}
trap cleanup_tmp EXIT INT TERM

detect_init() {
  if [ -f /etc/alpine-release ] && have_cmd rc-update; then
    INIT_STYLE="openrc"
    SERVICE_FILE="$OPENRC_INIT"
  elif have_cmd systemctl; then
    INIT_STYLE="systemd"
    SERVICE_FILE="$SYSTEMD_UNIT"
  elif have_cmd rc-update; then
    INIT_STYLE="openrc"
    SERVICE_FILE="$OPENRC_INIT"
  else
    INIT_STYLE=""
    SERVICE_FILE=""
  fi
}

detect_arch() {
  local_arch="$(uname -m)"
  case "$local_arch" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7*) ARCH="armv7" ;;
    *)
      log "[ERROR] 不支持的架构: $local_arch"
      exit 1
      ;;
  esac
  HOST_ARCH="$local_arch"
}

detect_os() {
  OS_NAME="Linux"
  if [ -r /etc/os-release ]; then
    OS_NAME="$(. /etc/os-release >/dev/null 2>&1; printf '%s' "${PRETTY_NAME:-${ID:-Linux}}")"
  elif [ -f /etc/alpine-release ]; then
    OS_NAME="Alpine Linux $(cat /etc/alpine-release)"
  fi
  [ -n "$OS_NAME" ] || OS_NAME="Linux"
}

detect_container() {
  IS_CONTAINER=0
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    IS_CONTAINER=1
  elif grep -qE 'docker|podman|libpod|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=1
  elif [ -r /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then
    IS_CONTAINER=1
  fi
}

init_label() {
  case "$INIT_STYLE" in
    systemd) printf '%s' "systemd" ;;
    openrc)  printf '%s' "OpenRC" ;;
    *)       printf '%s' "未检测到 systemd / OpenRC" ;;
  esac
}

fetch_ip4() {
  curl -fsS4 --connect-timeout 5 --max-time 8 https://ip.sb 2>/dev/null || \
  curl -fsS4 --connect-timeout 5 --max-time 8 https://icanhazip.com 2>/dev/null || \
  true
}

fetch_ip6() {
  curl -fsS6 --connect-timeout 5 --max-time 8 https://ip.sb 2>/dev/null || \
  curl -fsS6 --connect-timeout 5 --max-time 8 https://icanhazip.com 2>/dev/null || \
  true
}

detect_public_ips() {
  PUBLIC_IPV4="$(fetch_ip4 | tr -d '\r\n' || true)"
  PUBLIC_IPV6="$(fetch_ip6 | tr -d '\r\n' || true)"

  case "$PUBLIC_IPV4" in
    ''|*[!0-9.]*) PUBLIC_IPV4="" ;;
  esac
  case "$PUBLIC_IPV6" in
    *:*) : ;;
    *) PUBLIC_IPV6="" ;;
  esac
}

show_env() {
  printf '\n%s\n' "===== 第一步：环境检测 =====" >&2
  printf '系统    ：%s（%s）\n' "$OS_NAME" "$(init_label)" >&2
  printf '架构    ：%s → %s\n' "${HOST_ARCH:-$(uname -m)}" "$ARCH" >&2
  if [ "$IS_CONTAINER" = "1" ]; then
    printf '运行环境：容器内（无 systemd/OpenRC 时无法托管服务）\n' >&2
  else
    printf '运行环境：物理机 / 虚拟机\n' >&2
  fi
  printf '公网 IPv4：%s\n' "${PUBLIC_IPV4:-未检测到}" >&2
  printf '公网 IPv6：%s\n' "${PUBLIC_IPV6:-未检测到}" >&2
}

detect_env() {
  detect_arch
  detect_os
  detect_container
  log "[INFO] 正在检测公网 IPv4 / IPv6（最长约 16 秒）..."
  detect_public_ips
  show_env
}

ensure_deps() {
  if have_cmd curl && have_cmd tar && have_cmd openssl; then
    return 0
  fi
  pkg_install
}

pkg_install() {
  if have_cmd apk; then
    log "[INFO] 安装依赖（Alpine / apk）..."
    apk add --no-cache curl ca-certificates openssl gcompat iproute2 >/dev/null
  elif have_cmd apt-get; then
    log "[INFO] 安装依赖（Debian/Ubuntu / apt）..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl tar ca-certificates openssl iproute2
    apt-get clean
    rm -rf /var/lib/apt/lists/*
  elif have_cmd dnf; then
    log "[INFO] 安装依赖（dnf）..."
    dnf install -y curl tar ca-certificates openssl iproute
  elif have_cmd yum; then
    log "[INFO] 安装依赖（yum）..."
    yum install -y curl tar ca-certificates openssl iproute
  else
    log "[ERROR] 未找到可用包管理器（apk/apt/dnf/yum）"
    exit 1
  fi
}

port_in_use() {
  p="$1"
  hex="$(printf '%04X' "$p")"
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    if awk -v hp=":$hex" 'NR>1 && index($2, hp) {found=1; exit} END {if (found) exit 0; else exit 1}' "$f"; then
      return 0
    fi
  done
  return 1
}

rand_port() {
  while :; do
    h="$(openssl rand -hex 2)"
    n=$((0x$h))
    p=$((20000 + (n % 40000)))
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
}

valid_cred() {
  case "$1" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_host() {
  case "$1" in
    ''|.*|*..*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

prompt_port() {
  while :; do
    default="$(rand_port)"
    printf '代理端口（TCP，SOCKS5/HTTP 共用）[%s]: ' "$default" >&2
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="$default"

    case "$ans" in
      ''|*[!0-9]*)
        log "请输入数字"
        continue
        ;;
    esac
    if [ "$ans" -lt 1 ] || [ "$ans" -gt 65535 ]; then
      log "端口范围必须是 1-65535"
      continue
    fi
    if port_in_use "$ans"; then
      log "端口 $ans 已被本机占用，请重新输入"
      continue
    fi
    LISTEN_PORT="$ans"
    return 0
  done
}

prompt_auth() {
  if [ -z "$PROXY_USER" ]; then
    PROXY_USER="u$(openssl rand -hex 3)"
  fi
  while :; do
    printf '代理用户名 [%s]（输入 - 表示不启用认证，不推荐）: ' "$PROXY_USER" >&2
    read_or_exit ans
    if [ "$ans" = "-" ]; then
      PROXY_USER=""
      PROXY_PASS=""
      log "[WARN] 已关闭认证，请务必用防火墙限制来源 IP"
      return 0
    fi
    [ -n "$ans" ] && PROXY_USER="$ans"
    if valid_cred "$PROXY_USER"; then
      break
    fi
    log "[ERROR] 用户名只能包含字母、数字、. _ ~ -"
  done

  if [ -z "$PROXY_PASS" ]; then
    PROXY_PASS="$(openssl rand -hex 8)"
  fi
  while :; do
    printf '代理密码 [%s]: ' "$PROXY_PASS" >&2
    read_or_exit ans
    [ -n "$ans" ] && PROXY_PASS="$ans"
    if valid_cred "$PROXY_PASS"; then
      return 0
    fi
    log "[ERROR] 密码只能包含字母、数字、. _ ~ -"
  done
}

prompt_external_port() {
  def="$1"
  while :; do
    printf '对外端口 [%s]: ' "$def" >&2
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="$def"
    case "$ans" in
      ''|*[!0-9]*)
        log "请输入数字"
        continue
        ;;
    esac
    if [ "$ans" -lt 1 ] || [ "$ans" -gt 65535 ]; then
      log "端口范围必须是 1-65535"
      continue
    fi
    EXTERNAL_PORT="$ans"
    return 0
  done
}

prompt_external() {
  default="${EXTERNAL_HOST:-${PUBLIC_IPV4:-${PUBLIC_IPV6:-}}}"
  while :; do
    printf '对外地址（中转机连接时使用）[%s]: ' "$default" >&2
    read_or_exit ans
    [ -z "$ans" ] && ans="$default"
    if valid_host "$ans"; then
      EXTERNAL_HOST="$ans"
      break
    fi
    log "[ERROR] 地址格式不正确（IPv6 直接填地址，不要加方括号）"
  done

  prompt_external_port "${EXTERNAL_PORT:-$LISTEN_PORT}"
}

prompt_allow_ip() {
  while :; do
    printf '允许连接的中转机 IP/CIDR（留空 = 不限制，建议填写）: ' >&2
    IFS= read -r ans || ans=""
    if [ -z "$ans" ]; then
      ALLOW_IP=""
      return 0
    fi
    case "$ans" in
      *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:/-]*)
        log "[ERROR] 地址格式不正确"
        continue
        ;;
    esac
    ALLOW_IP="$ans"
    return 0
  done
}

save_state() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"
  cat > "$STATE_FILE" <<EOF
LISTEN_PORT=$(shq "$LISTEN_PORT")
PROXY_USER=$(shq "$PROXY_USER")
PROXY_PASS=$(shq "$PROXY_PASS")
EXTERNAL_HOST=$(shq "$EXTERNAL_HOST")
EXTERNAL_PORT=$(shq "$EXTERNAL_PORT")
ALLOW_IP=$(shq "${ALLOW_IP:-}")
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || return 1
  . "$STATE_FILE"
  ALLOW_IP="${ALLOW_IP:-}"
  EXTERNAL_PORT="${EXTERNAL_PORT:-$LISTEN_PORT}"
  EXTERNAL_HOST="${EXTERNAL_HOST:-}"
}

is_installed() {
  [ -f "$STATE_FILE" ] || return 1
  [ -x "$SB_BIN" ] && [ -f "$CONFIG_FILE" ] && [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]
}

install_singbox() {
  if [ -z "$ARCH" ]; then
    detect_arch
  fi

  log "[INFO] 安装 sing-box（官方版，$ARCH）..."
  TMPDIR_LANDING="$(mktemp -d)"

  latest_json="$TMPDIR_LANDING/latest.json"
  curl -fsSL -H 'User-Agent: curl' \
    -o "$latest_json" \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest

  latest="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$latest_json" | head -n 1)"
  [ -n "$latest" ] || {
    log "[ERROR] 获取 sing-box 最新版本失败"
    exit 1
  }

  ver="${latest#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver}-linux-${ARCH}.tar.gz"

  log "[INFO] 下载 sing-box: $latest ($ARCH)"
  curl -fL --retry 3 --retry-all-errors -o "$TMPDIR_LANDING/sing-box.tar.gz" "$url"

  tar -xzf "$TMPDIR_LANDING/sing-box.tar.gz" -C "$TMPDIR_LANDING"

  sb_dir="$(find "$TMPDIR_LANDING" -maxdepth 1 -type d -name "sing-box-${ver}-linux-*" | head -n 1)"
  if [ -z "$sb_dir" ] || [ ! -f "$sb_dir/sing-box" ]; then
    log "[ERROR] 解压 sing-box 失败"
    exit 1
  fi

  install -m 755 "$sb_dir/sing-box" "$SB_BIN"

  if [ -f "$sb_dir/libcronet.so" ]; then
    mkdir -p "$SB_LIB_DIR"
    install -m 644 "$sb_dir/libcronet.so" "$SB_LIB_DIR/libcronet.so"
    if have_cmd ldconfig; then
      ldconfig >/dev/null 2>&1 || true
    fi
  fi

  rm -rf "$TMPDIR_LANDING"
  TMPDIR_LANDING=""
  log "[INFO] sing-box 已安装到 $SB_BIN"
}

check_singbox_exec() {
  rc=0
  "$SB_BIN" version >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && return 0

  log "[ERROR] sing-box 已安装但无法执行（退出码 $rc）。"
  if [ "$rc" -eq 137 ] || [ "$rc" -eq 9 ]; then
    log "[ERROR] 进程被 SIGKILL 杀掉，通常是内存不足（OOM）或安全策略限制。"
    log "[ERROR] 可检查：cat /sys/fs/cgroup/memory.events; cat /sys/fs/cgroup/memory.max; dmesg | tail"
  else
    log "[ERROR] 真实报错信息："
    "$SB_BIN" version >&2 || true
    if [ -f /etc/alpine-release ]; then
      log "[ERROR] Alpine 环境请确认已安装 gcompat（apk add gcompat）"
    fi
  fi
  exit 1
}

write_config() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"

  listen="0.0.0.0"
  if [ -f /proc/net/if_inet6 ]; then
    listen="::"
  fi

  {
    printf '{\n'
    printf '  "log": {\n'
    printf '    "level": "warn",\n'
    printf '    "timestamp": true,\n'
    printf '    "output": "%s"\n' "$LOG_FILE"
    printf '  },\n'
    printf '  "inbounds": [\n'
    printf '    {\n'
    printf '      "type": "mixed",\n'
    printf '      "tag": "mixed-in",\n'
    printf '      "listen": "%s",\n' "$listen"
    printf '      "listen_port": %s' "$LISTEN_PORT"
    if [ -n "$PROXY_USER" ]; then
      printf ',\n      "users": [\n        {\n'
      printf '          "username": "%s",\n' "$PROXY_USER"
      printf '          "password": "%s"\n' "$PROXY_PASS"
      printf '        }\n      ]'
    fi
    printf '\n    }\n'
    printf '  ],\n'
    printf '  "outbounds": [\n'
    printf '    {\n      "type": "direct",\n      "tag": "direct"\n    }\n'
    printf '  ],\n'
    printf '  "route": {\n    "final": "direct"\n  }\n'
    printf '}\n'
  } > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"
}

write_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Landing Proxy (SOCKS5/HTTP for sing-box relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=/usr/local/lib
ExecStart=$SB_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_UNIT"
  elif [ "$INIT_STYLE" = "openrc" ]; then
    cat > "$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
description="Landing Proxy (SOCKS5/HTTP for sing-box relay)"
command="$SB_BIN"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
  need net
}

start_pre() {
  export LD_LIBRARY_PATH="/usr/local/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
}
EOF
    chmod 755 "$OPENRC_INIT"
  else
    log "[ERROR] 未检测到 systemd 或 OpenRC"
    exit 1
  fi
}

ensure_firewall() {
  if have_cmd ufw; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
      if [ -n "${ALLOW_IP:-}" ]; then
        ufw allow from "$ALLOW_IP" to any port "$LISTEN_PORT" proto tcp >/dev/null 2>&1 || true
      else
        ufw allow "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
      fi
    fi
  fi

  if have_cmd firewall-cmd; then
    if firewall-cmd --state >/dev/null 2>&1; then
      if [ -n "${ALLOW_IP:-}" ]; then
        case "$ALLOW_IP" in
          *:*) family="ipv6" ;;
          *) family="ipv4" ;;
        esac
        firewall-cmd --permanent --add-rich-rule="rule family=$family source address=$ALLOW_IP port port=$LISTEN_PORT protocol=tcp accept" >/dev/null 2>&1 || true
      else
        firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
      fi
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
}

remove_firewall_rules() {
  old_port="$1"
  old_ip="$2"
  [ -n "$old_port" ] || return 0

  if have_cmd ufw; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
      if [ -n "$old_ip" ]; then
        ufw delete allow from "$old_ip" to any port "$old_port" proto tcp >/dev/null 2>&1 || true
      else
        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
      fi
    fi
  fi

  if have_cmd firewall-cmd; then
    if firewall-cmd --state >/dev/null 2>&1; then
      if [ -n "$old_ip" ]; then
        case "$old_ip" in
          *:*) family="ipv6" ;;
          *) family="ipv4" ;;
        esac
        firewall-cmd --permanent --remove-rich-rule="rule family=$family source address=$old_ip port port=$old_port protocol=tcp accept" >/dev/null 2>&1 || true
      else
        firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
      fi
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
}

stop_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  elif [ "$INIT_STYLE" = "openrc" ]; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
  fi
  sleep 1
}

disable_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  elif [ "$INIT_STYLE" = "openrc" ]; then
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
  fi
}

start_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
      log "[ERROR] 落地代理启动失败，查看日志："
      journalctl -u "$SERVICE_NAME" -e --no-pager || true
      exit 1
    fi
  elif [ "$INIT_STYLE" = "openrc" ]; then
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || true
    sleep 2
    if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
      log "[ERROR] 落地代理启动失败，可执行：rc-service $SERVICE_NAME status"
      exit 1
    fi
  else
    log "[ERROR] 未检测到可用服务管理器"
    exit 1
  fi
}

restart_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl daemon-reload
    if ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
      log "[ERROR] 落地代理重启失败，查看日志："
      journalctl -u "$SERVICE_NAME" -e --no-pager || true
      exit 1
    fi
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
      log "[ERROR] 落地代理重启后未处于 active 状态，查看日志："
      journalctl -u "$SERVICE_NAME" -e --no-pager || true
      exit 1
    fi
  elif [ "$INIT_STYLE" = "openrc" ]; then
    if ! rc-service "$SERVICE_NAME" restart >/dev/null 2>&1; then
      log "[ERROR] 落地代理重启失败，可执行：rc-service $SERVICE_NAME status"
      exit 1
    fi
    sleep 2
    if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
      log "[ERROR] 落地代理重启后状态异常，可执行：rc-service $SERVICE_NAME status"
      exit 1
    fi
  else
    log "[ERROR] 未检测到可用服务管理器"
    exit 1
  fi
}

show_conn() {
  load_state || true

  hp="$(fmt_hostport "$EXTERNAL_HOST" "$EXTERNAL_PORT")"
  if [ -n "$PROXY_USER" ]; then
    auth="$PROXY_USER:$PROXY_PASS@"
  else
    auth=""
  fi

  printf '\n%s\n' "===== 落地连接信息 ====="
  printf '监听端口：%s\n' "$LISTEN_PORT"
  printf '对外地址：%s\n' "$hp"
  if [ -n "$PROXY_USER" ]; then
    printf '认证    ：%s / %s\n' "$PROXY_USER" "$PROXY_PASS"
  else
    printf '认证    ：无（不推荐）\n'
  fi
  printf '\nSOCKS5（支持 TCP，UDP 取决于落地防火墙）：\n'
  printf 'socks5://%s%s\n' "$auth" "$hp"
  printf '\nHTTP（仅 TCP）：\n'
  printf 'http://%s%s\n' "$auth" "$hp"
  printf '\n把上面的链接粘贴到中转机的 sbox.sh「中转设置」中。\n'
  if [ -n "${ALLOW_IP:-}" ]; then
    printf '已限制来源：%s\n' "$ALLOW_IP"
  else
    printf '[WARN] 未限制来源 IP，请用防火墙/安全组只放行中转机\n'
  fi
  printf '\n'
}

fresh_install() {
  ensure_deps
  detect_env

  printf '\n%s\n' "===== 第二步：配置落地代理 =====" >&2
  prompt_port
  prompt_auth
  prompt_external
  prompt_allow_ip

  install_singbox
  check_singbox_exec

  save_state
  write_config
  write_service

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  ensure_firewall

  log "[INFO] 启动服务..."
  start_service

  show_conn
}

change_port() {
  load_state || true

  printf '\n%s\n' "===== 修改代理端口 =====" >&2
  old_listen="$LISTEN_PORT"
  old_allow="${ALLOW_IP:-}"
  prompt_port
  if [ -z "${EXTERNAL_PORT:-}" ] || [ "$EXTERNAL_PORT" = "$old_listen" ]; then
    EXTERNAL_PORT="$LISTEN_PORT"
  fi
  prompt_external_port "$EXTERNAL_PORT"

  stop_service
  save_state
  write_config
  remove_firewall_rules "$old_listen" "$old_allow"
  ensure_firewall

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 启动服务..."
  start_service

  show_conn
}

change_auth() {
  load_state || true

  printf '\n%s\n' "===== 修改用户名 / 密码 =====" >&2
  prompt_auth

  save_state
  write_config

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 重启服务..."
  restart_service

  show_conn
}

change_external() {
  load_state || true

  printf '\n%s\n' "===== 修改对外地址 =====" >&2
  prompt_external
  save_state
  show_conn
}

change_allow_ip() {
  load_state || true

  printf '\n%s\n' "===== 修改来源限制 =====" >&2
  printf '当前：%s\n' "${ALLOW_IP:-不限制}" >&2
  old_allow="${ALLOW_IP:-}"
  prompt_allow_ip
  save_state
  remove_firewall_rules "$LISTEN_PORT" "$old_allow"
  ensure_firewall
  show_conn
}

uninstall_all() {
  stop_service
  disable_service

  rm -f "$SYSTEMD_UNIT" "$OPENRC_INIT" 2>/dev/null || true
  rm -f "$SB_BIN" 2>/dev/null || true
  rm -rf "$BASE_DIR" 2>/dev/null || true

  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

menu_loop() {
  load_state || true

  while :; do
    printf '\n%s\n' "===== 落地代理（SOCKS5 / HTTP）管理脚本 ====="
    printf '当前端口：%s\n' "$LISTEN_PORT"
    printf '对外地址：%s\n' "$(fmt_hostport "$EXTERNAL_HOST" "$EXTERNAL_PORT")"
    if [ -n "$PROXY_USER" ]; then
      printf '认证    ：%s\n' "$PROXY_USER"
    else
      printf '认证    ：无\n'
    fi
    printf '%s\n' "1) 重装"
    printf '%s\n' "2) 查看连接信息"
    printf '%s\n' "3) 修改代理端口"
    printf '%s\n' "4) 修改用户名 / 密码"
    printf '%s\n' "5) 修改对外地址"
    printf '%s\n' "6) 修改来源限制"
    printf '%s\n' "7) 重启服务"
    printf '%s\n' "8) 卸载"
    printf '%s\n' "0) 退出"
    printf '%s' "请选择 [0-8]: " >&2

    IFS= read -r choice || choice=""

    case "$choice" in
      1)
        log "[INFO] 开始重新安装..."
        uninstall_all
        fresh_install
        exit 0
        ;;
      2)
        show_conn
        ;;
      3)
        change_port
        ;;
      4)
        change_auth
        ;;
      5)
        change_external
        ;;
      6)
        change_allow_ip
        ;;
      7)
        log "[INFO] 重启服务..."
        restart_service
        printf '%s\n' "[INFO] 服务已重启"
        ;;
      8)
        log "[INFO] 开始卸载..."
        uninstall_all
        printf '%s\n' "[INFO] 已卸载"
        exit 0
        ;;
      0|'')
        exit 0
        ;;
      *)
        log "请输入 0-8 之间的选项"
        ;;
    esac
  done
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    log "[ERROR] 请使用 root 运行"
    exit 1
  fi

  detect_init
  detect_container
  detect_arch
  load_state 2>/dev/null || true

  if [ -z "$INIT_STYLE" ]; then
    log "[ERROR] 未检测到 systemd / OpenRC，脚本需要服务管理器才能托管落地代理"
    if [ "$IS_CONTAINER" = "1" ]; then
      log "[ERROR] 当前在容器内运行。请改用支持 systemd 的镜像并以 --privileged 启动，"
      log "[ERROR] 或直接在宿主机 / VPS 上运行本脚本。"
    fi
    exit 1
  fi

  if is_installed; then
    menu_loop
  else
    fresh_install
  fi
}

main "$@"
