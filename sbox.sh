#!/bin/sh
set -eu
umask 077

BASE_DIR="/etc/sing-box"
CONFIG_FILE="$BASE_DIR/config.json"
STATE_FILE="$BASE_DIR/state.env"
CERT_FILE="$BASE_DIR/cert.pem"
KEY_FILE="$BASE_DIR/key.pem"
LOG_FILE="$BASE_DIR/info.log"

SB_BIN="/usr/local/bin/sing-box"
SYSTEMD_UNIT="/etc/systemd/system/sing-box.service"
OPENRC_INIT="/etc/init.d/sing-box"

HY2_UP_MBPS="${HY2_UP_MBPS:-100}"
HY2_DOWN_MBPS="${HY2_DOWN_MBPS:-100}"

SNI_HOST="${SNI_HOST:-www.bing.com}"

PUBLIC_IPV4=""
PUBLIC_IPV6=""

INIT_STYLE=""
SERVICE_FILE=""
TMPDIR_SBOX=""

USED_UDP_PORTS=""
USED_TCP_PORTS=""

HY2_LISTEN_PORT=""
TUIC_LISTEN_PORT=""
ANYTLS_LISTEN_PORT=""

ENABLE_HY2=0
ENABLE_TUIC=0
ENABLE_ANYTLS=0
IP_MODE=""

AUTH_PASS=""
UUID=""

log() { printf '%s\n' "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

fmt_hostport() {
  h="$1"
  p="$2"
  case "$h" in
    *:*) printf '[%s]:%s' "$h" "$p" ;;
    *)   printf '%s:%s' "$h" "$p" ;;
  esac
}

cleanup_tmp() {
  [ -n "${TMPDIR_SBOX:-}" ] && [ -d "${TMPDIR_SBOX:-}" ] && rm -rf "$TMPDIR_SBOX" >/dev/null 2>&1 || true
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

is_installed() {
  [ -x "$SB_BIN" ] && [ -f "$CONFIG_FILE" ] && [ -f "$STATE_FILE" ] && [ -f "$SERVICE_FILE" ]
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
}

port_in_use() {
  p="$1"
  proto="$2"
  hex="$(printf '%04X' "$p")"

  case "$proto" in
    udp) files="/proc/net/udp /proc/net/udp6" ;;
    tcp) files="/proc/net/tcp /proc/net/tcp6" ;;
    *)
      return 1
      ;;
  esac

  for f in $files; do
    [ -r "$f" ] || continue
    if awk -v hp=":$hex" 'NR>1 && index($2, hp) {found=1; exit} END {if (found) exit 0; else exit 1}' "$f"; then
      return 0
    fi
  done
  return 1
}

proto_port_selected() {
  proto="$1"
  port="$2"
  case "$proto" in
    udp)
      case " $USED_UDP_PORTS " in
        *" $port "*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    tcp)
      case " $USED_TCP_PORTS " in
        *" $port "*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

proto_port_mark() {
  proto="$1"
  port="$2"
  case "$proto" in
    udp) USED_UDP_PORTS="$USED_UDP_PORTS $port" ;;
    tcp) USED_TCP_PORTS="$USED_TCP_PORTS $port" ;;
  esac
}

rand_port() {
  proto="$1"
  while :; do
    h="$(openssl rand -hex 2)"
    n=$((0x$h))
    p=$((20000 + (n % 40000)))

    if ! port_in_use "$p" "$proto" && ! proto_port_selected "$proto" "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
}

prompt_port() {
  label="$1"
  proto="$2"
  while :; do
    default="$(rand_port "$proto")"
    printf '%s [%s]: ' "$label" "$default" >&2
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="$default"

    case "$ans" in
      ''|*[!0-9]*)
        log "请输入 1-65535 的数字"
        continue
        ;;
    esac

    if [ "$ans" -lt 1 ] || [ "$ans" -gt 65535 ]; then
      log "端口范围必须是 1-65535"
      continue
    fi

    if port_in_use "$ans" "$proto"; then
      log "端口 $ans 已被本机占用，请重新输入"
      continue
    fi

    if proto_port_selected "$proto" "$ans"; then
      log "端口 $ans 与前面同类协议冲突，请重新输入"
      continue
    fi

    proto_port_mark "$proto" "$ans"
    printf '%s' "$ans"
    return 0
  done
}

apply_protocol_choice() {
  raw="$(printf '%s' "$1" | tr -d '[:space:]')"
  [ -n "$raw" ] || return 1

  h=0
  t=0
  a=0

  case "$raw" in
    4|all|ALL)
      h=1
      t=1
      a=1
      ;;
    *)
      old_ifs="$IFS"
      IFS=','
      for item in $raw; do
        case "$item" in
          1) h=1 ;;
          2) t=1 ;;
          3) a=1 ;;
          4) h=1; t=1; a=1 ;;
          *)
            IFS="$old_ifs"
            return 1
            ;;
        esac
      done
      IFS="$old_ifs"
      ;;
  esac

  if [ "$h" -eq 0 ] && [ "$t" -eq 0 ] && [ "$a" -eq 0 ]; then
    return 1
  fi

  ENABLE_HY2="$h"
  ENABLE_TUIC="$t"
  ENABLE_ANYTLS="$a"
  return 0
}

show_protocol_status() {
  label=""
  if [ "$ENABLE_HY2" = "1" ]; then
    label="Hysteria2"
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    if [ -n "$label" ]; then
      label="$label / TUIC"
    else
      label="TUIC"
    fi
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    if [ -n "$label" ]; then
      label="$label / AnyTLS"
    else
      label="AnyTLS"
    fi
  fi
  printf '%s' "${label:-无}"
}

prompt_protocols() {
  printf '\n%s\n' "===== 第一步：选择要安装的协议（可多选）=====" >&2
  printf '当前选择：%s\n' "$(show_protocol_status)" >&2
  printf '%s\n' "1) Hysteria2（UDP）" >&2
  printf '%s\n' "2) TUIC（UDP）" >&2
  printf '%s\n' "3) AnyTLS（TCP）" >&2
  printf '%s\n' "4) 全部安装（Hysteria2 + TUIC + AnyTLS）" >&2
  printf '%s\n' "多选示例：输入 1,3 表示只安装 Hysteria2 和 AnyTLS" >&2
  printf '%s\n' "0) 取消" >&2

  while :; do
    printf '%s' "请选择 [1/2/3/4 或 1,3]: " >&2
    IFS= read -r ans || ans=""
    case "$ans" in
      '')
        log "[WARN] 请输入选项，不要直接回车"
        continue
        ;;
      0)
        return 1
        ;;
    esac

    if apply_protocol_choice "$ans"; then
      log "[INFO] 已选择协议：$(show_protocol_status)"
      return 0
    fi
    log "[ERROR] 无效选择，请输入 1-4 或逗号分隔的组合（如 1,3）"
  done
}

ip_mode_label() {
  case "$IP_MODE" in
    4) printf '%s' "仅 IPv4" ;;
    6) printf '%s' "仅 IPv6" ;;
    both) printf '%s' "IPv4 + IPv6（双栈）" ;;
    *) printf '%s' "未选择" ;;
  esac
}

listen_addr() {
  case "$IP_MODE" in
    4) printf '%s' "0.0.0.0" ;;
    *) printf '%s' "::" ;;
  esac
}

stack_selected() {
  case "$IP_MODE" in
    4) [ "$1" = "V4" ] ;;
    6) [ "$1" = "V6" ] ;;
    *) return 0 ;;
  esac
}

prompt_ip_mode() {
  printf '\n%s\n' "===== 第二步：选择监听与节点输出的 IP 栈 =====" >&2
  printf '当前选择：%s\n' "$(ip_mode_label)" >&2
  printf '%s\n' "1) 仅 IPv4" >&2
  printf '%s\n' "2) 仅 IPv6" >&2
  printf '%s\n' "3) 双栈（IPv4 + IPv6）" >&2
  printf '%s\n' "0) 取消" >&2

  while :; do
    printf '%s' "请选择 [1/2/3]: " >&2
    IFS= read -r ans || ans=""
    case "$ans" in
      1) IP_MODE="4" ;;
      2) IP_MODE="6" ;;
      3) IP_MODE="both" ;;
      0) return 1 ;;
      '')
        log "[WARN] 请输入选项，不要直接回车"
        continue
        ;;
      *)
        log "[ERROR] 请输入 1、2 或 3"
        continue
        ;;
    esac
    log "[INFO] 已选择：$(ip_mode_label)"
    return 0
  done
}

clear_disabled_ports() {
  if [ "$ENABLE_HY2" != "1" ]; then
    HY2_LISTEN_PORT=""
  fi
  if [ "$ENABLE_TUIC" != "1" ]; then
    TUIC_LISTEN_PORT=""
  fi
  if [ "$ENABLE_ANYTLS" != "1" ]; then
    ANYTLS_LISTEN_PORT=""
  fi
}

prompt_all_ports() {
  USED_UDP_PORTS=""
  USED_TCP_PORTS=""
  clear_disabled_ports()

  if [ "$ENABLE_HY2" = "1" ]; then
    HY2_LISTEN_PORT="$(prompt_port '请输入 HY2 端口 (UDP) [回车随机]' udp)"
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    TUIC_LISTEN_PORT="$(prompt_port '请输入 TUIC 端口 (UDP) [回车随机]' udp)"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    ANYTLS_LISTEN_PORT="$(prompt_port '请输入 ANYTLS 端口 (TCP) [回车随机]' tcp)"
  fi
}

prompt_missing_ports() {
  USED_UDP_PORTS=""
  USED_TCP_PORTS=""
  clear_disabled_ports()

  if [ "$ENABLE_HY2" = "1" ] && [ -n "$HY2_LISTEN_PORT" ]; then
    proto_port_mark udp "$HY2_LISTEN_PORT"
  fi
  if [ "$ENABLE_TUIC" = "1" ] && [ -n "$TUIC_LISTEN_PORT" ]; then
    proto_port_mark udp "$TUIC_LISTEN_PORT"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ] && [ -n "$ANYTLS_LISTEN_PORT" ]; then
    proto_port_mark tcp "$ANYTLS_LISTEN_PORT"
  fi

  if [ "$ENABLE_HY2" = "1" ] && [ -z "$HY2_LISTEN_PORT" ]; then
    HY2_LISTEN_PORT="$(prompt_port '请输入 HY2 端口 (UDP) [回车随机]' udp)"
  fi
  if [ "$ENABLE_TUIC" = "1" ] && [ -z "$TUIC_LISTEN_PORT" ]; then
    TUIC_LISTEN_PORT="$(prompt_port '请输入 TUIC 端口 (UDP) [回车随机]' udp)"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ] && [ -z "$ANYTLS_LISTEN_PORT" ]; then
    ANYTLS_LISTEN_PORT="$(prompt_port '请输入 ANYTLS 端口 (TCP) [回车随机]' tcp)"
  fi
}

gen_creds() {
  AUTH_PASS="$(openssl rand -hex 4)"
  UUID="$(cat /proc/sys/kernel/random/uuid)"
}

gen_cert() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"

  log "[INFO] 生成自签证书（CN=$SNI_HOST）..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 3650 \
    -subj "/CN=$SNI_HOST" >/dev/null 2>&1

  chmod 600 "$KEY_FILE" "$CERT_FILE"
}

save_state() {
  mkdir -p "$BASE_DIR"
  cat > "$STATE_FILE" <<EOF
SNI_HOST=$(shq "$SNI_HOST")
HY2_UP_MBPS=$(shq "$HY2_UP_MBPS")
HY2_DOWN_MBPS=$(shq "$HY2_DOWN_MBPS")
IP_MODE=$(shq "$IP_MODE")
ENABLE_HY2=$(shq "$ENABLE_HY2")
ENABLE_TUIC=$(shq "$ENABLE_TUIC")
ENABLE_ANYTLS=$(shq "$ENABLE_ANYTLS")
HY2_LISTEN_PORT=$(shq "$HY2_LISTEN_PORT")
TUIC_LISTEN_PORT=$(shq "$TUIC_LISTEN_PORT")
ANYTLS_LISTEN_PORT=$(shq "$ANYTLS_LISTEN_PORT")
AUTH_PASS=$(shq "$AUTH_PASS")
UUID=$(shq "$UUID")
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || return 1
  . "$STATE_FILE"
  ENABLE_HY2="${ENABLE_HY2:-1}"
  ENABLE_TUIC="${ENABLE_TUIC:-1}"
  ENABLE_ANYTLS="${ENABLE_ANYTLS:-1}"
  IP_MODE="${IP_MODE:-both}"
}

install_singbox() {
  local_arch="$(uname -m)"
  case "$local_arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7*) arch="armv7" ;;
    *)
      log "[ERROR] 不支持的架构: $local_arch"
      exit 1
      ;;
  esac

  log "[INFO] 安装 sing-box..."
  TMPDIR_SBOX="$(mktemp -d)"

  latest_json="$TMPDIR_SBOX/latest.json"
  curl -fsSL -H 'User-Agent: curl' \
    -o "$latest_json" \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest

  latest="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$latest_json" | head -n 1)"
  [ -n "$latest" ] || {
    log "[ERROR] 获取 sing-box 最新版本失败"
    exit 1
  }

  ver="${latest#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver}-linux-${arch}.tar.gz"

  log "[INFO] 下载 sing-box: $latest ($arch)"
  curl -fL --retry 3 -o "$TMPDIR_SBOX/sing-box.tar.gz" "$url"

  tar -xzf "$TMPDIR_SBOX/sing-box.tar.gz" -C "$TMPDIR_SBOX"

  sb_dir="$(find "$TMPDIR_SBOX" -maxdepth 1 -type d -name "sing-box-${ver}-linux-*" | head -n 1)"
  if [ -z "$sb_dir" ] || [ ! -f "$sb_dir/sing-box" ]; then
    log "[ERROR] 解压 sing-box 失败"
    exit 1
  fi

  install -m 755 "$sb_dir/sing-box" "$SB_BIN"
  log "[INFO] sing-box 已安装到 $SB_BIN"
}

check_singbox_exec() {
  if ! "$SB_BIN" version >/dev/null 2>&1; then
    log "[ERROR] sing-box 已安装但无法执行。"
    log "[ERROR] 若在 Alpine 上运行，请确认已安装 gcompat。"
    exit 1
  fi
}

write_config() {
  mkdir -p "$BASE_DIR"

  ib_file="$BASE_DIR/inbounds.json.tmp"
  ib_fixed="$BASE_DIR/inbounds.fixed.tmp"
  : > "$ib_file"
  listen="$(listen_addr)"

  if [ "$ENABLE_HY2" = "1" ]; then
    cat >> "$ib_file" <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "$listen",
      "listen_port": $HY2_LISTEN_PORT,
      "up_mbps": $HY2_UP_MBPS,
      "down_mbps": $HY2_DOWN_MBPS,
      "users": [
        {
          "password": "$AUTH_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE",
        "alpn": ["h3"]
      }
    },
EOF
  fi

  if [ "$ENABLE_TUIC" = "1" ]; then
    cat >> "$ib_file" <<EOF
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "$listen",
      "listen_port": $TUIC_LISTEN_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "password": "$AUTH_PASS"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE",
        "alpn": ["h3"]
      }
    },
EOF
  fi

  if [ "$ENABLE_ANYTLS" = "1" ]; then
    cat >> "$ib_file" <<EOF
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "$listen",
      "listen_port": $ANYTLS_LISTEN_PORT,
      "users": [
        {
          "password": "$AUTH_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE"
      }
    },
EOF
  fi

  sed '$ s/,$//' "$ib_file" > "$ib_fixed"

  {
    printf '{\n'
    printf '  "log": {\n'
    printf '    "level": "warn",\n'
    printf '    "timestamp": true,\n'
    printf '    "output": "%s"\n' "$LOG_FILE"
    printf '  },\n'
    printf '  "inbounds": [\n'
    cat "$ib_fixed"
    printf '\n  ],\n'
    printf '  "outbounds": [\n'
    printf '    {\n      "type": "direct",\n      "tag": "direct"\n    },\n'
    printf '    {\n      "type": "block",\n      "tag": "block"\n    }\n'
    printf '  ],\n'
    printf '  "route": {\n    "final": "direct"\n  }\n'
    printf '}\n'
  } > "$CONFIG_FILE"

  rm -f "$ib_file" "$ib_fixed"
  chmod 600 "$CONFIG_FILE"
}

write_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=sing-box 3in1（hy2/tuic/Anytls）
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
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
description="sing-box 3in1（hy2/tuic/Anytls）"
command="$SB_BIN"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
  need net
}
EOF
    chmod 755 "$OPENRC_INIT"
  else
    log "[ERROR] 未检测到 systemd 或 OpenRC"
    exit 1
  fi
}

ensure_firewall() {
  # 仅尝试放行本机防火墙；云厂商安全组仍需手动放行
  if have_cmd ufw; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
      if [ "$ENABLE_HY2" = "1" ]; then
        ufw allow "${HY2_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
      fi
      if [ "$ENABLE_TUIC" = "1" ]; then
        ufw allow "${TUIC_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
      fi
      if [ "$ENABLE_ANYTLS" = "1" ]; then
        ufw allow "${ANYTLS_LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
      fi
    fi
  fi

  if have_cmd firewall-cmd; then
    if firewall-cmd --state >/dev/null 2>&1; then
      if [ "$ENABLE_HY2" = "1" ]; then
        firewall-cmd --permanent --add-port="${HY2_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
      fi
      if [ "$ENABLE_TUIC" = "1" ]; then
        firewall-cmd --permanent --add-port="${TUIC_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
      fi
      if [ "$ENABLE_ANYTLS" = "1" ]; then
        firewall-cmd --permanent --add-port="${ANYTLS_LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
      fi
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
}

stop_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl stop sing-box >/dev/null 2>&1 || true
  elif [ "$INIT_STYLE" = "openrc" ]; then
    rc-service sing-box stop >/dev/null 2>&1 || true
  fi
  sleep 1
}

disable_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl disable sing-box >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  elif [ "$INIT_STYLE" = "openrc" ]; then
    rc-update del sing-box default >/dev/null 2>&1 || true
  fi
}

start_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
      log "[ERROR] sing-box 启动失败，查看日志："
      journalctl -u sing-box -e --no-pager || true
      exit 1
    fi
  elif [ "$INIT_STYLE" = "openrc" ]; then
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || true
    sleep 2
    if ! rc-service sing-box status >/dev/null 2>&1; then
      log "[ERROR] sing-box 启动失败，可执行：rc-service sing-box status"
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
    if ! systemctl restart sing-box >/dev/null 2>&1; then
      log "[ERROR] sing-box 重启失败，查看日志："
      journalctl -u sing-box -e --no-pager || true
      exit 1
    fi
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
      log "[ERROR] sing-box 重启后未处于 active 状态，查看日志："
      journalctl -u sing-box -e --no-pager || true
      exit 1
    fi
  elif [ "$INIT_STYLE" = "openrc" ]; then
    if ! rc-service sing-box restart >/dev/null 2>&1; then
      log "[ERROR] sing-box 重启失败，可执行：rc-service sing-box status"
      exit 1
    fi
    sleep 2
    if ! rc-service sing-box status >/dev/null 2>&1; then
      log "[ERROR] sing-box 重启后状态异常，可执行：rc-service sing-box status"
      exit 1
    fi
  else
    log "[ERROR] 未检测到可用服务管理器"
    exit 1
  fi
}

emit_hy2() {
  host="$1"
  kind="$2"
  hp="$(fmt_hostport "$host" "$HY2_LISTEN_PORT")"
  printf '%s\n' "hysteria2://$AUTH_PASS@$hp?sni=$SNI_HOST&alpn=h3&insecure=1&allowInsecure=1#HY2_$kind"
}

emit_tuic() {
  host="$1"
  kind="$2"
  hp="$(fmt_hostport "$host" "$TUIC_LISTEN_PORT")"
  userinfo="${UUID}%3A${AUTH_PASS}"
  printf '%s\n' "tuic://$userinfo@$hp?sni=$SNI_HOST&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#TUIC_$kind"
}

emit_anytls() {
  host="$1"
  kind="$2"
  hp="$(fmt_hostport "$host" "$ANYTLS_LISTEN_PORT")"
  kind_lc="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "anytls://$AUTH_PASS@$hp?security=tls&insecure=1&allowInsecure=1&type=tcp#AnyTLS_${kind_lc}"
}

show_node_set() {
  host="$1"
  label="$2"
  printf '\n[%s]\n' "$label"
  if [ "$ENABLE_HY2" = "1" ]; then
    emit_hy2 "$host" "$label"
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    emit_tuic "$host" "$label"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    emit_anytls "$host" "$label"
  fi
}

show_nodes() {
  load_state || true
  detect_public_ips
  printf '\n%s\n' "===== 节点信息 ====="
  printf '协议：%s\n' "$(show_protocol_status)"
  printf '网络：%s\n' "$(ip_mode_label)"
  if [ -n "$PUBLIC_IPV4" ] && stack_selected "V4"; then
    show_node_set "$PUBLIC_IPV4" "V4"
  fi
  if [ -n "$PUBLIC_IPV6" ] && stack_selected "V6"; then
    show_node_set "$PUBLIC_IPV6" "V6"
  fi
  if [ "$IP_MODE" = "4" ] && [ -z "$PUBLIC_IPV4" ]; then
    log "[WARN] 未检测到公网 IPv4"
  elif [ "$IP_MODE" = "6" ] && [ -z "$PUBLIC_IPV6" ]; then
    log "[WARN] 未检测到公网 IPv6"
  elif [ "$IP_MODE" = "both" ] && [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; then
    log "[WARN] 未检测到公网 IPv4/IPv6"
  fi
  printf '\n'
}

fresh_install() {
  prompt_protocols || {
    log "[INFO] 已取消安装"
    exit 0
  }
  prompt_ip_mode || {
    log "[INFO] 已取消安装"
    exit 0
  }

  pkg_install
  install_singbox
  check_singbox_exec

  log "[INFO] 正在检测公网 IPv4/IPv6..."
  detect_public_ips
  log "[INFO] 检测到公网 IPv4: ${PUBLIC_IPV4:-未检测到}"
  log "[INFO] 检测到公网 IPv6: ${PUBLIC_IPV6:-未检测到}"

  printf '\n%s\n' "===== 第三步：配置各协议端口 =====" >&2
  prompt_all_ports

  gen_creds
  gen_cert
  save_state
  write_config
  write_service
  ensure_firewall

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 启动服务..."
  start_service

  show_nodes
}

reset_ports() {
  load_state

  stop_service
  printf '\n%s\n' "===== 重置已启用协议的端口 =====" >&2
  prompt_all_ports

  save_state
  write_config
  ensure_firewall

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 重启服务..."
  start_service

  show_nodes
}

change_settings() {
  load_state || true

  prompt_protocols || {
    log "[INFO] 已取消"
    return 0
  }
  prompt_ip_mode || {
    log "[INFO] 已取消"
    return 0
  }

  printf '\n%s\n' "===== 配置新启用协议的端口 =====" >&2
  prompt_missing_ports

  save_state
  write_config
  ensure_firewall

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 重启服务..."
  restart_service

  show_nodes
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

reinstall_all() {
  uninstall_all
  fresh_install
}

menu_loop() {
  load_state || true

  while :; do
    printf '\n%s\n' "===== sing-box 3in1（hy2/tuic/Anytls）管理脚本 ====="
    printf '当前协议：%s\n' "$(show_protocol_status)"
    printf '当前网络：%s\n' "$(ip_mode_label)"
    printf '%s\n' "1) 重装（重新选择协议与 IP 栈）"
    printf '%s\n' "2) 卸载"
    printf '%s\n' "3) 重置端口"
    printf '%s\n' "4) 重启服务"
    printf '%s\n' "5) 查看节点"
    printf '%s\n' "6) 修改协议 / IP 栈"
    printf '%s\n' "0) 退出"
    printf '%s' "请选择 [0-6]: " >&2

    IFS= read -r choice || choice=""

    case "$choice" in
      1)
        log "[INFO] 开始重新安装..."
        reinstall_all
        exit 0
        ;;
      2)
        log "[INFO] 开始卸载..."
        uninstall_all
        printf '%s\n' "[INFO] 已卸载"
        exit 0
        ;;
      3)
        reset_ports
        ;;
      4)
        log "[INFO] 重启服务..."
        restart_service
        printf '%s\n' "[INFO] 服务已重启"
        ;;
      5)
        show_nodes
        ;;
      6)
        change_settings
        ;;
      0|'')
        exit 0
        ;;
      *)
        log "请输入 0-6 之间的选项"
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
  if [ -z "$INIT_STYLE" ]; then
    log "[ERROR] 未检测到 systemd / OpenRC"
    exit 1
  fi

  if is_installed; then
    menu_loop
  else
    fresh_install
  fi
}

main "$@"
