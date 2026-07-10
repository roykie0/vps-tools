#!/usr/bin/env bash
# Interactive VPS bootstrapper for 3x-ui or S-UI on Debian and Ubuntu.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="VPS Panel Setup"
readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
readonly SUI_INSTALL_URL="https://s-ui.alireza0.dev/install.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

say() { printf '%b\n' "${GREEN}[OK]${RESET} $*"; }
info() { printf '%b\n' "${CYAN}[i]${RESET} $*"; }
warn() { printf '%b\n' "${YELLOW}[!]${RESET} $*"; }
fail() { printf '%b\n' "${RED}[x]${RESET} $*" >&2; }

pause() {
  read -r -p "按回车键返回主菜单..." _
}

confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

require_supported_os() {
  if [[ ! -r /etc/os-release ]]; then
    fail "无法识别系统版本。此脚本仅支持 Ubuntu 和 Debian。"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      fail "检测到 ${PRETTY_NAME:-未知系统}。此脚本仅支持 Ubuntu 和 Debian。"
      exit 1
      ;;
  esac
}

install_prerequisites() {
  info "刷新软件包索引并安装基础工具..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl ufw
}

update_system() {
  if confirm "是否安装系统可用更新？这可能需要几分钟"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    say "系统更新完成。"
  else
    info "已跳过系统更新。"
  fi
}

configure_timezone_and_ntp() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    warn "系统没有 timedatectl，已跳过时区和时间同步设置。"
    return
  fi

  if confirm "是否设置时区为 Asia/Shanghai 并启用网络时间同步？"; then
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || warn "无法启用 NTP，请检查系统时间服务。"
    say "时区和时间同步已处理。"
  fi
}

configure_bbr() {
  if ! confirm "是否尝试启用 BBR 拥塞控制？"; then
    return
  fi

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn "当前内核不提供 BBR，未修改系统设置。"
    return
  fi

  local config_file="/etc/sysctl.d/99-vps-panel-tuning.conf"
  cat >"$config_file" <<'EOF'
# Managed by vps-panel-setup.sh
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  say "BBR 已启用：$(sysctl -n net.ipv4.tcp_congestion_control)"
}

configure_file_limits() {
  if ! confirm "是否提高系统文件句柄上限？"; then
    return
  fi

  local config_file="/etc/security/limits.d/99-vps-panel.conf"
  cat >"$config_file" <<'EOF'
# Managed by vps-panel-setup.sh
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
  say "文件句柄上限已写入，将在新的登录会话中生效。"
}

get_ssh_port() {
  local port="22"
  if command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
  fi
  printf '%s' "${port:-22}"
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

random_text() {
  local length="$1"
  head -c "$((length * 2))" /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c "1-${length}"
}

ask_port() {
  local prompt="$1" default_value="$2" value
  while true; do
    read -r -p "${prompt}（直接回车使用 ${default_value}）: " value
    value="${value:-$default_value}"
    if valid_port "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "端口必须是 1 到 65535 之间的数字。" >&2
  done
}

ask_text() {
  local prompt="$1" default_value="$2" value
  read -r -p "${prompt}（直接回车自动生成）: " value
  printf '%s' "${value:-$default_value}"
}

normalize_path() {
  local value="$1"
  value="${value#/}"
  value="${value%/}"
  printf '/%s/' "$value"
}

show_access_hint() {
  local panel="$1" port="$2" path="$3"
  echo
  say "${panel} 已安装完成。"
  info "后台地址： http://你的服务器IP:${port}${path}"
  info "请在云服务商安全组和 UFW 中放行实际使用的端口。"
}

install_3x_ui_chinese() {
  local username password port path installer_file log_file
  username="$(ask_text '请输入后台用户名' "admin$(random_text 5)")"
  password="$(ask_text '请输入后台密码' "$(random_text 16)")"
  port="$(ask_port '请输入后台端口' '2053')"
  path="$(ask_text '请输入后台路径，例如 panel' "$(random_text 16)")"
  path="${path#/}"
  path="${path%/}"

  info "正在安装 3x-ui，请耐心等待。"
  installer_file="$(mktemp /tmp/3x-ui-installer.XXXXXX)"
  log_file="/var/log/vps-panel-3x-ui-install.log"
  curl -fsSL "$XUI_INSTALL_URL" -o "$installer_file"
  if ! XUI_NONINTERACTIVE=1 bash "$installer_file" >"$log_file" 2>&1 </dev/null; then
    rm -f "$installer_file"
    fail "3x-ui 安装失败，详细日志：${log_file}"
    return 1
  fi
  rm -f "$installer_file"

  if ! x-ui setting -username "$username" -password "$password" -port "$port" -webBasePath "$path" >>"$log_file" 2>&1; then
    fail "3x-ui 已安装，但初始化后台设置失败。详细日志：${log_file}"
    return 1
  fi
  systemctl restart x-ui >>"$log_file" 2>&1 || true
  echo
  say "3x-ui 已安装完成。"
  info "后台用户名：${username}"
  info "后台密码：${password}"
  show_access_hint '3x-ui' "$port" "/${path}"
}

install_s_ui_chinese() {
  local username password panel_port panel_path sub_port sub_path installer_file log_file
  username="$(ask_text '请输入后台用户名' "admin$(random_text 5)")"
  password="$(ask_text '请输入后台密码' "$(random_text 16)")"
  panel_port="$(ask_port '请输入后台端口' '2095')"
  panel_path="$(normalize_path "$(ask_text '请输入后台路径，例如 app' 'app')")"
  sub_port="$(ask_port '请输入订阅端口' '2096')"
  sub_path="$(normalize_path "$(ask_text '请输入订阅路径，例如 sub' 'sub')")"

  info "正在安装 S-UI，请耐心等待。"
  installer_file="$(mktemp /tmp/s-ui-installer.XXXXXX)"
  log_file="/var/log/vps-panel-s-ui-install.log"
  curl -fsSL "$SUI_INSTALL_URL" -o "$installer_file"
  # 官方脚本的首个问题输入 n；后续由中文向导统一配置。
  if ! printf 'n\n' | bash "$installer_file" >"$log_file" 2>&1; then
    rm -f "$installer_file"
    fail "S-UI 安装失败，详细日志：${log_file}"
    return 1
  fi
  rm -f "$installer_file"

  if ! /usr/local/s-ui/sui setting -port "$panel_port" -path "$panel_path" -subPort "$sub_port" -subPath "$sub_path" >>"$log_file" 2>&1 || ! /usr/local/s-ui/sui admin -username "$username" -password "$password" >>"$log_file" 2>&1; then
    fail "S-UI 已安装，但初始化后台设置失败。详细日志：${log_file}"
    return 1
  fi
  systemctl restart s-ui >>"$log_file" 2>&1 || true
  systemctl restart sing-box >>"$log_file" 2>&1 || true
  echo
  say "S-UI 已安装完成。"
  info "后台用户名：${username}"
  info "后台密码：${password}"
  show_access_hint 'S-UI' "$panel_port" "$panel_path"
  info "订阅地址格式： http://你的服务器IP:${sub_port}${sub_path}"
}

configure_firewall() {
  install_prerequisites
  local ssh_port extra_ports raw_port
  ssh_port="$(get_ssh_port)"

  warn "防火墙会默认拒绝入站连接，但会保留当前 SSH 端口 ${ssh_port}。"
  if ! confirm "是否继续配置 UFW 防火墙？"; then
    return
  fi

  read -r -p "请输入要额外放行的端口（用逗号分隔；例如 80,443,2095,2096；可留空）: " extra_ports
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp" comment 'SSH access'

  if [[ -n "${extra_ports//[[:space:]]/}" ]]; then
    IFS=',' read -r -a ports <<<"$extra_ports"
    for raw_port in "${ports[@]}"; do
      raw_port="${raw_port//[[:space:]]/}"
      if valid_port "$raw_port"; then
        ufw allow "$raw_port" comment 'Panel or service port'
      else
        warn "忽略无效端口：${raw_port}"
      fi
    done
  fi

  ufw --force enable
  say "UFW 已启用。请确认云服务商安全组也放行了需要的端口。"
  ufw status numbered
}

run_optimization() {
  require_supported_os
  update_system
  install_prerequisites
  configure_timezone_and_ntp
  configure_bbr
  configure_file_limits
  say "基础优化完成。"
}

run_installer() {
  local panel="$1" type="$2"
  require_supported_os
  install_prerequisites
  warn "将由中文向导安装 ${panel}。请设置强密码和不常见的后台路径。"
  if ! confirm "确认开始安装 ${panel}？"; then
    return
  fi
  case "$type" in
    xui) install_3x_ui_chinese ;;
    sui) install_s_ui_chinese ;;
  esac
  info "建议接着在主菜单选择“配置防火墙”，放行你实际设置的面板和节点端口。"
}

show_header() {
  clear
  printf '%b\n' "${CYAN}============================================${RESET}"
  printf '%b\n' "${CYAN}         ${SCRIPT_NAME}${RESET}"
  printf '%b\n' "${CYAN}        Ubuntu / Debian 专用${RESET}"
  printf '%b\n\n' "${CYAN}============================================${RESET}"
}

main_menu() {
  local choice
  while true; do
    show_header
    cat <<'EOF'
1) 安装 3x-ui（Xray 管理面板）
2) 安装 S-UI（Sing-box 管理面板）
3) 执行 VPS 基础优化
4) 配置 UFW 防火墙
0) 退出
EOF
    read -r -p "请输入选项 [0-4]: " choice
    case "$choice" in
      1) run_installer "3x-ui" 'xui'; pause ;;
      2) run_installer "S-UI" 'sui'; pause ;;
      3) run_optimization; pause ;;
      4) configure_firewall; pause ;;
      0) info "已退出。"; exit 0 ;;
      *) warn "请输入 0 到 4 之间的数字。"; pause ;;
    esac
  done
}

require_root
main_menu
