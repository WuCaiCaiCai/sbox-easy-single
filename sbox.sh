#!/bin/sh
# 仅用于合法、授权、合规的环境。使用前请阅读 README 的“免责声明与合规提示”。
set -eu
umask 077

BASE_DIR="/etc/sing-box"
CONFIG_FILE="$BASE_DIR/config.json"
STATE_FILE="$BASE_DIR/state.env"
CERT_FILE="$BASE_DIR/cert.pem"
KEY_FILE="$BASE_DIR/key.pem"
LOG_FILE="$BASE_DIR/info.log"

SB_BIN="/usr/local/bin/sing-box"
SB_LIB_DIR="/usr/local/lib"
SYSTEMD_UNIT="/etc/systemd/system/sing-box.service"
OPENRC_INIT="/etc/init.d/sing-box"

# 协议实现来源：Mieru 需要 mbox（sing-box 的 mieru 分支），其余用上游
SB_REPO_UPSTREAM="SagerNet/sing-box"
SB_REPO_MBOX="enfein/mbox"

HY2_UP_MBPS="${HY2_UP_MBPS:-100}"
HY2_DOWN_MBPS="${HY2_DOWN_MBPS:-100}"

SNI_ENV_SET=0
SNI_ENV_VALUE=""
if [ -n "${SNI_HOST:-}" ]; then
  SNI_ENV_SET=1
  SNI_ENV_VALUE="$SNI_HOST"
else
  SNI_HOST="www.bing.com"
fi
# 内置伪装域名候选（SNI），安装时会自动测速
SNI_CANDIDATES="${SNI_CANDIDATES:-www.bing.com www.microsoft.com www.apple.com www.cloudflare.com www.amazon.com www.github.com www.tesla.com www.icloud.com}"

PUBLIC_IPV4=""
PUBLIC_IPV6=""

INIT_STYLE=""
SERVICE_FILE=""
TMPDIR_SBOX=""

ARCH=""
HOST_ARCH=""
OS_NAME=""
IS_CONTAINER=0
SB_FLAVOR=""

USED_UDP_PORTS=""
USED_TCP_PORTS=""

HY2_LISTEN_PORT=""
TUIC_LISTEN_PORT=""
ANYTLS_LISTEN_PORT=""
MIERU_LISTEN_PORT=""

ENABLE_HY2=0
ENABLE_TUIC=0
ENABLE_ANYTLS=0
ENABLE_MIERU=0
MIERU_TRANSPORT="TCP"
IP_MODE=""

AUTH_PASS=""
UUID=""
MIERU_USER=""
MIERU_PASS=""
NODE_PREFIX="${NODE_PREFIX:-}"

# 可选的中转线路（本机节点默认为直连，中转线路是额外添加的一组节点）
RELAY_NAME=""
RELAY_TYPE="none"
RELAY_HOST=""
RELAY_PORT=""
RELAY_USER=""
RELAY_PASS=""
RELAY_METHOD=""
RELAY_HY2_PORT=""
RELAY_TUIC_PORT=""
RELAY_ANYTLS_PORT=""
RELAY_MIERU_PORT=""

log() { printf '%s\n' "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

read_or_exit() {
  if ! IFS= read -r "$1"; then
    log "[ERROR] 输入已结束（stdin 已关闭）"
    exit 1
  fi
}

shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

LINE_COUNT=0

line_get() {
  eval "printf '%s' \"\${LINE${1}_${2}:-}\""
}

line_set() {
  eval "LINE${1}_${2}=$(shq "$3")"
}

line_clear() {
  for line_field in NAME TYPE HOST PORT USER PASS METHOD HY2_PORT TUIC_PORT ANYTLS_PORT MIERU_PORT; do
    eval "LINE${1}_${line_field}=''"
  done
}

line_compact() {
  line_idx="$1"
  line_i="$line_idx"
  while [ "$line_i" -lt "$LINE_COUNT" ]; do
    line_next=$((line_i + 1))
    for line_field in NAME TYPE HOST PORT USER PASS METHOD HY2_PORT TUIC_PORT ANYTLS_PORT MIERU_PORT; do
      line_set "$line_i" "$line_field" "$(line_get "$line_next" "$line_field")"
    done
    line_i=$((line_i + 1))
  done
  line_clear "$LINE_COUNT"
  LINE_COUNT=$((LINE_COUNT - 1))
}

line_name() {
  line_n="$(line_get "$1" NAME)"
  [ -n "$line_n" ] || line_n="中转$1"
  printf '%s' "$line_n"
}

line_summary() {
  if [ "${LINE_COUNT:-0}" -eq 0 ]; then
    printf '无（仅本机直连节点）'
    return
  fi
  line_i=1
  line_out=""
  while [ "$line_i" -le "$LINE_COUNT" ]; do
    line_out="${line_out:+$line_out / }$(line_name "$line_i")"
    line_i=$((line_i + 1))
  done
  printf '%s' "$line_out"
}

line_node_name() {
  printf '%s_%s' "$(line_name "$1")" "$2"
}

line_reset_scratch() {
  RELAY_NAME=""
  RELAY_TYPE="none"
  RELAY_HOST=""
  RELAY_PORT=""
  RELAY_USER=""
  RELAY_PASS=""
  RELAY_METHOD=""
  RELAY_HY2_PORT=""
  RELAY_TUIC_PORT=""
  RELAY_ANYTLS_PORT=""
  RELAY_MIERU_PORT=""
}

line_load_scratch() {
  line_i="$1"
  RELAY_NAME="$(line_get "$line_i" NAME)"
  RELAY_TYPE="$(line_get "$line_i" TYPE)"
  RELAY_HOST="$(line_get "$line_i" HOST)"
  RELAY_PORT="$(line_get "$line_i" PORT)"
  RELAY_USER="$(line_get "$line_i" USER)"
  RELAY_PASS="$(line_get "$line_i" PASS)"
  RELAY_METHOD="$(line_get "$line_i" METHOD)"
  RELAY_HY2_PORT="$(line_get "$line_i" HY2_PORT)"
  RELAY_TUIC_PORT="$(line_get "$line_i" TUIC_PORT)"
  RELAY_ANYTLS_PORT="$(line_get "$line_i" ANYTLS_PORT)"
  RELAY_MIERU_PORT="$(line_get "$line_i" MIERU_PORT)"
  [ -n "$RELAY_TYPE" ] || RELAY_TYPE="none"
}

line_store_scratch() {
  line_i="$1"
  line_set "$line_i" NAME "$RELAY_NAME"
  line_set "$line_i" TYPE "$RELAY_TYPE"
  line_set "$line_i" HOST "$RELAY_HOST"
  line_set "$line_i" PORT "$RELAY_PORT"
  line_set "$line_i" USER "$RELAY_USER"
  line_set "$line_i" PASS "$RELAY_PASS"
  line_set "$line_i" METHOD "$RELAY_METHOD"
  line_set "$line_i" HY2_PORT "$RELAY_HY2_PORT"
  line_set "$line_i" TUIC_PORT "$RELAY_TUIC_PORT"
  line_set "$line_i" ANYTLS_PORT "$RELAY_ANYTLS_PORT"
  line_set "$line_i" MIERU_PORT "$RELAY_MIERU_PORT"
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

is_installed() {
  [ -f "$STATE_FILE" ] || return 1
  [ -x "$SB_BIN" ] && [ -f "$CONFIG_FILE" ] && [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]
}

singbox_wanted() {
  [ "$ENABLE_HY2" = "1" ] || [ "$ENABLE_TUIC" = "1" ] || [ "$ENABLE_ANYTLS" = "1" ]
}

wanted_flavor() {
  if [ "$ENABLE_MIERU" = "1" ]; then
    printf '%s' "mbox"
  else
    printf '%s' "upstream"
  fi
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

  # NAT64 / 双栈回落时，IPv6 查询可能返回 IPv4 地址，这里做格式校验
  case "$PUBLIC_IPV4" in
    ''|*[!0-9.]*) PUBLIC_IPV4="" ;;
  esac
  case "$PUBLIC_IPV6" in
    *:*) : ;;
    *) PUBLIC_IPV6="" ;;
  esac
}

port_in_use() {
  p="$1"
  proto="$2"
  hex="$(printf '%04X' "$p")"

  case "$proto" in
    udp) files="/proc/net/udp /proc/net/udp6" ;;
    tcp) files="/proc/net/tcp /proc/net/tcp6" ;;
    both)
      if port_in_use "$p" tcp; then
        return 0
      fi
      port_in_use "$p" udp
      return $?
      ;;
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
    both)
      proto_port_selected tcp "$port" || proto_port_selected udp "$port"
      return $?
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
    both)
      USED_UDP_PORTS="$USED_UDP_PORTS $port"
      USED_TCP_PORTS="$USED_TCP_PORTS $port"
      ;;
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
  minp="${3:-1}"
  default="${4:-}"
  while :; do
    if [ -z "$default" ]; then
      default="$(rand_port "$proto")"
    fi
    printf '%s [%s]: ' "$label" "$default" >&2
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="$default"

    case "$ans" in
      ''|*[!0-9]*)
        log "请输入数字"
        default=""
        continue
        ;;
    esac

    if [ "$ans" -lt "$minp" ] || [ "$ans" -gt 65535 ]; then
      log "端口范围必须是 $minp-65535"
      default=""
      continue
    fi

    if port_in_use "$ans" "$proto"; then
      log "端口 $ans 已被本机占用，请重新输入"
      default=""
      continue
    fi

    if proto_port_selected "$proto" "$ans"; then
      log "端口 $ans 与前面同类协议冲突，请重新输入"
      default=""
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
  m=0

  case "$raw" in
    5|all|ALL)
      h=1
      t=1
      a=1
      m=1
      ;;
    *)
      old_ifs="$IFS"
      IFS=','
      for item in $raw; do
        case "$item" in
          1) h=1 ;;
          2) t=1 ;;
          3) a=1 ;;
          4) m=1 ;;
          5) h=1; t=1; a=1; m=1 ;;
          *)
            IFS="$old_ifs"
            return 1
            ;;
        esac
      done
      IFS="$old_ifs"
      ;;
  esac

  if [ "$h" -eq 0 ] && [ "$t" -eq 0 ] && [ "$a" -eq 0 ] && [ "$m" -eq 0 ]; then
    return 1
  fi

  ENABLE_HY2="$h"
  ENABLE_TUIC="$t"
  ENABLE_ANYTLS="$a"
  ENABLE_MIERU="$m"
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
  if [ "$ENABLE_MIERU" = "1" ]; then
    if [ -n "$label" ]; then
      label="$label / Mieru($(mieru_proto_name))"
    else
      label="Mieru($(mieru_proto_name))"
    fi
  fi
  printf '%s' "${label:-无}"
}

prompt_protocols() {
  printf '\n%s\n' "===== 第二步：选择要安装的协议（可多选）=====" >&2
  printf '当前选择：%s\n' "$(show_protocol_status)" >&2
  printf '%s\n' "1) Hysteria2（UDP，sing-box）" >&2
  printf '%s\n' "2) TUIC（UDP，sing-box）" >&2
  printf '%s\n' "3) AnyTLS（TCP，sing-box）" >&2
  printf '%s\n' "4) Mieru（TCP 或 UDP 二选一，需使用 mbox 构建）" >&2
  printf '%s\n' "5) 全部安装（Hysteria2 + TUIC + AnyTLS + Mieru）" >&2
  printf '%s\n' "多选示例：输入 1,4 表示只安装 Hysteria2 和 Mieru" >&2
  printf '%s\n' "0) 取消" >&2

  while :; do
    printf '%s' "请选择 [1/2/3/4/5 或 1,4]: " >&2
    read_or_exit ans
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
      prompt_mieru_transport || return 1
      return 0
    fi
    log "[ERROR] 无效选择，请输入 1-5 或逗号分隔的组合（如 1,4）"
  done
}

mieru_proto_name() {
  case "$MIERU_TRANSPORT" in
    UDP) printf 'UDP' ;;
    *)   printf 'TCP' ;;
  esac
}

mieru_proto_port_kind() {
  case "$MIERU_TRANSPORT" in
    UDP) printf 'udp' ;;
    *)   printf 'tcp' ;;
  esac
}

prompt_mieru_transport() {
  [ "$ENABLE_MIERU" = "1" ] || return 0

  printf '\n%s\n' "===== Mieru 传输协议（每条链接只能一种）=====" >&2
  printf '当前选择：%s\n' "$(mieru_proto_name)" >&2
  printf '%s\n' "1) TCP：兼容性最好，绝大多数网络都能通，被限速/封锁概率低；速度略逊，高延迟线路抖动更明显" >&2
  printf '%s\n' "2) UDP：延迟更低、抗丢包（QUIC 风格），适合游戏 / 语音视频 / HTTP3；部分网络会限速甚至屏蔽 UDP" >&2
  printf '%s\n' "建议：不确定选 TCP；确认运营商/云厂商不封 UDP 且在意延迟再选 UDP" >&2

  while :; do
    printf '请选择 [1/2]: ' >&2
    read_or_exit ans
    case "$ans" in
      '') break ;;
      1) MIERU_TRANSPORT="TCP" ;;
      2) MIERU_TRANSPORT="UDP" ;;
      0) return 1 ;;
      *)
        log "[ERROR] 请输入 1 或 2"
        continue
        ;;
    esac
    break
  done
  log "[INFO] Mieru 传输协议：$MIERU_TRANSPORT"
  return 0
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
  has_v4=0
  has_v6=0
  [ -n "$PUBLIC_IPV4" ] && has_v4=1
  [ -n "$PUBLIC_IPV6" ] && has_v6=1

  if [ "$has_v4" = "1" ] && [ "$has_v6" = "0" ]; then
    IP_MODE="4"
    log "[INFO] 仅检测到公网 IPv4，已自动选择：$(ip_mode_label)"
    return 0
  fi
  if [ "$has_v4" = "0" ] && [ "$has_v6" = "1" ]; then
    IP_MODE="6"
    log "[INFO] 仅检测到公网 IPv6，已自动选择：$(ip_mode_label)"
    return 0
  fi

  printf '\n%s\n' "===== 第三步：选择监听与节点输出的 IP 栈 =====" >&2
  if [ "$has_v4" = "0" ] && [ "$has_v6" = "0" ]; then
    printf '[WARN] 未检测到公网 IPv4/IPv6（可能网络受限或仅内网），请手动选择\n' >&2
  else
    printf '检测结果：IPv4=%s IPv6=%s\n' "${PUBLIC_IPV4:-无}" "${PUBLIC_IPV6:-无}" >&2
  fi
  printf '当前选择：%s\n' "$(ip_mode_label)" >&2
  printf '%s\n' "1) 仅 IPv4" >&2
  printf '%s\n' "2) 仅 IPv6" >&2
  printf '%s\n' "3) 双栈（IPv4 + IPv6）" >&2
  printf '%s\n' "0) 取消" >&2

  while :; do
    printf '%s' "请选择 [1/2/3]: " >&2
    read_or_exit ans
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

mark_all_line_ports() {
  line_i=1
  while [ "$line_i" -le "$LINE_COUNT" ]; do
    line_p="$(line_get "$line_i" HY2_PORT)"
    [ -n "$line_p" ] && proto_port_mark udp "$line_p"
    line_p="$(line_get "$line_i" TUIC_PORT)"
    [ -n "$line_p" ] && proto_port_mark udp "$line_p"
    line_p="$(line_get "$line_i" ANYTLS_PORT)"
    [ -n "$line_p" ] && proto_port_mark tcp "$line_p"
    line_p="$(line_get "$line_i" MIERU_PORT)"
    [ -n "$line_p" ] && proto_port_mark "$(mieru_proto_port_kind)" "$line_p"
    line_i=$((line_i + 1))
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
  if [ "$ENABLE_MIERU" != "1" ]; then
    MIERU_LISTEN_PORT=""
  fi
}

prompt_all_ports() {
  USED_UDP_PORTS=""
  USED_TCP_PORTS=""
  clear_disabled_ports
  mark_all_line_ports

  if [ "$ENABLE_HY2" = "1" ]; then
    HY2_LISTEN_PORT="$(prompt_port '请输入 HY2 端口 (UDP) [回车随机]' udp)"
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    TUIC_LISTEN_PORT="$(prompt_port '请输入 TUIC 端口 (UDP) [回车随机]' udp)"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    ANYTLS_LISTEN_PORT="$(prompt_port '请输入 ANYTLS 端口 (TCP) [回车随机]' tcp)"
  fi
  if [ "$ENABLE_MIERU" = "1" ]; then
    MIERU_LISTEN_PORT="$(prompt_port "请输入 Mieru 端口 ($(mieru_proto_name)) [回车随机]" "$(mieru_proto_port_kind)" 1025)"
  fi
}

prompt_missing_ports() {
  USED_UDP_PORTS=""
  USED_TCP_PORTS=""
  clear_disabled_ports
  mark_all_line_ports

  if [ "$ENABLE_HY2" = "1" ] && [ -n "$HY2_LISTEN_PORT" ]; then
    proto_port_mark udp "$HY2_LISTEN_PORT"
  fi
  if [ "$ENABLE_TUIC" = "1" ] && [ -n "$TUIC_LISTEN_PORT" ]; then
    proto_port_mark udp "$TUIC_LISTEN_PORT"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ] && [ -n "$ANYTLS_LISTEN_PORT" ]; then
    proto_port_mark tcp "$ANYTLS_LISTEN_PORT"
  fi
  if [ "$ENABLE_MIERU" = "1" ] && [ -n "$MIERU_LISTEN_PORT" ]; then
    if proto_port_selected "$(mieru_proto_port_kind)" "$MIERU_LISTEN_PORT"; then
      log "[WARN] Mieru 端口 $MIERU_LISTEN_PORT 与已启用的 $(mieru_proto_name) 协议端口冲突，请重新选择"
      MIERU_LISTEN_PORT=""
    else
      proto_port_mark "$(mieru_proto_port_kind)" "$MIERU_LISTEN_PORT"
    fi
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
  if [ "$ENABLE_MIERU" = "1" ] && [ -z "$MIERU_LISTEN_PORT" ]; then
    MIERU_LISTEN_PORT="$(prompt_port "请输入 Mieru 端口 ($(mieru_proto_name)) [回车随机]" "$(mieru_proto_port_kind)" 1025)"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

b64_encode() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

ss_key_bytes() {
  case "$1" in
    *aes-128*) printf '16' ;;
    *)         printf '32' ;;
  esac
}

ss_key_ok() {
  case "$1" in
    2022-*) ;;
    *) return 0 ;;
  esac
  [ -n "${2:-}" ] || return 1
  ss_len="$(printf '%s' "$2" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  [ "$ss_len" = "$(ss_key_bytes "$1")" ]
}

relay_label() {
  case "$RELAY_TYPE" in
    socks) printf '%s：SOCKS5 %s:%s' "${RELAY_NAME:-中转}" "$RELAY_HOST" "$RELAY_PORT" ;;
    http)  printf '%s：HTTP %s:%s' "${RELAY_NAME:-中转}" "$RELAY_HOST" "$RELAY_PORT" ;;
    ss)    printf '%s：SS2022 %s:%s（%s）' "${RELAY_NAME:-中转}" "$RELAY_HOST" "$RELAY_PORT" "$RELAY_METHOD" ;;
    *)     printf '未添加' ;;
  esac
}

relay_link() {
  [ "$RELAY_TYPE" = "none" ] && return 0
  relay_hp="$(fmt_hostport "$RELAY_HOST" "$RELAY_PORT")"
  if [ -n "$RELAY_USER" ]; then
    relay_auth="$RELAY_USER:$RELAY_PASS@"
  else
    relay_auth=""
  fi
  case "$RELAY_TYPE" in
    socks) printf 'socks5://%s%s' "$relay_auth" "$relay_hp" ;;
    http)  printf 'http://%s%s' "$relay_auth" "$relay_hp" ;;
    ss)    printf 'ss://%s@%s#%s' "$(b64_encode "$RELAY_METHOD:$RELAY_PASS")" "$relay_hp" "${RELAY_NAME:-SS}" ;;
  esac
}

parse_ss_uri() {
  ss_uri="$1"
  ss_uri="${ss_uri#ss://}"

  case "$ss_uri" in
    *'#'*) ss_uri="${ss_uri%%#*}" ;;
  esac
  case "$ss_uri" in
    *'?'*) ss_uri="${ss_uri%%\?*}" ;;
  esac

  if [ "${ss_uri#*@}" = "$ss_uri" ]; then
    ss_decoded="$(printf '%s' "$ss_uri" | base64 -d 2>/dev/null || true)"
    case "$ss_decoded" in
      *@*) ss_uri="$ss_decoded" ;;
      *)
        log "[ERROR] 无法解析 SS 链接（缺少 @host:port）"
        return 1
        ;;
    esac
  fi

  ss_userinfo="${ss_uri%@*}"
  ss_hostport="${ss_uri##*@}"

  case "$ss_userinfo" in
    *:*)
      ss_method="${ss_userinfo%%:*}"
      ss_pass="${ss_userinfo#*:}"
      ;;
    *)
      ss_decoded="$(printf '%s' "$ss_userinfo" | base64 -d 2>/dev/null || true)"
      case "$ss_decoded" in
        *:*)
          ss_method="${ss_decoded%%:*}"
          ss_pass="${ss_decoded#*:}"
          ;;
        *)
          log "[ERROR] SS 链接缺少 method:password"
          return 1
          ;;
      esac
      ;;
  esac

  [ -n "$ss_method" ] || {
    log "[ERROR] SS 加密方式为空"
    return 1
  }
  [ -n "$ss_pass" ] || {
    log "[ERROR] SS 密码为空"
    return 1
  }

  if ! ss_key_ok "$ss_method" "$ss_pass"; then
    log "[WARN] SS2022 密钥长度异常（应为 16 或 32 字节的 base64），请确认链接是否完整"
  fi

  RELAY_TYPE="ss"
  RELAY_METHOD="$ss_method"
  RELAY_PASS="$ss_pass"
  RELAY_USER=""

  case "$ss_hostport" in
    \[*\]:*)
      ss_tmp="${ss_hostport#\[}"
      RELAY_HOST="${ss_tmp%%\]*}"
      RELAY_PORT="${ss_tmp##*\]:}"
      ;;
    \[*\])
      RELAY_HOST="${ss_hostport#\[}"
      RELAY_HOST="${RELAY_HOST%\]}"
      RELAY_PORT=""
      ;;
    *:*)
      RELAY_HOST="${ss_hostport%:*}"
      RELAY_PORT="${ss_hostport##*:}"
      ;;
    *)
      RELAY_HOST="$ss_hostport"
      RELAY_PORT=""
      ;;
  esac
  return 0
}

parse_relay_target() {
  relay_raw="$1"

  case "$relay_raw" in
    ss://*)
      parse_ss_uri "$relay_raw"
      return $?
      ;;
  esac

  case "$relay_raw" in
    *://*)
      relay_scheme="${relay_raw%%://*}"
      relay_rest="${relay_raw#*://}"
      ;;
    *)
      relay_scheme=""
      relay_rest="$relay_raw"
      ;;
  esac
  relay_rest="${relay_rest%%\?*}"
  relay_rest="${relay_rest%%#*}"
  relay_rest="${relay_rest%%/*}"

  case "$relay_scheme" in
    socks|socks5|socks5h) RELAY_TYPE="socks" ;;
    http) RELAY_TYPE="http" ;;
    https)
      log "[ERROR] 暂不支持 https 代理，请填写 socks5:// / http:// / ss://"
      return 1
      ;;
    '')
      : ;;
    *)
      log "[ERROR] 不支持的代理类型: $relay_scheme（支持 socks5:// / http:// / ss://）"
      return 1
      ;;
  esac

  case "$relay_rest" in
    *@*)
      relay_userinfo="${relay_rest%@*}"
      relay_hostport="${relay_rest##*@}"
      case "$relay_userinfo" in
        *:*)
          RELAY_USER="${relay_userinfo%%:*}"
          RELAY_PASS="${relay_userinfo#*:}"
          ;;
        *)
          RELAY_USER="$relay_userinfo"
          RELAY_PASS=""
          ;;
      esac
      ;;
    *)
      relay_hostport="$relay_rest"
      ;;
  esac

  case "$relay_hostport" in
    \[*\]:*)
      relay_tmp="${relay_hostport#\[}"
      RELAY_HOST="${relay_tmp%%\]*}"
      RELAY_PORT="${relay_tmp##*\]:}"
      ;;
    \[*\])
      RELAY_HOST="${relay_hostport#\[}"
      RELAY_HOST="${RELAY_HOST%\]}"
      RELAY_PORT=""
      ;;
    *:*)
      RELAY_HOST="${relay_hostport%:*}"
      RELAY_PORT="${relay_hostport##*:}"
      ;;
    *)
      RELAY_HOST="$relay_hostport"
      RELAY_PORT=""
      ;;
  esac
  return 0
}

prompt_relay_target() {
  if [ -n "$RELAY_HOST" ] && [ -n "$RELAY_PORT" ]; then
    printf '落地地址 [%s:%s]（回车保持当前）: ' "$RELAY_HOST" "$RELAY_PORT" >&2
  else
    case "$RELAY_TYPE" in
      ss) printf '落地地址（粘贴 ss:// 链接，或 host:port）: ' >&2 ;;
      *)  printf '落地地址（host:port，或粘贴 socks5://user:pass@host:port）: ' >&2 ;;
    esac
  fi
  read_or_exit ans

  if [ -z "$ans" ]; then
    [ -n "$RELAY_HOST" ] && [ -n "$RELAY_PORT" ] && return 0
    log "[ERROR] 地址不能为空"
    return 1
  fi

  relay_had_auth=0
  case "$ans" in
    *@*) relay_had_auth=1 ;;
  esac

  parse_relay_target "$ans" || return 1

  [ -n "$RELAY_HOST" ] || {
    log "[ERROR] 未能解析出落地地址"
    return 1
  }

  while :; do
    if [ -z "$RELAY_PORT" ]; then
      printf '落地端口: ' >&2
      read_or_exit RELAY_PORT
    fi
    case "$RELAY_PORT" in
      ''|*[!0-9]*)
        log "[ERROR] 端口必须是数字"
        RELAY_PORT=""
        continue
        ;;
    esac
    if [ "$RELAY_PORT" -lt 1 ] || [ "$RELAY_PORT" -gt 65535 ]; then
      log "[ERROR] 端口范围必须是 1-65535"
      RELAY_PORT=""
      continue
    fi
    break
  done

  if [ "$RELAY_TYPE" = "ss" ]; then
    if [ -z "$RELAY_METHOD" ]; then
      printf 'SS 加密方式 [2022-blake3-aes-128-gcm]: ' >&2
      read_or_exit RELAY_METHOD
      [ -n "$RELAY_METHOD" ] || RELAY_METHOD="2022-blake3-aes-128-gcm"
    fi
    while :; do
      if [ -z "$RELAY_PASS" ]; then
        printf 'SS 密码（landing.sh 输出里的那串 base64）: ' >&2
        read_or_exit RELAY_PASS
      fi
      if ss_key_ok "$RELAY_METHOD" "$RELAY_PASS"; then
        break
      fi
      log "[ERROR] $RELAY_METHOD 的密码必须是 $(ss_key_bytes "$RELAY_METHOD") 字节的 base64，请重新输入"
      RELAY_PASS=""
    done
    return 0
  fi

  if [ "$relay_had_auth" = "0" ]; then
    printf '落地用户名（留空表示无认证）: ' >&2
    read_or_exit RELAY_USER
    if [ -n "$RELAY_USER" ]; then
      printf '落地密码（留空表示无密码）: ' >&2
      read_or_exit RELAY_PASS
    else
      RELAY_PASS=""
    fi
  fi
  return 0
}

prompt_line_name() {
  line_idx="$1"
  line_def="${RELAY_NAME:-中转$line_idx}"
  printf '中转线路名称（如 TR，可自定义）[%s]: ' "$line_def" >&2
  read_or_exit ans
  ans="$(printf '%s' "$ans" | tr -d '[:space:]#?&/:')"
  RELAY_NAME="${ans:-$line_def}"
}

prompt_line_ports() {
  line_idx="$1"
  line_label_name="${RELAY_NAME:-中转$line_idx}"
  USED_UDP_PORTS=""
  USED_TCP_PORTS=""

  if [ "$ENABLE_HY2" = "1" ] && [ -n "$HY2_LISTEN_PORT" ]; then
    proto_port_mark udp "$HY2_LISTEN_PORT"
  fi
  if [ "$ENABLE_TUIC" = "1" ] && [ -n "$TUIC_LISTEN_PORT" ]; then
    proto_port_mark udp "$TUIC_LISTEN_PORT"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ] && [ -n "$ANYTLS_LISTEN_PORT" ]; then
    proto_port_mark tcp "$ANYTLS_LISTEN_PORT"
  fi
  if [ "$ENABLE_MIERU" = "1" ] && [ -n "$MIERU_LISTEN_PORT" ]; then
    if proto_port_selected "$(mieru_proto_port_kind)" "$MIERU_LISTEN_PORT"; then
      log "[WARN] Mieru 端口 $MIERU_LISTEN_PORT 与已启用的 $(mieru_proto_name) 协议端口冲突，请重新选择"
      MIERU_LISTEN_PORT=""
    else
      proto_port_mark "$(mieru_proto_port_kind)" "$MIERU_LISTEN_PORT"
    fi
  fi

  line_j=1
  while [ "$line_j" -le "$LINE_COUNT" ]; do
    if [ "$line_j" -ne "$line_idx" ]; then
      line_p="$(line_get "$line_j" HY2_PORT)"
      [ -n "$line_p" ] && proto_port_mark udp "$line_p"
      line_p="$(line_get "$line_j" TUIC_PORT)"
      [ -n "$line_p" ] && proto_port_mark udp "$line_p"
      line_p="$(line_get "$line_j" ANYTLS_PORT)"
      [ -n "$line_p" ] && proto_port_mark tcp "$line_p"
      line_p="$(line_get "$line_j" MIERU_PORT)"
      [ -n "$line_p" ] && proto_port_mark "$(mieru_proto_port_kind)" "$line_p"
    fi
    line_j=$((line_j + 1))
  done

  if [ "$ENABLE_HY2" = "1" ]; then
    RELAY_HY2_PORT="$(prompt_port "请输入 $line_label_name 的 HY2 端口 (UDP) [回车随机]" udp 1 "$RELAY_HY2_PORT")"
  else
    RELAY_HY2_PORT=""
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    RELAY_TUIC_PORT="$(prompt_port "请输入 $line_label_name 的 TUIC 端口 (UDP) [回车随机]" udp 1 "$RELAY_TUIC_PORT")"
  else
    RELAY_TUIC_PORT=""
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    RELAY_ANYTLS_PORT="$(prompt_port "请输入 $line_label_name 的 AnyTLS 端口 (TCP) [回车随机]" tcp 1 "$RELAY_ANYTLS_PORT")"
  else
    RELAY_ANYTLS_PORT=""
  fi
  if [ "$ENABLE_MIERU" = "1" ]; then
    RELAY_MIERU_PORT="$(prompt_port "请输入 $line_label_name 的 Mieru 端口 ($(mieru_proto_name)) [回车随机]" "$(mieru_proto_port_kind)" 1025 "$RELAY_MIERU_PORT")"
  else
    RELAY_MIERU_PORT=""
  fi
}

prompt_relay() {
  line_idx="$1"
  printf '\n%s\n' "===== 中转线路配置 =====" >&2
  printf '提示：落地机可运行同仓库的 landing.sh，一键生成 SOCKS5 / HTTP / SS2022。\n' >&2
  if [ "$RELAY_TYPE" != "none" ]; then
    printf '当前：%s\n' "$(relay_label)" >&2
  fi

  prompt_line_name "$line_idx"

  printf '%s\n' \
    "1) SOCKS5 落地（明文）" \
    "2) HTTP 落地（明文，仅 TCP）" \
    "3) SS2022 落地（加密，推荐）" \
    "0) 取消" >&2
  while :; do
    case "$RELAY_TYPE" in
      http) relay_def=2 ;;
      ss)   relay_def=3 ;;
      *)    relay_def=1 ;;
    esac
    printf '请选择落地类型 [1/2/3，回车=%s]: ' "$relay_def" >&2
    read_or_exit ans
    [ -z "$ans" ] && ans="$relay_def"
    case "$ans" in
      1|2|3) break ;;
      0) return 1 ;;
      *) log "[ERROR] 请输入 1、2、3 或 0" ;;
    esac
  done

  relay_new_type="socks"
  [ "$ans" = "2" ] && relay_new_type="http"
  [ "$ans" = "3" ] && relay_new_type="ss"
  if [ "$RELAY_TYPE" != "$relay_new_type" ]; then
    RELAY_HOST=""
    RELAY_PORT=""
    RELAY_USER=""
    RELAY_PASS=""
    RELAY_METHOD=""
  fi
  RELAY_TYPE="$relay_new_type"

  prompt_relay_target || return 1
  prompt_line_ports "$line_idx"

  log "[INFO] 中转线路：$(relay_label)"
  [ "$RELAY_TYPE" = "http" ] && log "[WARN] HTTP 落地仅支持 TCP，通过该线路的 UDP 流量会失败"
  return 0
}

relay_probe_ss() {
  if [ ! -x "$SB_BIN" ]; then
    log "[WARN] 找不到 sing-box，跳过 SS2022 链路测试"
    return 0
  fi

  probe_dir="$(mktemp -d)"
  probe_port="$(rand_port tcp)"

  cat > "$probe_dir/config.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    { "type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": $probe_port }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "out",
      "server": "$(json_escape "$RELAY_HOST")",
      "server_port": $RELAY_PORT,
      "method": "$(json_escape "$RELAY_METHOD")",
      "password": "$(json_escape "$RELAY_PASS")"
    }
  ],
  "route": { "final": "out" }
}
EOF

  if ! "$SB_BIN" check -c "$probe_dir/config.json" >/dev/null 2>&1; then
    log "[WARN] SS2022 测试配置无效，跳过测试"
    rm -rf "$probe_dir"
    return 0
  fi

  log "[INFO] 测试 SS2022 落地连通性..."
  "$SB_BIN" run -c "$probe_dir/config.json" >/dev/null 2>&1 &
  probe_pid=$!
  sleep 1

  probe_ok=1
  if curl -fsS --max-time 10 --socks5-hostname "127.0.0.1:$probe_port" https://ip.sb >/dev/null 2>&1; then
    probe_ok=0
  fi

  kill "$probe_pid" >/dev/null 2>&1 || true
  wait "$probe_pid" >/dev/null 2>&1 || true
  rm -rf "$probe_dir"

  if [ "$probe_ok" = "0" ]; then
    log "[INFO] 落地代理可用"
    return 0
  fi

  log "[WARN] 无法通过 SS2022 落地访问外网，请检查 method / 密码 / 端口 / 落地白名单"
  return 1
}

relay_probe() {
  [ "$RELAY_TYPE" = "none" ] && return 0
  if [ "$RELAY_TYPE" = "ss" ]; then
    relay_probe_ss
    return $?
  fi

  relay_hp="$(fmt_hostport "$RELAY_HOST" "$RELAY_PORT")"
  case "$RELAY_TYPE" in
    socks) relay_proxy="socks5h://$relay_hp" ;;
    http)  relay_proxy="http://$relay_hp" ;;
    *) return 0 ;;
  esac

  log "[INFO] 测试落地代理连通性..."
  if [ -n "$RELAY_USER" ]; then
    if curl -fsS --max-time 10 --proxy "$relay_proxy" \
      --proxy-user "$RELAY_USER:$RELAY_PASS" https://ip.sb >/dev/null 2>&1; then
      log "[INFO] 落地代理可用"
      return 0
    fi
  else
    if curl -fsS --max-time 10 --proxy "$relay_proxy" https://ip.sb >/dev/null 2>&1; then
      log "[INFO] 落地代理可用"
      return 0
    fi
  fi

  log "[WARN] 无法通过落地代理访问外网，请检查地址、认证、落地白名单或目标限制"
  return 1
}

prompt_missing_line_ports() {
  [ "$LINE_COUNT" -gt 0 ] || return 0

  line_i=1
  while [ "$line_i" -le "$LINE_COUNT" ]; do
    [ "$ENABLE_HY2" = "1" ] || line_set "$line_i" HY2_PORT ""
    [ "$ENABLE_TUIC" = "1" ] || line_set "$line_i" TUIC_PORT ""
    [ "$ENABLE_ANYTLS" = "1" ] || line_set "$line_i" ANYTLS_PORT ""
    [ "$ENABLE_MIERU" = "1" ] || line_set "$line_i" MIERU_PORT ""
    line_i=$((line_i + 1))
  done

  USED_UDP_PORTS=""
  USED_TCP_PORTS=""

  if [ "$ENABLE_HY2" = "1" ] && [ -n "$HY2_LISTEN_PORT" ]; then
    proto_port_mark udp "$HY2_LISTEN_PORT"
  fi
  if [ "$ENABLE_TUIC" = "1" ] && [ -n "$TUIC_LISTEN_PORT" ]; then
    proto_port_mark udp "$TUIC_LISTEN_PORT"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ] && [ -n "$ANYTLS_LISTEN_PORT" ]; then
    proto_port_mark tcp "$ANYTLS_LISTEN_PORT"
  fi
  if [ "$ENABLE_MIERU" = "1" ] && [ -n "$MIERU_LISTEN_PORT" ]; then
    if proto_port_selected "$(mieru_proto_port_kind)" "$MIERU_LISTEN_PORT"; then
      log "[WARN] Mieru 端口 $MIERU_LISTEN_PORT 与已启用的 $(mieru_proto_name) 协议端口冲突，请重新选择"
      MIERU_LISTEN_PORT=""
    else
      proto_port_mark "$(mieru_proto_port_kind)" "$MIERU_LISTEN_PORT"
    fi
  fi

  line_j=1
  while [ "$line_j" -le "$LINE_COUNT" ]; do
    line_p="$(line_get "$line_j" HY2_PORT)"
    [ -n "$line_p" ] && proto_port_mark udp "$line_p"
    line_p="$(line_get "$line_j" TUIC_PORT)"
    [ -n "$line_p" ] && proto_port_mark udp "$line_p"
    line_p="$(line_get "$line_j" ANYTLS_PORT)"
    [ -n "$line_p" ] && proto_port_mark tcp "$line_p"
    line_p="$(line_get "$line_j" MIERU_PORT)"
    if [ -n "$line_p" ]; then
      if proto_port_selected "$(mieru_proto_port_kind)" "$line_p"; then
        log "[WARN] 线路 $(line_name "$line_j") 的 Mieru 端口 $line_p 与已启用协议冲突，请重新选择"
        line_set "$line_j" MIERU_PORT ""
      else
        proto_port_mark "$(mieru_proto_port_kind)" "$line_p"
      fi
    fi
    line_j=$((line_j + 1))
  done

  line_i=1
  while [ "$line_i" -le "$LINE_COUNT" ]; do
    line_label_name="$(line_name "$line_i")"

    if [ "$ENABLE_HY2" = "1" ] && [ -z "$(line_get "$line_i" HY2_PORT)" ]; then
      line_p="$(prompt_port "请输入 $line_label_name 的 HY2 端口 (UDP) [回车随机]" udp)"
      line_set "$line_i" HY2_PORT "$line_p"
    fi
    if [ "$ENABLE_TUIC" = "1" ] && [ -z "$(line_get "$line_i" TUIC_PORT)" ]; then
      line_p="$(prompt_port "请输入 $line_label_name 的 TUIC 端口 (UDP) [回车随机]" udp)"
      line_set "$line_i" TUIC_PORT "$line_p"
    fi
    if [ "$ENABLE_ANYTLS" = "1" ] && [ -z "$(line_get "$line_i" ANYTLS_PORT)" ]; then
      line_p="$(prompt_port "请输入 $line_label_name 的 AnyTLS 端口 (TCP) [回车随机]" tcp)"
      line_set "$line_i" ANYTLS_PORT "$line_p"
    fi
    if [ "$ENABLE_MIERU" = "1" ] && [ -z "$(line_get "$line_i" MIERU_PORT)" ]; then
      line_p="$(prompt_port "请输入 $line_label_name 的 Mieru 端口 ($(mieru_proto_name)) [回车随机]" "$(mieru_proto_port_kind)" 1025)"
      line_set "$line_i" MIERU_PORT "$line_p"
    fi

    line_i=$((line_i + 1))
  done
}

prompt_node_name() {
  cur="${NODE_PREFIX:-}"
  if [ -n "$cur" ]; then
    printf '本机节点名称前缀 [%s]（回车保持，输入 - 清除）: ' "$cur" >&2
  else
    printf '本机节点名称前缀（链接 # 后的内容，回车使用默认名）: ' >&2
  fi
  IFS= read -r ans || ans=""
  case "$ans" in
    '')
      : ;;
    -)
      NODE_PREFIX="" ;;
    *)
      NODE_PREFIX="$(printf '%s' "$ans" | tr -d '[:space:]#?&/:')" ;;
  esac
  if [ -n "$NODE_PREFIX" ]; then
    log "[INFO] 本机节点名称示例：$(node_name "$(node_example_label)")"
  else
    log "[INFO] 本机节点使用默认名称（如 HY2_V4）"
  fi
}

sni_by_index() {
  sni_i=0
  for sni_d in $SNI_CANDIDATES; do
    sni_i=$((sni_i + 1))
    if [ "$sni_i" -eq "$1" ]; then
      printf '%s' "$sni_d"
      return 0
    fi
  done
  return 1
}

probe_sni() {
  sni_dir="$(mktemp -d)"
  sni_i=0
  for sni_d in $SNI_CANDIDATES; do
    sni_i=$((sni_i + 1))
    (
      sni_t="$(curl -o /dev/null -sS -k --connect-timeout 2 --max-time 4 \
        -w '%{time_appconnect}' "https://$sni_d" 2>/dev/null)" || sni_t=""
      case "$sni_t" in
        ''|0|0.000000) sni_t="" ;;
      esac
      printf '%s' "$sni_t" > "$sni_dir/$sni_i"
    ) &
  done
  wait || true
}

show_sni_probe() {
  sni_i=0
  for sni_d in $SNI_CANDIDATES; do
    sni_i=$((sni_i + 1))
    sni_t="$(cat "$sni_dir/$sni_i" 2>/dev/null || true)"
    if [ -n "$sni_t" ]; then
      sni_ms="$(awk -v t="$sni_t" 'BEGIN { printf "%d", t * 1000 }')"
      printf '  %d) %-22s %4s ms\n' "$sni_i" "$sni_d" "$sni_ms" >&2
    else
      printf '  %d) %-22s 不可用\n' "$sni_i" "$sni_d" >&2
    fi
  done
}

best_sni_from_probe() {
  sni_best=""
  sni_best_t=""
  sni_i=0
  for sni_d in $SNI_CANDIDATES; do
    sni_i=$((sni_i + 1))
    sni_t="$(cat "$sni_dir/$sni_i" 2>/dev/null || true)"
    [ -n "$sni_t" ] || continue
    if [ -z "$sni_best_t" ] || awk -v a="$sni_t" -v b="$sni_best_t" 'BEGIN { exit !(a < b) }'; then
      sni_best="$sni_d"
      sni_best_t="$sni_t"
    fi
  done
  [ -n "$sni_best" ] || sni_best="$(sni_by_index 1)"
}

prompt_custom_sni() {
  printf '请输入自定义域名（如 www.example.com，不要带 https://）: ' >&2
  IFS= read -r ans || ans=""
  ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
  case "$ans" in
    ''|.*|*..*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-]*)
      log "[ERROR] 域名格式不正确"
      return 1
      ;;
    *.*)
      SNI_HOST="$ans"
      return 0
      ;;
    *)
      log "[ERROR] 域名格式不正确"
      return 1
      ;;
  esac
}

prompt_sni() {
  printf '正在测试内置伪装域名延迟（约 4 秒）...\n' >&2
  probe_sni
  show_sni_probe
  best_sni_from_probe
  rm -rf "$sni_dir"
  sni_dir=""

  printf '最快：%s\n' "$sni_best" >&2
  if [ -n "${SNI_HOST:-}" ]; then
    printf '当前：%s（回车将改用最快域名）\n' "$SNI_HOST" >&2
  fi

  while :; do
    printf '请选择 [回车=使用最快 / 序号 / 0=自定义]: ' >&2
    IFS= read -r ans || ans=""
    case "$ans" in
      '')
        SNI_HOST="$sni_best"
        break
        ;;
      0)
        prompt_custom_sni || continue
        break
        ;;
      *[!0-9]*)
        log "[ERROR] 请输入序号、0 或直接回车"
        continue
        ;;
    esac
    if [ "$ans" -ge 1 ] && [ "$ans" -le "$sni_i" ]; then
      SNI_HOST="$(sni_by_index "$ans")"
      break
    fi
    log "[ERROR] 序号超出范围"
  done
  log "[INFO] 已选择 SNI：$SNI_HOST"
}

gen_creds() {
  AUTH_PASS="$(openssl rand -hex 4)"
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  MIERU_USER="$(openssl rand -hex 3)"
  MIERU_PASS="$(openssl rand -hex 8)"
}

gen_missing_creds() {
  [ -n "$AUTH_PASS" ] || AUTH_PASS="$(openssl rand -hex 4)"
  [ -n "$UUID" ] || UUID="$(cat /proc/sys/kernel/random/uuid)"
  [ -n "$MIERU_USER" ] || MIERU_USER="$(openssl rand -hex 3)"
  [ -n "$MIERU_PASS" ] || MIERU_PASS="$(openssl rand -hex 8)"
}

ensure_cert() {
  singbox_wanted || return 0
  [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && return 0
  gen_cert
}

gen_cert() {
  if ! singbox_wanted; then
    log "[INFO] 当前未启用需要 TLS 的协议，跳过证书生成"
    return 0
  fi

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
  {
    cat <<EOF
SNI_HOST=$(shq "$SNI_HOST")
HY2_UP_MBPS=$(shq "$HY2_UP_MBPS")
HY2_DOWN_MBPS=$(shq "$HY2_DOWN_MBPS")
IP_MODE=$(shq "$IP_MODE")
ENABLE_HY2=$(shq "$ENABLE_HY2")
ENABLE_TUIC=$(shq "$ENABLE_TUIC")
ENABLE_ANYTLS=$(shq "$ENABLE_ANYTLS")
ENABLE_MIERU=$(shq "$ENABLE_MIERU")
HY2_LISTEN_PORT=$(shq "$HY2_LISTEN_PORT")
TUIC_LISTEN_PORT=$(shq "$TUIC_LISTEN_PORT")
ANYTLS_LISTEN_PORT=$(shq "$ANYTLS_LISTEN_PORT")
MIERU_LISTEN_PORT=$(shq "$MIERU_LISTEN_PORT")
AUTH_PASS=$(shq "$AUTH_PASS")
UUID=$(shq "$UUID")
MIERU_USER=$(shq "$MIERU_USER")
MIERU_PASS=$(shq "$MIERU_PASS")
MIERU_TRANSPORT=$(shq "$MIERU_TRANSPORT")
NODE_PREFIX=$(shq "${NODE_PREFIX:-}")
SB_FLAVOR=$(shq "${SB_FLAVOR:-}")
LINE_COUNT=$(shq "$LINE_COUNT")
EOF

    line_i=1
    while [ "$line_i" -le "$LINE_COUNT" ]; do
      printf 'LINE%d_NAME=%s\n' "$line_i" "$(shq "$(line_get "$line_i" NAME)")"
      printf 'LINE%d_TYPE=%s\n' "$line_i" "$(shq "$(line_get "$line_i" TYPE)")"
      printf 'LINE%d_HOST=%s\n' "$line_i" "$(shq "$(line_get "$line_i" HOST)")"
      printf 'LINE%d_PORT=%s\n' "$line_i" "$(shq "$(line_get "$line_i" PORT)")"
      printf 'LINE%d_USER=%s\n' "$line_i" "$(shq "$(line_get "$line_i" USER)")"
      printf 'LINE%d_PASS=%s\n' "$line_i" "$(shq "$(line_get "$line_i" PASS)")"
      printf 'LINE%d_METHOD=%s\n' "$line_i" "$(shq "$(line_get "$line_i" METHOD)")"
      printf 'LINE%d_HY2_PORT=%s\n' "$line_i" "$(shq "$(line_get "$line_i" HY2_PORT)")"
      printf 'LINE%d_TUIC_PORT=%s\n' "$line_i" "$(shq "$(line_get "$line_i" TUIC_PORT)")"
      printf 'LINE%d_ANYTLS_PORT=%s\n' "$line_i" "$(shq "$(line_get "$line_i" ANYTLS_PORT)")"
      printf 'LINE%d_MIERU_PORT=%s\n' "$line_i" "$(shq "$(line_get "$line_i" MIERU_PORT)")"
      line_i=$((line_i + 1))
    done
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || return 1
  . "$STATE_FILE"
  ENABLE_HY2="${ENABLE_HY2:-1}"
  ENABLE_TUIC="${ENABLE_TUIC:-1}"
  ENABLE_ANYTLS="${ENABLE_ANYTLS:-1}"
  ENABLE_MIERU="${ENABLE_MIERU:-0}"
  MIERU_TRANSPORT="${MIERU_TRANSPORT:-TCP}"
  case "$MIERU_TRANSPORT" in
    TCP|tcp) MIERU_TRANSPORT="TCP" ;;
    UDP|udp) MIERU_TRANSPORT="UDP" ;;
    *)       MIERU_TRANSPORT="TCP" ;;
  esac
  SB_FLAVOR="${SB_FLAVOR:-}"
  NODE_PREFIX="${NODE_PREFIX:-}"
  LINE_COUNT="${LINE_COUNT:-0}"
  case "$LINE_COUNT" in
    ''|*[!0-9]*) LINE_COUNT=0 ;;
  esac
  IP_MODE="${IP_MODE:-both}"
}

install_singbox() {
  if [ -z "$ARCH" ]; then
    detect_arch
  fi

  want_flavor="$(wanted_flavor)"
  case "$want_flavor" in
    mbox)
      repo="$SB_REPO_MBOX"
      flavor_label="mbox（含 Mieru 支持）"
      ;;
    *)
      repo="$SB_REPO_UPSTREAM"
      flavor_label="官方 sing-box"
      ;;
  esac

  log "[INFO] 安装 $flavor_label（$ARCH）..."
  TMPDIR_SBOX="$(mktemp -d)"

  latest_json="$TMPDIR_SBOX/latest.json"
  curl -fsSL -H 'User-Agent: curl' \
    -o "$latest_json" \
    "https://api.github.com/repos/${repo}/releases/latest"

  latest="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$latest_json" | head -n 1)"
  [ -n "$latest" ] || {
    log "[ERROR] 获取 $repo 最新版本失败"
    exit 1
  }

  ver="${latest#v}"
  url="https://github.com/${repo}/releases/download/${latest}/sing-box-${ver}-linux-${ARCH}.tar.gz"

  log "[INFO] 下载 $flavor_label: $latest ($ARCH)"
  curl -fL --retry 3 --retry-all-errors -o "$TMPDIR_SBOX/sing-box.tar.gz" "$url"

  tar -xzf "$TMPDIR_SBOX/sing-box.tar.gz" -C "$TMPDIR_SBOX"

  sb_dir="$(find "$TMPDIR_SBOX" -maxdepth 1 -type d -name "sing-box-${ver}-linux-*" | head -n 1)"
  if [ -z "$sb_dir" ] || [ ! -f "$sb_dir/sing-box" ]; then
    log "[ERROR] 解压 sing-box 失败"
    exit 1
  fi

  install -m 755 "$sb_dir/sing-box" "$SB_BIN"

  # 1.13+ 为动态链接版本，附带 libcronet.so（可选功能通过 dlopen 使用）
  if [ -f "$sb_dir/libcronet.so" ]; then
    mkdir -p "$SB_LIB_DIR"
    install -m 644 "$sb_dir/libcronet.so" "$SB_LIB_DIR/libcronet.so"
    if have_cmd ldconfig; then
      ldconfig >/dev/null 2>&1 || true
    fi
  fi

  rm -rf "$TMPDIR_SBOX"
  TMPDIR_SBOX=""
  SB_FLAVOR="$want_flavor"
  log "[INFO] sing-box 已安装到 $SB_BIN（$flavor_label $latest）"
}

ensure_singbox_flavor() {
  want_flavor="$(wanted_flavor)"
  current="${SB_FLAVOR:-}"
  if [ -z "$current" ] && [ -x "$SB_BIN" ]; then
    # 旧版本脚本装的都是官方 sing-box
    current="upstream"
  fi
  if [ "$want_flavor" = "$current" ] && [ -x "$SB_BIN" ]; then
    SB_FLAVOR="$current"
    return 0
  fi
  if [ "$want_flavor" = "mbox" ]; then
    log "[INFO] 启用了 Mieru，切换为 mbox（sing-box + mieru）"
  else
    log "[INFO] 未启用 Mieru，切换回官方 sing-box"
  fi
  install_singbox
  check_singbox_exec
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

append_inbound_hy2() {
  ib_listen="$1"
  ib_port="$2"
  ib_tag="$3"
  cat >> "$ib_file" <<EOF
    {
      "type": "hysteria2",
      "tag": "$ib_tag",
      "listen": "$ib_listen",
      "listen_port": $ib_port,
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
}

append_inbound_tuic() {
  ib_listen="$1"
  ib_port="$2"
  ib_tag="$3"
  cat >> "$ib_file" <<EOF
    {
      "type": "tuic",
      "tag": "$ib_tag",
      "listen": "$ib_listen",
      "listen_port": $ib_port,
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
}

append_inbound_anytls() {
  ib_listen="$1"
  ib_port="$2"
  ib_tag="$3"
  cat >> "$ib_file" <<EOF
    {
      "type": "anytls",
      "tag": "$ib_tag",
      "listen": "$ib_listen",
      "listen_port": $ib_port,
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
}

append_inbound_mieru() {
  ib_listen="$1"
  ib_port="$2"
  ib_tag="$3"
  if [ "${MIERU_TRANSPORT:-TCP}" = "UDP" ]; then
    cat >> "$ib_file" <<EOF
    {
      "type": "mieru",
      "tag": "${ib_tag}-udp",
      "listen": "$ib_listen",
      "listen_port": $ib_port,
      "transport": "UDP",
      "users": [
        {
          "name": "$MIERU_USER",
          "password": "$MIERU_PASS"
        }
      ]
    },
EOF
    return 0
  fi

  cat >> "$ib_file" <<EOF
    {
      "type": "mieru",
      "tag": "${ib_tag}-tcp",
      "listen": "$ib_listen",
      "listen_port": $ib_port,
      "transport": "TCP",
      "users": [
        {
          "name": "$MIERU_USER",
          "password": "$MIERU_PASS"
        }
      ],
      "user_hint_is_mandatory": false,
      "tcp_idle_timeout": 1800
    },
EOF
}

append_relay_outbound() {
  o_type="$1"
  o_host="$2"
  o_port="$3"
  o_user="$4"
  o_pass="$5"
  o_method="$6"
  o_tag="$7"

  if [ "$o_type" = "ss" ]; then
    printf '    {\n'
    printf '      "type": "shadowsocks",\n'
    printf '      "tag": "%s",\n' "$o_tag"
    printf '      "server": "%s",\n' "$(json_escape "$o_host")"
    printf '      "server_port": %s,\n' "$o_port"
    printf '      "method": "%s",\n' "$(json_escape "$o_method")"
    printf '      "password": "%s"\n' "$(json_escape "$o_pass")"
    printf '    },\n'
    return 0
  fi

  printf '    {\n'
  if [ "$o_type" = "socks" ]; then
    printf '      "type": "socks",\n'
  else
    printf '      "type": "http",\n'
  fi
  printf '      "tag": "%s",\n' "$o_tag"
  printf '      "server": "%s",\n' "$(json_escape "$o_host")"
  if [ "$o_type" = "socks" ]; then
    printf '      "server_port": %s,\n' "$o_port"
    printf '      "version": "5"'
  else
    printf '      "server_port": %s' "$o_port"
  fi
  if [ -n "$o_user" ]; then
    printf ',\n      "username": "%s"' "$(json_escape "$o_user")"
    if [ -n "$o_pass" ]; then
      printf ',\n      "password": "%s"' "$(json_escape "$o_pass")"
    fi
  fi
  printf '\n    },\n'
}

write_config() {
  mkdir -p "$BASE_DIR"

  ib_file="$BASE_DIR/inbounds.json.tmp"
  ib_fixed="$BASE_DIR/inbounds.fixed.tmp"
  : > "$ib_file"
  listen="$(listen_addr)"

  if [ "$ENABLE_HY2" = "1" ]; then
    append_inbound_hy2 "$listen" "$HY2_LISTEN_PORT" "hy2"
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    append_inbound_tuic "$listen" "$TUIC_LISTEN_PORT" "tuic"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    append_inbound_anytls "$listen" "$ANYTLS_LISTEN_PORT" "anytls"
  fi
  if [ "$ENABLE_MIERU" = "1" ]; then
    append_inbound_mieru "$listen" "$MIERU_LISTEN_PORT" "mieru"
  fi

  line_i=1
  while [ "$line_i" -le "$LINE_COUNT" ]; do
    if [ "$ENABLE_HY2" = "1" ]; then
      append_inbound_hy2 "$listen" "$(line_get "$line_i" HY2_PORT)" "line${line_i}-hy2"
    fi
    if [ "$ENABLE_TUIC" = "1" ]; then
      append_inbound_tuic "$listen" "$(line_get "$line_i" TUIC_PORT)" "line${line_i}-tuic"
    fi
    if [ "$ENABLE_ANYTLS" = "1" ]; then
      append_inbound_anytls "$listen" "$(line_get "$line_i" ANYTLS_PORT)" "line${line_i}-anytls"
    fi
    if [ "$ENABLE_MIERU" = "1" ]; then
      append_inbound_mieru "$listen" "$(line_get "$line_i" MIERU_PORT)" "line${line_i}-mieru"
    fi
    line_i=$((line_i + 1))
  done

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

    line_i=1
    while [ "$line_i" -le "$LINE_COUNT" ]; do
      append_relay_outbound \
        "$(line_get "$line_i" TYPE)" \
        "$(line_get "$line_i" HOST)" \
        "$(line_get "$line_i" PORT)" \
        "$(line_get "$line_i" USER)" \
        "$(line_get "$line_i" PASS)" \
        "$(line_get "$line_i" METHOD)" \
        "relay${line_i}"
      line_i=$((line_i + 1))
    done

    printf '    {\n      "type": "direct",\n      "tag": "direct"\n    },\n'
    printf '    {\n      "type": "block",\n      "tag": "block"\n    }\n'
    printf '  ],\n'

    if [ "$LINE_COUNT" -gt 0 ]; then
      printf '  "route": {\n'
      printf '    "rules": [\n'
      line_i=1
      while [ "$line_i" -le "$LINE_COUNT" ]; do
        route_tags=""
        if [ "$ENABLE_HY2" = "1" ]; then route_tags="$route_tags \"line${line_i}-hy2\","; fi
        if [ "$ENABLE_TUIC" = "1" ]; then route_tags="$route_tags \"line${line_i}-tuic\","; fi
        if [ "$ENABLE_ANYTLS" = "1" ]; then route_tags="$route_tags \"line${line_i}-anytls\","; fi
        if [ "$ENABLE_MIERU" = "1" ]; then
          if [ "${MIERU_TRANSPORT:-TCP}" = "UDP" ]; then
            route_tags="$route_tags \"line${line_i}-mieru-udp\","
          else
            route_tags="$route_tags \"line${line_i}-mieru-tcp\","
          fi
        fi
        route_tags="${route_tags%,}"
        printf '      {\n'
        printf '        "inbound": [%s],\n' "$route_tags"
        printf '        "outbound": "relay%s"\n' "$line_i"
        if [ "$line_i" -lt "$LINE_COUNT" ]; then
          printf '      },\n'
        else
          printf '      }\n'
        fi
        line_i=$((line_i + 1))
      done
      printf '    ],\n'
      printf '    "final": "direct"\n'
      printf '  }\n'
    else
      printf '  "route": {\n    "final": "direct"\n  }\n'
    fi
    printf '}\n'
  } > "$CONFIG_FILE"

  rm -f "$ib_file" "$ib_fixed"
  chmod 600 "$CONFIG_FILE"
}

write_service() {
  if [ "$INIT_STYLE" = "systemd" ]; then
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=sing-box 多协议服务（hy2/tuic/anytls/mieru）
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
description="sing-box 多协议服务（hy2/tuic/anytls/mieru）"
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
      if [ "$ENABLE_MIERU" = "1" ]; then
        ufw allow "${MIERU_LISTEN_PORT}/$(mieru_proto_port_kind)" >/dev/null 2>&1 || true
      fi

      line_i=1
      while [ "$line_i" -le "$LINE_COUNT" ]; do
        if [ "$ENABLE_HY2" = "1" ]; then
          line_p="$(line_get "$line_i" HY2_PORT)"
          [ -n "$line_p" ] && ufw allow "${line_p}/udp" >/dev/null 2>&1 || true
        fi
        if [ "$ENABLE_TUIC" = "1" ]; then
          line_p="$(line_get "$line_i" TUIC_PORT)"
          [ -n "$line_p" ] && ufw allow "${line_p}/udp" >/dev/null 2>&1 || true
        fi
        if [ "$ENABLE_ANYTLS" = "1" ]; then
          line_p="$(line_get "$line_i" ANYTLS_PORT)"
          [ -n "$line_p" ] && ufw allow "${line_p}/tcp" >/dev/null 2>&1 || true
        fi
        if [ "$ENABLE_MIERU" = "1" ]; then
          line_p="$(line_get "$line_i" MIERU_PORT)"
          if [ -n "$line_p" ]; then
            ufw allow "${line_p}/$(mieru_proto_port_kind)" >/dev/null 2>&1 || true
          fi
        fi
        line_i=$((line_i + 1))
      done
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
      if [ "$ENABLE_MIERU" = "1" ]; then
        firewall-cmd --permanent --add-port="${MIERU_LISTEN_PORT}/$(mieru_proto_port_kind)" >/dev/null 2>&1 || true
      fi

      line_i=1
      while [ "$line_i" -le "$LINE_COUNT" ]; do
        if [ "$ENABLE_HY2" = "1" ]; then
          line_p="$(line_get "$line_i" HY2_PORT)"
          [ -n "$line_p" ] && firewall-cmd --permanent --add-port="${line_p}/udp" >/dev/null 2>&1 || true
        fi
        if [ "$ENABLE_TUIC" = "1" ]; then
          line_p="$(line_get "$line_i" TUIC_PORT)"
          [ -n "$line_p" ] && firewall-cmd --permanent --add-port="${line_p}/udp" >/dev/null 2>&1 || true
        fi
        if [ "$ENABLE_ANYTLS" = "1" ]; then
          line_p="$(line_get "$line_i" ANYTLS_PORT)"
          [ -n "$line_p" ] && firewall-cmd --permanent --add-port="${line_p}/tcp" >/dev/null 2>&1 || true
        fi
        if [ "$ENABLE_MIERU" = "1" ]; then
          line_p="$(line_get "$line_i" MIERU_PORT)"
          if [ -n "$line_p" ]; then
            firewall-cmd --permanent --add-port="${line_p}/$(mieru_proto_port_kind)" >/dev/null 2>&1 || true
          fi
        fi
        line_i=$((line_i + 1))
      done
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

node_name() {
  if [ -n "${NODE_PREFIX:-}" ]; then
    printf '%s_%s' "$NODE_PREFIX" "$1"
  else
    printf '%s' "$1"
  fi
}

emit_hy2() {
  host="$1"
  port="$2"
  name="$3"
  hp="$(fmt_hostport "$host" "$port")"
  printf '%s\n' "hysteria2://$AUTH_PASS@$hp?sni=$SNI_HOST&alpn=h3&insecure=1&allowInsecure=1#$name"
}

emit_tuic() {
  host="$1"
  port="$2"
  name="$3"
  hp="$(fmt_hostport "$host" "$port")"
  printf '%s\n' "tuic://${UUID}:${AUTH_PASS}@$hp?sni=$SNI_HOST&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#$name"
}

emit_anytls() {
  host="$1"
  port="$2"
  name="$3"
  hp="$(fmt_hostport "$host" "$port")"
  printf '%s\n' "anytls://$AUTH_PASS@$hp?security=tls&sni=$SNI_HOST&insecure=1&allowInsecure=1&type=tcp#$name"
}

emit_mieru() {
  host="$1"
  port="$2"
  name="$3"
  hp="$(fmt_hostport "$host" "$port")"
  # SublinkPro / mihomo 只接受单协议链接，按用户选择的传输协议输出一条
  proto="$(mieru_proto_name)"
  printf '%s\n' "mierus://${MIERU_USER}:${MIERU_PASS}@${hp}?port=${port}&protocol=$proto&profile=default#${name}_$proto"
}

show_node_set() {
  host="$1"
  kind="$2"

  printf '\n[%s]\n' "$kind"
  if [ "$ENABLE_HY2" = "1" ]; then
    emit_hy2 "$host" "$HY2_LISTEN_PORT" "$(node_name "HY2_$kind")"
  fi
  if [ "$ENABLE_TUIC" = "1" ]; then
    emit_tuic "$host" "$TUIC_LISTEN_PORT" "$(node_name "TUIC_$kind")"
  fi
  if [ "$ENABLE_ANYTLS" = "1" ]; then
    emit_anytls "$host" "$ANYTLS_LISTEN_PORT" "$(node_name "AnyTLS_$kind")"
  fi
  if [ "$ENABLE_MIERU" = "1" ]; then
    emit_mieru "$host" "$MIERU_LISTEN_PORT" "$(node_name "Mieru_$kind")"
  fi

  line_i=1
  while [ "$line_i" -le "$LINE_COUNT" ]; do
    printf '\n[%s 中转 %s]\n' "$kind" "$(line_name "$line_i")"
    if [ "$ENABLE_HY2" = "1" ]; then
      emit_hy2 "$host" "$(line_get "$line_i" HY2_PORT)" "$(line_node_name "$line_i" "HY2_$kind")"
    fi
    if [ "$ENABLE_TUIC" = "1" ]; then
      emit_tuic "$host" "$(line_get "$line_i" TUIC_PORT)" "$(line_node_name "$line_i" "TUIC_$kind")"
    fi
    if [ "$ENABLE_ANYTLS" = "1" ]; then
      emit_anytls "$host" "$(line_get "$line_i" ANYTLS_PORT)" "$(line_node_name "$line_i" "AnyTLS_$kind")"
    fi
    if [ "$ENABLE_MIERU" = "1" ]; then
      emit_mieru "$host" "$(line_get "$line_i" MIERU_PORT)" "$(line_node_name "$line_i" "Mieru_$kind")"
    fi
    line_i=$((line_i + 1))
  done
}

show_nodes() {
  load_state || true
  if [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; then
    detect_public_ips
  fi
  printf '\n%s\n' "===== 节点信息 ====="
  printf '协议：%s\n' "$(show_protocol_status)"
  printf '网络：%s\n' "$(ip_mode_label)"
  if [ "$LINE_COUNT" -eq 0 ]; then
    printf '中转线路：无（本机节点直连）\n'
    printf '如需增加中转线路，请在菜单 9 中添加。\n'
  else
    printf '中转线路：%s 条\n' "$LINE_COUNT"
  fi

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

  if [ "$ENABLE_MIERU" = "1" ]; then
    printf '\nMieru 传输协议：%s（每条链接只绑定这一种）\n' "$(mieru_proto_name)"
    printf '  官方客户端：mieru import config "<上面的 mierus 链接>"\n'
    printf '  mihomo/clash.meta（本机）：type: mieru, port: %s, transport: %s, udp: true\n' "$MIERU_LISTEN_PORT" "$(mieru_proto_name)"
    line_i=1
    while [ "$line_i" -le "$LINE_COUNT" ]; do
      printf '  mihomo/clash.meta（%s）：type: mieru, port: %s, transport: %s, udp: true\n' "$(line_name "$line_i")" "$(line_get "$line_i" MIERU_PORT)" "$(mieru_proto_name)"
      line_i=$((line_i + 1))
    done
    if [ "$MIERU_TRANSPORT" = "UDP" ]; then
      printf '  UDP 延迟低、抗丢包；若运营商 QoS 限速 UDP，可在菜单 6 换回 TCP。\n'
      printf '  注意：云安全组 / 外部防火墙也要放行 UDP 端口。\n'
    else
      printf '  TCP 兼容性最好；想要更低延迟可在菜单 6 换 UDP（需客户端同步改协议）。\n'
      printf '  注意：云安全组 / 外部防火墙也要放行 TCP 端口。\n'
    fi
  fi

  if [ "$LINE_COUNT" -gt 0 ]; then
    printf '\n%s\n' "===== 中转线路上游（含密码，请勿发给客户端）====="
    line_i=1
    while [ "$line_i" -le "$LINE_COUNT" ]; do
      line_load_scratch "$line_i"
      printf '[%s] %s\n' "$(line_name "$line_i")" "$(relay_link)"
      line_i=$((line_i + 1))
    done
    printf '客户端只使用上面的节点链接；这些上游连接仅本机 / 运维保存。\n'
  fi
  printf '\n'
}

fresh_install() {
  ensure_deps
  detect_env

  prompt_protocols || {
    log "[INFO] 已取消安装"
    exit 0
  }
  prompt_ip_mode || {
    log "[INFO] 已取消安装"
    exit 0
  }

  printf '\n%s\n' "===== 第四步：配置各协议端口 =====" >&2
  prompt_all_ports

  printf '\n%s\n' "===== 第五步：节点名称（可选）=====" >&2
  prompt_node_name

  if singbox_wanted; then
    if [ "$SNI_ENV_SET" = "1" ]; then
      [ -n "$SNI_ENV_VALUE" ] && SNI_HOST="$SNI_ENV_VALUE"
      log "[INFO] 使用预设 SNI：$SNI_HOST"
    else
      printf '\n%s\n' "===== 第六步：TLS 伪装域名（SNI）=====" >&2
      prompt_sni
    fi
  fi

  gen_creds
  gen_cert

  install_singbox
  check_singbox_exec

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

change_node_name() {
  load_state || true

  printf '\n%s\n' "===== 修改节点名称 =====" >&2
  printf '当前前缀：%s\n' "${NODE_PREFIX:-（无，使用默认名称）}" >&2
  prompt_node_name

  save_state
  show_nodes
}

change_sni() {
  load_state || true

  printf '\n%s\n' "===== 修改 TLS 伪装域名（SNI）=====" >&2
  if ! singbox_wanted; then
    log "[WARN] 当前未启用 Hysteria2 / TUIC / AnyTLS，SNI 不会影响节点链接"
  fi

  prompt_sni

  if singbox_wanted; then
    log "[INFO] 重新生成证书..."
    gen_cert
  fi

  save_state

  if singbox_wanted; then
    log "[INFO] 重启服务..."
    restart_service
  fi

  show_nodes
}

prompt_line_index() {
  [ "$LINE_COUNT" -gt 0 ] || {
    log "[WARN] 当前没有中转线路"
    return 1
  }
  while :; do
    printf '请选择线路序号 [1-%s]: ' "$LINE_COUNT" >&2
    read_or_exit ans
    case "$ans" in
      ''|*[!0-9]*)
        log "[ERROR] 请输入数字"
        continue
        ;;
    esac
    if [ "$ans" -ge 1 ] && [ "$ans" -le "$LINE_COUNT" ]; then
      printf '%s' "$ans"
      return 0
    fi
    log "[ERROR] 序号超出范围"
  done
}

add_line() {
  load_state || true
  line_new=$((LINE_COUNT + 1))
  line_reset_scratch
  if ! prompt_relay "$line_new"; then
    log "[INFO] 已取消"
    return 0
  fi
  relay_probe || true
  line_store_scratch "$line_new"
  LINE_COUNT="$line_new"
  save_state
  write_config
  ensure_firewall

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 重启服务..."
  restart_service
  show_nodes
}

edit_line() {
  load_state || true
  line_pick="$(prompt_line_index)" || return 0
  line_load_scratch "$line_pick"
  stop_service
  if ! prompt_relay "$line_pick"; then
    log "[INFO] 已取消，恢复原配置"
    start_service
    return 0
  fi
  relay_probe || true
  line_store_scratch "$line_pick"
  save_state
  write_config
  ensure_firewall

  log "[INFO] 检查 sing-box 配置..."
  if ! "$SB_BIN" check -c "$CONFIG_FILE"; then
    log "[ERROR] 配置检查失败，恢复原服务"
    start_service
    return 0
  fi

  log "[INFO] 启动服务..."
  start_service
  show_nodes
}

delete_line() {
  load_state || true
  line_pick="$(prompt_line_index)" || return 0
  printf '确认删除中转线路 %s？[y/N]: ' "$(line_name "$line_pick")" >&2
  read_or_exit ans
  case "$ans" in
    y|Y) : ;;
    *)
      log "[INFO] 已取消"
      return 0
      ;;
  esac

  stop_service
  line_compact "$line_pick"
  save_state
  write_config

  log "[INFO] 检查 sing-box 配置..."
  "$SB_BIN" check -c "$CONFIG_FILE"

  log "[INFO] 启动服务..."
  start_service
  show_nodes
}

line_menu() {
  load_state || true
  while :; do
    printf '\n%s\n' "===== 中转线路管理 ====="
    printf '本机节点：直连（始终保留，不受中转线路影响）\n'
    if [ "$LINE_COUNT" -eq 0 ]; then
      printf '当前线路：无\n'
    else
      printf '当前线路：%s 条\n' "$LINE_COUNT"
      line_i=1
      while [ "$line_i" -le "$LINE_COUNT" ]; do
        line_t="$(line_get "$line_i" TYPE)"
        case "$line_t" in
          socks) line_t="SOCKS5" ;;
          http)  line_t="HTTP" ;;
          ss)    line_t="SS2022" ;;
        esac
        printf '  %s) %-10s %s %s:%s\n' "$line_i" "$(line_name "$line_i")" "$line_t" "$(line_get "$line_i" HOST)" "$(line_get "$line_i" PORT)"
        line_i=$((line_i + 1))
      done
    fi
    printf '%s\n' "1) 添加中转线路" "2) 修改中转线路" "3) 删除中转线路" "0) 返回"
    printf '请选择 [0-3]: ' >&2
    read_or_exit choice
    case "$choice" in
      1) add_line ;;
      2) edit_line ;;
      3) delete_line ;;
      0|'') return 0 ;;
      *) log "请输入 0-3 之间的选项" ;;
    esac
  done
}

change_settings() {
  load_state || true

  ensure_deps
  if [ -z "$ARCH" ] || { [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; }; then
    detect_env
  fi

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
  prompt_missing_line_ports

  gen_missing_creds
  ensure_cert

  ensure_singbox_flavor

  save_state
  write_config
  write_service
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
  rm -f "$SB_LIB_DIR/libcronet.so" 2>/dev/null || true
  rm -rf "$BASE_DIR" 2>/dev/null || true
  LINE_COUNT=0

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
    printf '\n%s\n' "===== sing-box / Mieru 多协议管理脚本 ====="
    printf '当前协议：%s\n' "$(show_protocol_status)"
    printf '当前网络：%s\n' "$(ip_mode_label)"
    printf '当前线路：%s\n' "$(line_summary)"
    printf '%s\n' "1) 重装（重新选择协议 / IP 栈）"
    printf '%s\n' "2) 卸载"
    printf '%s\n' "3) 重置端口（本机节点）"
    printf '%s\n' "4) 重启服务"
    printf '%s\n' "5) 查看节点"
    printf '%s\n' "6) 修改协议 / IP 栈"
    printf '%s\n' "7) 修改节点名称（本机节点）"
    printf '%s\n' "8) 修改伪装域名（SNI）"
    printf '%s\n' "9) 中转线路管理"
    printf '%s\n' "0) 退出"
    printf '%s' "请选择 [0-9]: " >&2

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
      7)
        change_node_name
        ;;
      8)
        change_sni
        ;;
      9)
        line_menu
        ;;
      0|'')
        exit 0
        ;;
      *)
        log "请输入 0-9 之间的选项"
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
    log "[ERROR] 未检测到 systemd / OpenRC，脚本需要服务管理器才能托管 sing-box"
    if [ "$IS_CONTAINER" = "1" ]; then
      log "[ERROR] 当前在容器内运行。请改用支持 systemd 的镜像并以 --privileged 启动，"
      log "[ERROR] 或直接在宿主机/ VPS 上运行本脚本。"
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
