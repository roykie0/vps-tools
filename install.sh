#!/usr/bin/env bash
# Interactive VPS bootstrapper for 3x-ui or S-UI on Debian and Ubuntu.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="VPS Panel Setup"
readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
readonly SUI_INSTALL_URL="https://s-ui.alireza0.dev/install.sh"
readonly SHORTCUT_NAME="roy"
readonly LOCAL_SCRIPT_PATH="/usr/local/lib/vps-panel-setup/${SHORTCUT_NAME}"
APT_INDEX_READY=false
RECOMMENDED_NODE_PORTS=""

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

install_shortcut() {
  local source_file="${BASH_SOURCE[0]}"
  if [[ ! -r "$source_file" ]]; then
    warn "无法创建快捷命令。请从本地脚本文件运行后再重试。"
    return
  fi

  install -d -m 755 "$(dirname "$LOCAL_SCRIPT_PATH")"
  install -m 755 "$source_file" "$LOCAL_SCRIPT_PATH"
  ln -sfn "$LOCAL_SCRIPT_PATH" "/usr/local/bin/${SHORTCUT_NAME}"
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

refresh_package_index() {
  if [[ "$APT_INDEX_READY" == true ]]; then
    return
  fi
  apt-get update
  APT_INDEX_READY=true
}

install_prerequisites() {
  info "正在安装基础工具..."
  export DEBIAN_FRONTEND=noninteractive
  refresh_package_index
  apt-get install -y ca-certificates curl ufw
}

update_system() {
  if confirm "是否安装系统可用更新？这可能需要几分钟"; then
    export DEBIAN_FRONTEND=noninteractive
    refresh_package_index
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

configure_network_acceleration() {
  local config_file="/etc/sysctl.d/99-vps-network-acceleration.conf" memory_mb
  if ! confirm "是否执行网络速度优化？"; then
    return
  fi

  memory_mb="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
  {
    echo "# Managed by vps-panel-setup.sh"
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
    else
      warn "当前内核不提供 BBR，将跳过 BBR 设置。" >&2
    fi
    # 仅在出现 PMTU 黑洞时启用探测，避免强制改变所有连接的 MSS。
    if sysctl -n net.ipv4.tcp_mtu_probing >/dev/null 2>&1; then
      echo "net.ipv4.tcp_mtu_probing=1"
    fi
    # 启用 TCP Fast Open 的客户端和服务端能力；应用仍可自行决定是否使用它。
    if sysctl -n net.ipv4.tcp_fastopen >/dev/null 2>&1; then
      echo "net.ipv4.tcp_fastopen=3"
    fi
  } >"$config_file"

  if [[ "${memory_mb:-0}" -ge 1024 ]] && confirm "检测到内存 ${memory_mb} MB。是否提高 TCP 缓冲区上限以改善高带宽连接？"; then
    cat >>"$config_file" <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
  fi

  sysctl --system >/dev/null
  say "网络速度优化已应用。"
  info "当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
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

port_in_use() {
  local port="$1"
  command -v ss >/dev/null 2>&1 && ss -ltnH | awk '{print $4}' | grep -Eq "(:|\\])${port}$"
}

ask_free_port() {
  local prompt="$1" default_value="$2" value
  while true; do
    value="$(ask_port "$prompt" "$default_value")"
    if ! port_in_use "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "端口 ${value} 正被其他服务使用，请换一个端口。" >&2
  done
}

preferred_free_port() {
  local preferred="$1" fallback
  if ! port_in_use "$preferred"; then
    printf '%s' "$preferred"
    return
  fi
  fallback="$(shuf -i 20000-45000 -n 1)"
  while port_in_use "$fallback"; do
    fallback="$(shuf -i 20000-45000 -n 1)"
  done
  printf '%s' "$fallback"
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

create_recommended_3x_nodes() {
  local username="$1" password="$2" panel_port="$3" panel_path="$4"
  local main_port backup_port xray_bin keypair private_key short_id uuid ss_password
  local cookie_file main_payload backup_payload panel_base main_result backup_result

  if ! confirm "是否自动创建无域名推荐节点？"; then
    return
  fi

  main_port="$(preferred_free_port 443)"
  backup_port="$(preferred_free_port 8443)"
  if [[ "$backup_port" == "$main_port" ]]; then
    backup_port="$(preferred_free_port 2443)"
  fi
  xray_bin="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 | head -n 1)"
  if [[ -z "$xray_bin" ]]; then
    warn "未找到 Xray 内核，已跳过自动创建推荐节点。"
    return
  fi

  keypair="$($xray_bin x25519)"
  private_key="$(awk '/Private key:/ {print $3}' <<<"$keypair")"
  if [[ -z "$private_key" ]]; then
    warn "无法生成 Reality 密钥，已跳过自动创建推荐节点。"
    return
  fi
  short_id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  ss_password="$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | cut -c 1-32)"
  cookie_file="$(mktemp)"
  main_payload="$(mktemp)"
  backup_payload="$(mktemp)"
  panel_base="http://127.0.0.1:${panel_port}/${panel_path}"

  curl -fsS -c "$cookie_file" --data-urlencode "username=${username}" --data-urlencode "password=${password}" "${panel_base}/login" >/dev/null
  main_settings="$(printf '{"clients":[{"id":"%s","flow":"xtls-rprx-vision","email":"main-user"}],"decryption":"none"}' "$uuid")"
  main_stream="$(printf '{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"www.microsoft.com:443","xver":0,"serverNames":["www.microsoft.com"],"privateKey":"%s","shortIds":["%s"]}}' "$private_key" "$short_id")"
  backup_settings="$(printf '{"clients":[{"email":"backup-user","method":"2022-blake3-aes-256-gcm","password":"%s"}],"network":"tcp,udp"}' "$ss_password")"
  sniffing='{"enabled":true,"destOverride":["http","tls","quic"]}'
  json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  cat >"$main_payload" <<EOF
{"remark":"主用-VLESS-Reality","enable":true,"port":${main_port},"protocol":"vless","settings":"$(printf '%s' "$main_settings" | json_escape)","streamSettings":"$(printf '%s' "$main_stream" | json_escape)","sniffing":"$(printf '%s' "$sniffing" | json_escape)"}
EOF
  cat >"$backup_payload" <<EOF
{"remark":"备用-Shadowsocks-2022","enable":true,"port":${backup_port},"protocol":"shadowsocks","settings":"$(printf '%s' "$backup_settings" | json_escape)","streamSettings":"$(printf '%s' '{"network":"tcp","security":"none"}' | json_escape)","sniffing":"$(printf '%s' "$sniffing" | json_escape)"}
EOF

  main_result="$(curl -fsS -b "$cookie_file" -H 'Content-Type: application/json' --data-binary "@${main_payload}" "${panel_base}/panel/api/inbounds/add" || true)"
  backup_result="$(curl -fsS -b "$cookie_file" -H 'Content-Type: application/json' --data-binary "@${backup_payload}" "${panel_base}/panel/api/inbounds/add" || true)"
  rm -f "$cookie_file" "$main_payload" "$backup_payload"

  if [[ "$main_result" == *'"success":true'* && "$backup_result" == *'"success":true'* ]]; then
    RECOMMENDED_NODE_PORTS="${main_port},${backup_port}"
    systemctl restart x-ui >/dev/null 2>&1 || true
    say "已创建主用 VLESS Reality 和备用 Shadowsocks 2022 节点。"
    info "节点端口：${RECOMMENDED_NODE_PORTS}；请在面板的入站列表中复制订阅或连接链接。"
  else
    warn "推荐节点创建未完成。请在面板中手动检查入站列表，未成功的请求不会影响面板本身。"
  fi
}

create_s_ui_node_entry() {
  local panel_port="$1" panel_path="$2" guide_file="/root/s-ui-recommended-nodes.txt"
  cat >"$guide_file" <<EOF
无域名推荐方案
主用：VLESS + Reality + Vision
备用：Shadowsocks 2022

有域名推荐方案
主用：Hysteria2 + TLS
备用：VLESS + Reality + Vision

请在 S-UI 后台的入站页面创建以上节点。面板地址：
http://你的服务器IP:${panel_port}${panel_path}
EOF
  info "S-UI 推荐节点入口已生成：${guide_file}"
  info "无域名：主用 VLESS + Reality + Vision，备用 Shadowsocks 2022。"
  info "有域名：可改用 Hysteria2 + TLS 作为主用。"
}

preflight_check() {
  local free_disk_kb memory_mb
  free_disk_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
  memory_mb="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"

  info "安装前检查：内存 ${memory_mb:-未知} MB，可用磁盘 $(( ${free_disk_kb:-0} / 1024 )) MB。"
  if [[ "${free_disk_kb:-0}" -lt 1048576 ]]; then
    warn "可用磁盘空间不足 1 GB，安装可能失败。"
  fi
  if [[ "${memory_mb:-0}" -lt 512 ]]; then
    warn "内存低于 512 MB，面板运行可能不稳定。"
  fi
}

backup_existing_panels() {
  local backup_dir timestamp found=false
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/vps-panel-backups/${timestamp}"

  if [[ -d /etc/x-ui || -d /usr/local/x-ui || -d /usr/local/s-ui ]]; then
    if ! confirm "检测到已有面板数据。是否先备份？"; then
      warn "已跳过备份。"
      return
    fi
    mkdir -p "$backup_dir"
    for target in /etc/x-ui /usr/local/x-ui /usr/local/s-ui; do
      if [[ -d "$target" ]]; then
        tar -czf "${backup_dir}/$(basename "$target").tar.gz" -C "$(dirname "$target")" "$(basename "$target")"
        found=true
      fi
    done
    if [[ "$found" == true ]]; then
      say "已有面板数据已备份到：${backup_dir}"
    fi
  fi
}

configure_auto_security_updates() {
  if ! confirm "是否启用自动安装安全更新？"; then
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  refresh_package_index
  apt-get install -y unattended-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  say "自动安全更新已启用。"
}

configure_fail2ban() {
  if ! confirm "是否启用 Fail2Ban 防 SSH 暴力尝试？"; then
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  refresh_package_index
  apt-get install -y fail2ban
  cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
  say "Fail2Ban 已启用：10 分钟内连续失败 5 次将封禁 1 小时。"
}

run_security_hardening() {
  require_supported_os
  configure_auto_security_updates
  configure_fail2ban
  say "安全加固流程完成。"
}

install_3x_ui_chinese() {
  local username password port path installer_file log_file
  username="$(ask_text '请输入后台用户名' "admin$(random_text 5)")"
  password="$(ask_text '请输入后台密码' "$(random_text 16)")"
  port="$(ask_free_port '请输入后台端口' '2053')"
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
  create_recommended_3x_nodes "$username" "$password" "$port" "$path"
  echo
  info "后台用户名：${username}"
  info "后台密码：${password}"
  show_access_hint '3x-ui' "$port" "/${path}"
  if confirm "是否现在配置 UFW 防火墙并放行后台端口 ${port}？"; then
    configure_firewall "${port}${RECOMMENDED_NODE_PORTS:+,${RECOMMENDED_NODE_PORTS}}"
  fi
}

install_s_ui_chinese() {
  local username password panel_port panel_path sub_port sub_path installer_file log_file
  username="$(ask_text '请输入后台用户名' "admin$(random_text 5)")"
  password="$(ask_text '请输入后台密码' "$(random_text 16)")"
  panel_port="$(ask_free_port '请输入后台端口' '2095')"
  panel_path="$(normalize_path "$(ask_text '请输入后台路径，例如 app' 'app')")"
  sub_port="$(ask_free_port '请输入订阅端口' '2096')"
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
  info "后台用户名：${username}"
  info "后台密码：${password}"
  show_access_hint 'S-UI' "$panel_port" "$panel_path"
  info "订阅地址格式： http://你的服务器IP:${sub_port}${sub_path}"
  create_s_ui_node_entry "$panel_port" "$panel_path"
  if confirm "是否现在配置 UFW 防火墙并放行后台与订阅端口？"; then
    configure_firewall "${panel_port},${sub_port}"
  fi
}

configure_firewall() {
  install_prerequisites
  local ssh_port extra_ports raw_port suggested_ports="${1:-}"
  ssh_port="$(get_ssh_port)"

  warn "防火墙会默认拒绝入站连接，但会保留当前 SSH 端口 ${ssh_port}。"
  if ! confirm "是否继续配置 UFW 防火墙？"; then
    return
  fi

  read -r -e -i "$suggested_ports" -p "请输入要额外放行的端口（用逗号分隔；例如 80,443,2095,2096；可留空）: " extra_ports
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
  configure_file_limits
  say "基础优化完成。"
}

run_installer() {
  local panel="$1" type="$2"
  require_supported_os
  preflight_check
  backup_existing_panels
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

show_service_status() {
  echo
  if systemctl is-active --quiet x-ui; then
    say "3x-ui 服务正在运行。"
  else
    warn "3x-ui 服务未运行或尚未安装。"
  fi
  if systemctl is-active --quiet s-ui; then
    say "S-UI 服务正在运行。"
  else
    warn "S-UI 服务未运行或尚未安装。"
  fi
  if systemctl is-active --quiet sing-box; then
    say "Sing-box 服务正在运行。"
  else
    info "Sing-box 服务未运行或尚未安装。"
  fi
  if systemctl is-active --quiet fail2ban; then
    say "Fail2Ban 正在运行。"
  else
    info "Fail2Ban 未启用。"
  fi
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
1) 执行 VPS 基础优化
2) 执行网络速度优化（BBR、MTU 探测、TCP Fast Open）
3) 执行安全加固（自动安全更新与 Fail2Ban）
4) 安装 3x-ui（Xray 管理面板）
5) 安装 S-UI（Sing-box 管理面板）
6) 配置 UFW 防火墙
7) 查看面板与安全服务状态
0) 退出
EOF
    read -r -p "请输入选项 [0-7]: " choice
    case "$choice" in
      1) run_optimization; pause ;;
      2) configure_network_acceleration; pause ;;
      3) run_security_hardening; pause ;;
      4) run_installer "3x-ui" 'xui'; pause ;;
      5) run_installer "S-UI" 'sui'; pause ;;
      6) configure_firewall; pause ;;
      7) show_service_status; pause ;;
      0) info "已退出。"; exit 0 ;;
      *) warn "请输入 0 到 7 之间的数字。"; pause ;;
    esac
  done
}

require_root
install_shortcut
main_menu
