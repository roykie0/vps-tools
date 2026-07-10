#!/usr/bin/env bash
# Interactive VPS bootstrapper for 3x-ui or S-UI on Debian and Ubuntu.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="VPS Panel Setup"
readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
readonly SUI_INSTALL_URL="https://s-ui.alireza0.dev/install.sh"
readonly SHORTCUT_NAME="roy"
readonly LOCAL_SCRIPT_PATH="/usr/local/lib/vps-panel-setup/${SHORTCUT_NAME}"
readonly ROY_DATA_DIR="/root/.roy"
readonly PANEL_INFO_FILE="${ROY_DATA_DIR}/panel-info.conf"
readonly NODE_INFO_FILE="${ROY_DATA_DIR}/nodes.txt"
APT_INDEX_READY=false

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

offer_disable_existing_ufw() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "检测到旧配置中的 UFW 仍在运行，它可能限制面板或节点端口。"
    if confirm "是否禁用 UFW，解除本机端口限制？"; then
      ufw --force disable
      say "UFW 已禁用。"
    fi
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
  apt-get install -y ca-certificates curl
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

get_server_ip() {
  local ip="" url
  for url in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    ip="$(curl -4fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"
      return
    fi
  done
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-服务器IP}"
}

url_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

detect_web_scheme() {
  local port="$1"
  if curl -kIsS --max-time 3 "https://127.0.0.1:${port}/" >/dev/null 2>&1; then
    printf 'https'
  else
    printf 'http'
  fi
}

save_panel_info() {
  local panel_type="$1" host="$2" port="$3" path="$4" username="$5" password="$6"
  local sub_port="${7:-}" sub_path="${8:-}" panel_scheme="${9:-http}" sub_scheme="${10:-http}"
  install -d -m 700 "$ROY_DATA_DIR"
  {
    printf 'PANEL_TYPE=%q\n' "$panel_type"
    printf 'PANEL_HOST=%q\n' "$host"
    printf 'PANEL_PORT=%q\n' "$port"
    printf 'PANEL_PATH=%q\n' "$path"
    printf 'PANEL_USERNAME=%q\n' "$username"
    printf 'PANEL_PASSWORD=%q\n' "$password"
    printf 'PANEL_SCHEME=%q\n' "$panel_scheme"
    printf 'SUB_PORT=%q\n' "$sub_port"
    printf 'SUB_PATH=%q\n' "$sub_path"
    printf 'SUB_SCHEME=%q\n' "$sub_scheme"
  } >"$PANEL_INFO_FILE"
  chmod 600 "$PANEL_INFO_FILE"
}

show_saved_panel_info() {
  if [[ ! -r "$PANEL_INFO_FILE" ]]; then
    info "没有找到由本脚本保存的面板登录信息。"
    return
  fi

  PANEL_TYPE="" PANEL_HOST="" PANEL_PORT="" PANEL_PATH=""
  PANEL_USERNAME="" PANEL_PASSWORD="" PANEL_SCHEME="http"
  SUB_PORT="" SUB_PATH="" SUB_SCHEME="http"
  # shellcheck disable=SC1090
  . "$PANEL_INFO_FILE"
  local host
  host="$(url_host "$PANEL_HOST")"
  echo
  printf '%b\n' "${CYAN}面板登录信息${RESET}"
  printf '面板：%s\n' "$PANEL_TYPE"
  printf '登录地址：%s://%s:%s%s\n' "$PANEL_SCHEME" "$host" "$PANEL_PORT" "$PANEL_PATH"
  printf '用户名：%s\n' "$PANEL_USERNAME"
  printf '密码：%s\n' "$PANEL_PASSWORD"
  if [[ -n "$SUB_PORT" ]]; then
    printf '订阅地址：%s://%s:%s%s\n' "$SUB_SCHEME" "$host" "$SUB_PORT" "$SUB_PATH"
  fi
  printf '信息文件：%s（仅 root 可读）\n' "$PANEL_INFO_FILE"
}

show_saved_nodes() {
  echo
  printf '%b\n' "${CYAN}节点信息${RESET}"
  if [[ -r "$NODE_INFO_FILE" ]]; then
    cat "$NODE_INFO_FILE"
  elif [[ -r /root/s-ui-recommended-nodes.txt ]]; then
    warn "S-UI 尚未自动创建可导入节点，下面是面板内的推荐配置入口："
    cat /root/s-ui-recommended-nodes.txt
  else
    info "尚未保存可直接导入客户端的节点链接。"
  fi
}

show_access_hint() {
  local panel="$1" scheme="$2" host="$3" port="$4" path="$5"
  echo
  say "${panel} 已安装完成。"
  info "后台地址：${scheme}://${host}:${port}${path}"
  info "本脚本不会限制端口；若外网打不开，请检查云服务商安全组。"
}

create_recommended_3x_nodes() {
  local username="$1" password="$2" panel_port="$3" panel_path="$4"
  local main_port backup_port xray_bin keypair private_key public_key short_id uuid ss_password
  local cookie_file main_payload backup_payload panel_base panel_scheme main_result backup_result
  local server_ip display_host ss_userinfo vless_link ss_link

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

  keypair="$("$xray_bin" x25519 2>/dev/null || true)"
  private_key="$(awk -F':[[:space:]]*' 'tolower($1) ~ /^private ?key$/ {print $2; exit}' <<<"$keypair")"
  public_key="$(awk -F':[[:space:]]*' 'tolower($1) ~ /^(public ?key|password)$/ {print $2; exit}' <<<"$keypair")"
  if [[ -z "$private_key" || -z "$public_key" ]]; then
    warn "无法生成 Reality 密钥，已跳过自动创建推荐节点。"
    return
  fi
  short_id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  ss_password="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  cookie_file="$(mktemp)"
  main_payload="$(mktemp)"
  backup_payload="$(mktemp)"
  panel_scheme="$(detect_web_scheme "$panel_port")"
  panel_base="${panel_scheme}://127.0.0.1:${panel_port}/${panel_path}"

  if ! curl -kfsS -c "$cookie_file" --data-urlencode "username=${username}" --data-urlencode "password=${password}" "${panel_base}/login" >/dev/null; then
    rm -f "$cookie_file" "$main_payload" "$backup_payload"
    warn "无法登录 3x-ui API，已保留面板安装结果，但跳过自动创建节点。"
    return
  fi
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

  main_result="$(curl -kfsS -b "$cookie_file" -H 'Content-Type: application/json' --data-binary "@${main_payload}" "${panel_base}/panel/api/inbounds/add" || true)"
  backup_result="$(curl -kfsS -b "$cookie_file" -H 'Content-Type: application/json' --data-binary "@${backup_payload}" "${panel_base}/panel/api/inbounds/add" || true)"
  rm -f "$cookie_file" "$main_payload" "$backup_payload"

  if [[ "$main_result" == *'"success":true'* && "$backup_result" == *'"success":true'* ]]; then
    server_ip="$(get_server_ip)"
    display_host="$(url_host "$server_ip")"
    ss_userinfo="$(printf '2022-blake3-aes-256-gcm:%s' "$ss_password" | base64 | tr -d '\n=' | tr '+/' '-_')"
    vless_link="vless://${uuid}@${display_host}:${main_port}?type=tcp&security=reality&pbk=${public_key}&fp=chrome&sni=www.microsoft.com&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#Roy-Main-Reality"
    ss_link="ss://${ss_userinfo}@${display_host}:${backup_port}#Roy-Backup-SS2022"
    install -d -m 700 "$ROY_DATA_DIR"
    cat >"$NODE_INFO_FILE" <<EOF
主用节点：VLESS + Reality + Vision
端口：${main_port}
导入链接：
${vless_link}

备用节点：Shadowsocks 2022
端口：${backup_port}
导入链接：
${ss_link}
EOF
    chmod 600 "$NODE_INFO_FILE"
    systemctl restart x-ui >/dev/null 2>&1 || true
    say "已创建主用 VLESS Reality 和备用 Shadowsocks 2022 节点。"
    info "完整节点链接已保存到：${NODE_INFO_FILE}"
    show_saved_nodes
  else
    warn "推荐节点创建未完成。请在面板中手动检查入站列表，未成功的请求不会影响面板本身。"
  fi
}

create_s_ui_node_entry() {
  local panel_port="$1" panel_path="$2" panel_scheme="$3" host guide_file="/root/s-ui-recommended-nodes.txt"
  host="$(url_host "$(get_server_ip)")"
  cat >"$guide_file" <<EOF
无域名推荐方案
1. 主用：VLESS + Reality + Vision
   建议端口：443（被占用时可换其他端口）
   Reality 目标/SNI：www.microsoft.com:443 / www.microsoft.com
   Flow：xtls-rprx-vision
   在面板中生成 Reality 密钥、Short ID 和客户端 UUID

2. 备用：Shadowsocks 2022
   建议端口：8443
   加密方式：2022-blake3-aes-256-gcm
   网络：TCP + UDP
   在面板中生成随机密码

有域名推荐方案
主用：Hysteria2 + TLS
备用：VLESS + Reality + Vision

请在 S-UI 后台的入站页面创建以上节点。面板地址：
${panel_scheme}://${host}:${panel_port}${panel_path}
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
  local username password port path installer_file log_file server_ip panel_scheme
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
  server_ip="$(get_server_ip)"
  panel_scheme="$(detect_web_scheme "$port")"
  save_panel_info "3x-ui" "$server_ip" "$port" "/${path}" "$username" "$password" "" "" "$panel_scheme" "http"
  create_recommended_3x_nodes "$username" "$password" "$port" "$path"
  echo
  info "后台用户名：${username}"
  info "后台密码：${password}"
  show_access_hint '3x-ui' "$panel_scheme" "$(url_host "$server_ip")" "$port" "/${path}"
  info "以后输入 roy，再选择“查看面板、登录信息、节点与安全服务状态”即可重新查看。"
}

install_s_ui_chinese() {
  local username password panel_port panel_path sub_port sub_path installer_file log_file server_ip panel_scheme sub_scheme
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
  server_ip="$(get_server_ip)"
  panel_scheme="$(detect_web_scheme "$panel_port")"
  sub_scheme="$(detect_web_scheme "$sub_port")"
  save_panel_info "S-UI" "$server_ip" "$panel_port" "$panel_path" "$username" "$password" "$sub_port" "$sub_path" "$panel_scheme" "$sub_scheme"
  echo
  info "后台用户名：${username}"
  info "后台密码：${password}"
  show_access_hint 'S-UI' "$panel_scheme" "$(url_host "$server_ip")" "$panel_port" "$panel_path"
  info "订阅地址：${sub_scheme}://$(url_host "$server_ip"):${sub_port}${sub_path}"
  create_s_ui_node_entry "$panel_port" "$panel_path" "$panel_scheme"
  info "以后输入 roy，再选择“查看面板、登录信息、节点与安全服务状态”即可重新查看。"
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
}

show_service_status() {
  echo
  show_saved_panel_info
  show_saved_nodes
  echo
  printf '%b\n' "${CYAN}服务运行状态${RESET}"
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

  if [[ ! -r "$PANEL_INFO_FILE" ]]; then
    if command -v x-ui >/dev/null 2>&1; then
      echo
      info "尝试读取现有 3x-ui 设置："
      x-ui settings 2>/dev/null || true
    elif [[ -x /usr/local/s-ui/sui ]]; then
      echo
      info "尝试读取现有 S-UI 地址与管理员信息："
      /usr/local/s-ui/sui uri 2>/dev/null || true
      /usr/local/s-ui/sui admin -show 2>/dev/null || true
    fi
  fi

  echo
  info "3x-ui 安装日志：/var/log/vps-panel-3x-ui-install.log"
  info "S-UI 安装日志：/var/log/vps-panel-s-ui-install.log"
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
6) 查看面板、登录信息、节点与安全服务状态
0) 退出
EOF
    read -r -p "请输入选项 [0-6]: " choice
    case "$choice" in
      1) run_optimization; pause ;;
      2) configure_network_acceleration; pause ;;
      3) run_security_hardening; pause ;;
      4) run_installer "3x-ui" 'xui'; pause ;;
      5) run_installer "S-UI" 'sui'; pause ;;
      6) show_service_status; pause ;;
      0) info "已退出。"; exit 0 ;;
      *) warn "请输入 0 到 6 之间的数字。"; pause ;;
    esac
  done
}

require_root
install_shortcut
offer_disable_existing_ufw
main_menu
