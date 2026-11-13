#!/bin/bash

# ==========================================
# HiNAS WiFi 控制面板 (终极进化版)
# 项目地址: https://github.com/ioiy/hinas-wifi
# v1.9.7: watchdog v3.5 ping-only 监控 — 正常时只 ping 不碰驱动, 解决 RTL8188FU 频繁断线
# v2.0.0: watchdog v3.5 ping-only + 省电模式保持开启(实测稳定) — 解决 RTL8188FU 频繁断线
# v2.1.0: IPv6 模式开关 — NM ignore 避免路由器 IPv6 不稳定拖垮 DHCPv4
# v2.2.0: BSSID 锁定/解除 — 双AP同名SSID环境防漫游互踢
# v2.3.2: BSSID提取修复(cut f2->f2-), scan_wifi_iw tab匹配修复, 非打印字符清理
# v2.3.1: 自动热点救生 — 无WiFi连接时自动开热点, 热点时定期探测恢复

VERSION="2.3.2"
UPDATE_URL="https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh"
WATCHDOG_SCRIPT="/usr/local/bin/wifi_watchdog.sh"
KEEPALIVE_SCRIPT="/usr/local/bin/wifi_keepalive.sh"
AUTO_HOTSPOT_SCRIPT="/usr/local/bin/wifi_auto_hotspot.sh"
AUTO_HOTSPOT_CONFIG="/etc/hinaswifi/auto_hotspot.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")

# --- root 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
 echo -e "${RED}需要 root 权限运行。请使用 sudo 或以 root 身份执行。${NC}"
 exit 1
fi

if [ ! -x "/usr/bin/wifi" ] || [ "$(readlink -f /usr/bin/wifi)" != "$SCRIPT_PATH" ]; then
 ln -sf "$SCRIPT_PATH" /usr/bin/wifi
 chmod +x "$SCRIPT_PATH"
fi

# --- Helper 函数 ---
get_wifi_iface() {
 local IF
 IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
 [ -z "$IF" ] && IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
 [ -z "$IF" ] && IF="wlan0"
 echo "$IF"
}

get_wifi_conn() {
 local IF
 IF=$(get_wifi_iface)
 local CONN
 CONN=$(nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
 [ -z "$CONN" ] || [ "$CONN" == "--" ] && CONN=""
 # v1.9.5: 设备断开时从已保存的 WiFi 连接里找
 if [ -z "$CONN" ]; then
 CONN=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":802-11-wireless$" | cut -d: -f1 | head -1)
 fi
 echo "$CONN"
}

get_wifi_driver() {
 local DRV
 DRV=$(lsmod 2>/dev/null | grep -iE "rtl8188|rtl8xxxu|8188" | awk '{print $1}' | head -n 1)
 [ -z "$DRV" ] && DRV="rtl8188fu"
 echo "$DRV"
}
# iw 底层扫描 — 比 nmcli 更可靠, 能在已连接状态下扫到更多 AP
# 输出格式: BSSID:SSID:SIGNAL:FREQ
scan_wifi_iw() {
 local IF=${1:-$(get_wifi_iface)}
 timeout 15 iw dev "$IF" scan 2>/dev/null | awk '
 /^BSS / {
     if (bssid != "") {
         gsub(/[^[:print:]]/, "", ssid)
         if (ssid != "" && signal != "" && freq != "")
             print bssid ":" ssid ":" signal ":" freq
     }
     bssid=$2
     gsub(/\\(.*\\)/, "", bssid)
     ssid=""; signal=""; freq=""
 }
 /\tSSID:/ { sub(/.*SSID: /, ""); ssid=$0 }
 /\tsignal:/ { signal=$2 }
 /\tfreq:/ { freq=$2 }
 END {
     if (bssid != "") {
         gsub(/[^[:print:]]/, "", ssid)
         if (ssid != "" && signal != "" && freq != "")
             print bssid ":" ssid ":" signal ":" freq
     }
 }
 '
}

# 合并扫描: nmcli + iw, 去重
scan_wifi_all() {
 local IF=${1:-$(get_wifi_iface)}
 local TMPFILE; TMPFILE=$(mktemp)
 nmcli -t -f BSSID,SSID,SIGNAL,FREQ dev wifi list 2>/dev/null > "$TMPFILE"
 scan_wifi_iw "$IF" >> "$TMPFILE"
 sort -u "$TMPFILE" | awk -F: '{
     bssid=substr($0,1,17)
     if (!(bssid in seen)) { seen[bssid]=1; print $0 }
 }'
 rm -f "$TMPFILE"
}


# 获取 WiFi 信号强度 (dBm)
get_signal_strength() {
 local IF=${1:-$(get_wifi_iface)}
 iw dev "$IF" link 2>/dev/null | grep -oP 'signal: \K[-0-9]+'
}

# IP 地址格式校验
validate_ip() {
 local ip=$1
 if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
 IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
 [ "$o1" -le 255 ] 2>/dev/null && [ "$o2" -le 255 ] 2>/dev/null && \
 [ "$o3" -le 255 ] 2>/dev/null && [ "$o4" -le 255 ] 2>/dev/null
 else
 return 1
 fi
}


check_network() {
 local IF
 IF=$(get_wifi_iface)
 local WIFI_STATE
 WIFI_STATE=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
 if [ "$WIFI_STATE" != "connected" ] && [ "$WIFI_STATE" != "connecting" ]; then
 return 1
 fi
 ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && return 0
 ping -c 2 -W 3 119.29.29.29 >/dev/null 2>&1 && return 0
 timeout 5 ping6 -c 2 -W 2 2408:8899::8 >/dev/null 2>&1 && return 0
 return 1
}

update_script() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 在线检测与更新控制面板 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 echo -e "${YELLOW}正在检测外网连接与云端版本...${NC}"
 if ! check_network; then
 echo -e "${RED}❌ 无网络连接，无法获取更新！请先连接 WiFi 或网线。${NC}"
 sleep 3; return
 fi
 # 依次尝试: ghfast代理 → GitHub直连 → ghproxy镜像, 每个最多8秒
 for U in "$UPDATE_URL" \
   "https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh" \
   "https://ghproxy.com/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh"; do
  CLOUD_VERSION=$(timeout 8 wget -qO- --timeout=5 --tries=1 "$U" 2>/dev/null | grep -E "^VERSION=" | head -n 1 | cut -d\" -f2)
  [ -n "$CLOUD_VERSION" ] && break
 done
 if [ -z "$CLOUD_VERSION" ]; then
 echo -e "${RED}❌ 获取云端版本失败。${NC}"
 sleep 3; return
 fi
 echo -e "当前本地版本: ${CYAN}v${VERSION}${NC}"
 echo -e "发现云端版本: ${GREEN}v${CLOUD_VERSION}${NC}"
 echo "--------------------------------------"
 local FORCE=0
 if [ "$VERSION" == "$CLOUD_VERSION" ]; then
 echo -e "${GREEN}✅ 当前已是最新版本${NC}"
 echo "--------------------------------------"
 echo "1. 强制替换 (同版本覆盖, 用于修复热更新)"
 echo "0. 返回主菜单"
 read -p "选项: " upd_choice
 [ "$upd_choice" != "1" ] && return
 FORCE=1
 echo -e "${YELLOW}⚠ 强制替换: 用云端代码覆盖本地${NC}"
 else
 read -p "是否更新到 v${CLOUD_VERSION}？(y/n): " confirm
 if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
 echo -e "${YELLOW}已取消更新。${NC}"; sleep 1; return
 fi
 fi
 echo -e "${GREEN}正在下载最新代码...${NC}"
 local DL_OK=0
 for U in "$UPDATE_URL" \
   "https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh" \
   "https://ghproxy.com/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh"; do
  if timeout 30 wget -q --timeout=10 --tries=1 -O /tmp/hinaswifi.sh.tmp "$U" 2>/dev/null; then
   DL_OK=1; break
  fi
 done
 if [ "$DL_OK" = "1" ]; then
 if ! grep -q "^VERSION=" /tmp/hinaswifi.sh.tmp; then
 echo -e "${RED}❌ 下载的文件不合法(缺少VERSION行)，已放弃更新。${NC}"
 rm -f /tmp/hinaswifi.sh.tmp; sleep 3; return
 fi
 cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak" 2>/dev/null
 echo -e "${YELLOW}已备份当前版本到 ${SCRIPT_PATH}.bak${NC}"
 cat /tmp/hinaswifi.sh.tmp > "$SCRIPT_PATH"
 chmod +x "$SCRIPT_PATH"
 rm -f /tmp/hinaswifi.sh.tmp
 echo -e "${GREEN}🎉 更新成功！正在重新启动面板...${NC}"
 sleep 2
 exec bash "$SCRIPT_PATH"
 else
 echo -e "${RED}❌ 下载失败。${NC}"
 rm -f /tmp/hinaswifi.sh.tmp; sleep 3
 fi
}

# --- Keepalive 脚本生成 ---
setup_keepalive() {
 local action=$1 # on/off
 cat > "$KEEPALIVE_SCRIPT" << 'KAEOF'
#!/bin/bash
# WiFi Keepalive v2 — 每分钟 ping 网关3包+外网1包, 保持连接活跃
GATEWAY=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -1)
[ -z "$GATEWAY" ] && exit 0
ping -c 3 -W 2 "$GATEWAY" >/dev/null 2>&1
ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1
KAEOF
 chmod +x "$KEEPALIVE_SCRIPT"
 if [ "$action" = "on" ]; then
 (crontab -l 2>/dev/null | grep -v "$KEEPALIVE_SCRIPT"; echo "* * * * * $KEEPALIVE_SCRIPT") | crontab -
 else
 crontab -l 2>/dev/null | grep -v "$KEEPALIVE_SCRIPT" | crontab -
 fi
}

toggle_watchdog() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} WiFi 防掉线守护进程 v3.5 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 EXISTING_CRON=$(crontab -l 2>/dev/null | grep "$WATCHDOG_SCRIPT")
 if [ -n "$EXISTING_CRON" ]; then
 CURRENT_INTERVAL=$(echo "$EXISTING_CRON" | awk '{print $1}' | cut -d'/' -f2)
 [ "$CURRENT_INTERVAL" = "*" ] && CURRENT_INTERVAL="1"
 [ -z "$CURRENT_INTERVAL" ] && CURRENT_INTERVAL="未知"
 echo -e "自动重连: ${GREEN}▶ 已开启 (每 $CURRENT_INTERVAL 分钟检测)${NC}"
 else
 echo -e "自动重连: ${RED}⏸ 未开启${NC}"
 fi
 KA_CRON=$(crontab -l 2>/dev/null | grep "$KEEPALIVE_SCRIPT")
 if [ -n "$KA_CRON" ]; then
 echo -e "连接保活: ${GREEN}▶ 已开启 (每分钟 ping 网关)${NC}"
 else
 echo -e "连接保活: ${RED}⏸ 未开启${NC}"
 fi
 local IF
 IF=$(get_wifi_iface)
 local PS_STATE
 PS_STATE=$(iw dev "$IF" get power_save 2>/dev/null | awk '{print $3}')
 if [ "$PS_STATE" = "on" ]; then
 echo -e "省电模式: ${GREEN}开启 (正常)${NC}"
 else
 echo -e "省电模式: ${GREEN}已关闭${NC}"
 fi
 local SIG
 SIG=$(get_signal_strength "$IF")
 if [ -n "$SIG" ]; then
 if [ "$SIG" -lt -70 ]; then
 echo -e "信号强度: ${RED}${SIG} dBm (较弱)${NC}"
 elif [ "$SIG" -lt -60 ]; then
 echo -e "信号强度: ${YELLOW}${SIG} dBm (一般)${NC}"
 else
 echo -e "信号强度: ${GREEN}${SIG} dBm (良好)${NC}"
 fi
 else
 echo -e "信号强度: ${YELLOW}未获取${NC}"
 fi
 echo "--------------------------------------"
 echo "1. 开启/修改自动重连 (可自定义检测间隔)"
 echo "2. 关闭自动重连"
 echo "3. 查看自动重连日志"
 echo -e "4. ${GREEN}开启/关闭 连接保活${NC} (v3.5下已冗余, 建议关闭)"
 echo -e "5. ${GREEN}查看故障快照${NC} (断网诊断)"
 echo "0. 返回主菜单"
 echo -e "${CYAN}======================================${NC}"
 read -p "请输入选项: " wd_choice
 case $wd_choice in
 1)
 read -p "请输入检测间隔(分钟，回车默认1分钟): " interval
 if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
 interval=1
 echo -e "${YELLOW}使用默认间隔: 1 分钟 (ping-only 开销极低)${NC}"
 fi
 CRON_JOB="*/$interval * * * * $WATCHDOG_SCRIPT"
 echo "正在配置后台守护进程..."
 cat > "$WATCHDOG_SCRIPT" << 'WD1'
#!/bin/bash
# WiFi Watchdog v3.5 — ping-only 监控, 正常时不碰驱动 (解决 RTL8188FU 频繁断线)
exec 200>/tmp/wifi_watchdog.lock
flock -n 200 || exit 0

LOG_FILE="/var/log/wifi_watchdog.log"
STATS_FILE="/var/log/wifi_watchdog.stats"
SNAPSHOT_DIR="/var/log/wifi_debug"
MAX_LOG_LINES=2000
MAX_SNAPSHOTS=10

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

detect_iface() {
 local IF
 IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
 [ -z "$IF" ] && IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
 [ -z "$IF" ] && IF="wlan0"
 echo "$IF"
}

detect_conn() {
 local IF; IF=$(detect_iface)
 local CONN; CONN=$(nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
 [ -z "$CONN" ] || [ "$CONN" = "--" ] && CONN=""
 # v3.3: 设备断开时从已保存的 WiFi 连接里找
 if [ -z "$CONN" ]; then
 CONN=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":802-11-wireless$" | cut -d: -f1 | head -1)
 fi
 echo "$CONN"
}

get_signal() { iw dev "$1" link 2>/dev/null | grep -oP 'signal: \K[-0-9]+'; }

categorize_reason() {
 local IF=$1 reason="unknown" recent_dmesg
 recent_dmesg=$(dmesg 2>&1 | tail -50)
 local nm_log
 nm_log=$(journalctl -u NetworkManager --since "3 min ago" --no-pager 2>/dev/null)
 if echo "$nm_log" | grep -qiE "rekey.*fail|GTK.*fail|group.*key.*fail|group.*rekey.*timeout"; then
 reason="gtk_rekey_fail"
 elif echo "$nm_log" | grep -qiE "dhcp.*fail|lease.*expired|dhcp4.*timeout"; then
 reason="dhcp_fail"
 elif echo "$recent_dmesg" | grep -qiE "deauth|disassoc"; then
 reason="deauth"
 elif echo "$recent_dmesg" | grep -qiE "firmware|rtl8188.*error|.*fail.*rtl"; then
 reason="driver_error"
 elif echo "$recent_dmesg" | grep -qiE "usb.*disconnect|usb.*reset|usb.*error"; then
 reason="usb_disconnect"
 else
 local sig; sig=$(get_signal "$IF")
 if [ -n "$sig" ] 2>/dev/null && [ "$sig" -lt -75 ] 2>/dev/null; then
 reason="signal_weak(${sig}dBm)"
 fi
 fi
 echo "$reason"
}

start_timer() { START_TIME=$(date +%s); }
elapsed_time() { echo $(( $(date +%s) - START_TIME )); }

log_stats() {
 echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|${3}s|$4" >> "$STATS_FILE"
 tail -n 500 "$STATS_FILE" > "${STATS_FILE}.tmp" 2>/dev/null && mv "${STATS_FILE}.tmp" "$STATS_FILE"
}


check_net() {
 ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && return 0
 ping -c 2 -W 3 119.29.29.29 >/dev/null 2>&1 && return 0
 return 1
}
WD1
 cat >> "$WATCHDOG_SCRIPT" << 'WD2'

capture_snapshot() {
 local tag=$1 IF=$2
 mkdir -p "$SNAPSHOT_DIR"
 local ts; ts=$(date '+%Y%m%d_%H%M%S')
 local snapdir="$SNAPSHOT_DIR/${ts}_${tag}"
 mkdir -p "$snapdir"
 dmesg 2>&1 | tail -50 > "$snapdir/dmesg.txt"
 iw dev "$IF" link 2>&1 > "$snapdir/iw_link.txt"
 iw dev "$IF" info 2>&1 > "$snapdir/iw_info.txt"
 nmcli dev status 2>&1 > "$snapdir/nmcli_dev.txt"
 nmcli -t -f all dev show "$IF" 2>&1 > "$snapdir/nmcli_show.txt"
 ip addr show "$IF" 2>&1 > "$snapdir/ip_addr.txt"
 ip route 2>&1 > "$snapdir/ip_route.txt"
 lsusb 2>&1 > "$snapdir/lsusb.txt"
 lsmod 2>&1 | grep -iE "rtl|8188|wifi|usb" > "$snapdir/lsmod.txt" 2>&1
 cat /etc/resolv.conf 2>/dev/null > "$snapdir/resolv.conf"
 iwlist "$IF" scanning 2>/dev/null | head -80 > "$snapdir/scan.txt"
 ps aux 2>&1 | grep -iE "wifi|nmcli|wpa|dhcp" | grep -v grep > "$snapdir/ps.txt"
 uptime 2>&1 > "$snapdir/uptime.txt"
 free -m 2>&1 > "$snapdir/mem.txt"
 log " 快照已保存: $snapdir"
 local count; count=$(ls -d "$SNAPSHOT_DIR"/*_* 2>/dev/null | wc -l)
 if [ "$count" -gt "$MAX_SNAPSHOTS" ]; then
 ls -dt "$SNAPSHOT_DIR"/*_* 2>/dev/null | tail -n +$((MAX_SNAPSHOTS + 1)) | while read -r old; do rm -rf "$old"; done
 fi
}

rotate_log() {
 [ ! -f "$LOG_FILE" ] && return
 local lines; lines=$(wc -l < "$LOG_FILE")
 if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
 tail -n $((MAX_LOG_LINES / 2)) "$LOG_FILE" > "$LOG_FILE.tmp"
 mv "$LOG_FILE.tmp" "$LOG_FILE"
 log "日志已轮转 (保留最近 $((MAX_LOG_LINES / 2)) 行)"
 fi
}

recover_with_patience() {
 local level=$1 patience=$2 IF=$3 rc=1
 case $level in
 1)
 local CONN; CONN=$(detect_conn)
 if [ -n "$CONN" ]; then
 log " L1: nmcli con up ($CONN), 等待 ${patience}s..."
 nmcli con up "$CONN" >/dev/null 2>&1; rc=$?
 log " L1: nmcli 返回 $rc"
 sleep "$patience"
 if check_net; then rc=0; log " L1: ✅ 网络恢复"; fi
 else
 log " L1: 无连接名, 跳过"
 fi ;;
 2)
 log " L2: WiFi radio off→on, 等待 ${patience}s..."
 nmcli radio wifi off >/dev/null 2>&1; sleep 3
 nmcli radio wifi on >/dev/null 2>&1; sleep 5
 local CONN; CONN=$(detect_conn)
 [ -n "$CONN" ] && nmcli con up "$CONN" >/dev/null 2>&1; rc=$?
 log " L2: radio 重启完成, nmcli 返回 $rc"
 sleep "$patience"
 if check_net; then rc=0; log " L2: ✅ 网络恢复"; fi ;;
 3)
 log " L3: ip link down→up (软重启网卡), 等待 ${patience}s..."
 log " (不使用 rmmod/modprobe — 内置USB WiFi热拔驱动不安全)"
 ip link set "$IF" down 2>/dev/null; sleep 3
 ip link set "$IF" up 2>/dev/null; sleep 5
 local CONN; CONN=$(detect_conn)
 [ -n "$CONN" ] && nmcli con up "$CONN" >/dev/null 2>&1; rc=$?
 log " L3: ip link 重启完成, nmcli 返回 $rc"
 sleep "$patience"
 if check_net; then rc=0; log " L3: ✅ 网络恢复"; fi ;;
 4)
 log " L4: 重启 NetworkManager, 等待 ${patience}s..."
 systemctl restart NetworkManager >/dev/null 2>&1; rc=$?
 log " L4: NM 重启返回 $rc"
 # v3.3: 等 NM 真正就绪, 不死等
 local waited=0
 while [ "$waited" -lt "$patience" ]; do
 systemctl is-active NetworkManager >/dev/null 2>&1 && break
 sleep 2; waited=$((waited + 2))
 done
 sleep 5 # 再等 5 秒让设备枚举完成
 IF=$(detect_iface)
 local CONN; CONN=$(detect_conn)
 [ -n "$CONN" ] && nmcli con up "$CONN" >/dev/null 2>&1
 if check_net; then rc=0; log " L4: ✅ 网络恢复"; fi ;;
 esac
 return $rc
}

# v3.3: 恢复成功后的收尾工作
post_recover() {
 local IF=$1
 # 禁用后台扫描 (防止扫描导致再次断线)
 local CONN; CONN=$(detect_conn)
 [ -n "$CONN" ] && nmcli con mod "$CONN" wifi.bgscan "" 2>/dev/null
 # 省电由用户控制, 不自动关
}
WD2
 cat >> "$WATCHDOG_SCRIPT" << 'WD3'

# ========== 主循环 (v3.5: ping-only, 正常时不碰驱动) ==========
rotate_log
GW=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -1)
if [ -n "$GW" ] && ping -c 2 -W 3 "$GW" >/dev/null 2>&1; then
 OK_COUNT_FILE="/tmp/wifi_wd_ok_count"
 OK_COUNT=$(cat "$OK_COUNT_FILE" 2>/dev/null || echo 0)
 OK_COUNT=$((OK_COUNT + 1))
 echo "$OK_COUNT" > "$OK_COUNT_FILE"
 if [ $((OK_COUNT % 30)) -eq 0 ]; then
 log "✅ 网络正常 (第${OK_COUNT}次巡逻) 网关=$GW"
 fi
 exit 0
fi
if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 || ping -c 2 -W 3 119.29.29.29 >/dev/null 2>&1; then
 exit 0
fi
IF=$(detect_iface)
CONN=$(detect_conn)
SIG=$(get_signal "$IF")
if [ -n "$SIG" ]; then
 log "⚠ 检测到断网 — IF=$IF CONN=$CONN 信号=${SIG}dBm"
else
 log "⚠ 检测到断网 — IF=$IF CONN=$CONN 信号=无"
fi
start_timer
REASON=$(categorize_reason "$IF")
log " 断网原因: $REASON"
for level in 1 2 3 4; do
 case $level in 1) p=60 ;; 2) p=90 ;; 3) p=120 ;; 4) p=90 ;; esac
 recover_with_patience "$level" "$p" "$IF"
 if [ $? -eq 0 ]; then
 DUR=$(elapsed_time)
 log "✅ 恢复成功 (L${level}), 耗时 ${DUR}s, 原因: $REASON"
 log_stats "success" "L${level}" "$DUR" "$REASON"
 post_recover "$IF"
 exit 0
 fi
done
DUR=$(elapsed_time)
log "❌ 全部恢复失败, 耗时 ${DUR}s, 原因: $REASON"
log_stats "fail" "L4" "$DUR" "$REASON"
capture_snapshot "recovery_failed" "$IF"
exit 1
WD3
 chmod +x "$WATCHDOG_SCRIPT"
 (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_JOB") | crontab -
 echo -e "${GREEN}✅ 自动重连已开启 (每 $interval 分钟检测)${NC}"
 echo -e "${YELLOW}watchdog v3.5: ping-only 监控, 正常时不碰驱动${NC}"
 sleep 3
 ;;
 2)
 crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT" | crontab -
 echo -e "${GREEN}✅ 已关闭自动重连${NC}"
 sleep 2
 ;;
 3)
 clear
 echo -e "${CYAN}===== 自动重连日志 (最后100行) =====${NC}"
 if [ -f /var/log/wifi_watchdog.log ]; then
 tail -n 100 /var/log/wifi_watchdog.log
 else
 echo -e "${YELLOW}暂无日志。${NC}"
 fi
 echo "--------------------------------------"
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 4)
 KA_CRON=$(crontab -l 2>/dev/null | grep "$KEEPALIVE_SCRIPT")
 if [ -n "$KA_CRON" ]; then
 setup_keepalive "off"
 echo -e "${GREEN}✅ 已关闭连接保活${NC}"
 else
 setup_keepalive "on"
 echo -e "${GREEN}✅ 已开启连接保活${NC}"
 echo -e "${YELLOW}⚠ v3.5 watchdog 已含 ping, keepalive 冗余, 建议关闭${NC}"
 fi
 sleep 2
 ;;
 5)
 clear
 echo -e "${CYAN}===== 故障快照查看 =====${NC}"
 if [ -d /var/log/wifi_debug ] && [ -n "$(ls -A /var/log/wifi_debug 2>/dev/null)" ]; then
 echo "可用快照:"
 ls -dt /var/log/wifi_debug/*_* 2>/dev/null | head -10 | while read -r d; do
 echo " $(basename "$d")"
 done
 echo "--------------------------------------"
 read -p "输入快照名查看详情(回车返回): " snap_name
 if [ -n "$snap_name" ] && [ -d "/var/log/wifi_debug/$snap_name" ]; then
 clear
 echo -e "${CYAN}===== $snap_name =====${NC}"
 for f in /var/log/wifi_debug/"$snap_name"/*; do
 echo -e "\n${YELLOW}--- $(basename "$f") ---${NC}"
 cat "$f" 2>/dev/null | head -30
 done
 read -n 1 -s -r -p "按任意键返回..."
 fi
 else
 echo -e "${YELLOW}暂无故障快照。${NC}"
 sleep 2
 fi
 ;;
 0) return ;;
 esac
}

# --- 网络信息与体检 (合并 show_network_info + network_diagnose) ---
show_network_info() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 网络信息与体检 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 echo -e "${YELLOW}正在获取...${NC}"

 # 基本信息
 MAC_ADDR=$(ip link show "$WIFI_IF" 2>/dev/null | awk '/ether/ {print $2}')
 [ -z "$MAC_ADDR" ] && MAC_ADDR="未知"
 LAN_IP=$(ip -4 addr show dev "$WIFI_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
 [ -z "$LAN_IP" ] && LAN_IP="未分配"
 IPV6_ADDR=$(ip -6 addr show dev "$WIFI_IF" 2>/dev/null | grep "scope global" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
 [ -z "$IPV6_ADDR" ] && IPV6_ADDR="无"
 GATEWAY=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
 [ -z "$GATEWAY" ] && GATEWAY="未知"
 DNS=$(grep -m 1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}')
 [ -z "$DNS" ] && DNS="未知"
 PUBLIC_IP=$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo "获取失败")
 PS_STATE=$(iw dev "$WIFI_IF" get power_save 2>/dev/null | awk '{print $3}')
 WIFI_DRIVER=$(get_wifi_driver)
 SSID=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2 | head -1)
 [ -z "$SSID" ] && SSID="未连接"
 SIG=$(get_signal_strength "$WIFI_IF")

 echo "--------------------------------------"
 echo -e "接口: ${GREEN}$WIFI_IF${NC}"
 echo -e "驱动: ${GREEN}$WIFI_DRIVER${NC}"
 echo -e "SSID: ${GREEN}$SSID${NC}"
 echo -e "MAC: ${GREEN}$MAC_ADDR${NC}"
 echo -e "IPv4: ${GREEN}$LAN_IP${NC}"
 echo -e "IPv6: ${GREEN}$IPV6_ADDR${NC}"
 echo -e "网关: ${GREEN}$GATEWAY${NC}"
 echo -e "DNS: ${GREEN}$DNS${NC}"
 echo -e "公网IP: ${GREEN}$PUBLIC_IP${NC}"
 if [ -n "$SIG" ]; then
 if [ "$SIG" -lt -70 ]; then
 echo -e "信号: ${RED}${SIG} dBm (较弱)${NC}"
 elif [ "$SIG" -lt -60 ]; then
 echo -e "信号: ${YELLOW}${SIG} dBm (一般)${NC}"
 else
 echo -e "信号: ${GREEN}${SIG} dBm (良好)${NC}"
 fi
 else
 echo -e "信号: ${YELLOW}未获取${NC}"
 fi
 if [ "$PS_STATE" = "on" ]; then
 echo -e "省电: ${GREEN}开启 (正常)${NC}"
 else
 echo -e "省电: ${GREEN}已关闭${NC}"
 fi

 # 体检 (ping 测试)
 echo "--------------------------------------"
 echo -e "${CYAN}网络体检:${NC}"
 echo -n " [1] 网卡($WIFI_IF): "
 ip link show "$WIFI_IF" >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}"
 echo -n " [2] 网关($GATEWAY): "
 ping -c 2 -W 2 "$GATEWAY" >/dev/null 2>&1 && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
 echo -n " [3] DNS(223.5.5.5): "
 ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && echo -e "${GREEN}正常${NC}" || echo -e "${RED}无响应${NC}"
 echo -n " [4] 公网: "
 { ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 2 -W 2 119.29.29.29 >/dev/null 2>&1; } && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"

 echo -e "${CYAN}======================================${NC}"
 read -n 1 -s -r -p "按任意键返回..."
}

config_ip_mode() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 配置静态/动态 IP ${NC}"
 echo -e "${CYAN}======================================${NC}"
 if ! command -v nmcli >/dev/null 2>&1; then
 echo -e "${RED}无 nmcli${NC}"; sleep 2; return
 fi
 WIFI_IF=$(get_wifi_iface)
 CONN_NAME=$(get_wifi_conn)
 if [ -z "$CONN_NAME" ]; then
 echo -e "${RED}❌ 未连接 WiFi${NC}"; read -n 1 -s -r -p "按任意键返回..."; return
 fi
 echo -e "当前: ${GREEN}$CONN_NAME${NC}"
 echo "1.静态IP 2.动态IP 0.返回"
 read -p "选项: " ip_choice
 case $ip_choice in
 1)
 read -p "静态IP: " static_ip; [ -z "$static_ip" ] && return
 if ! validate_ip "$static_ip"; then
 echo -e "${RED}❌ IP 格式不合法${NC}"; sleep 2; return
 fi
 read -p "前缀(默认24): " prefix; [ -z "$prefix" ] && prefix=24
 read -p "网关: " gateway; [ -z "$gateway" ] && return
 if ! validate_ip "$gateway"; then
 echo -e "${RED}❌ 网关格式不合法${NC}"; sleep 2; return
 fi
 read -p "DNS(默认223.5.5.5): " dns; [ -z "$dns" ] && dns="223.5.5.5"
 if ! validate_ip "$dns"; then
 echo -e "${RED}❌ DNS格式不合法${NC}"; sleep 2; return
 fi
 nmcli con mod "$CONN_NAME" ipv4.addresses "$static_ip/$prefix" ipv4.gateway "$gateway" ipv4.dns "$dns" ipv4.method manual
 nmcli con down "$CONN_NAME" >/dev/null 2>&1; nmcli con up "$CONN_NAME" >/dev/null 2>&1
 [ $? -eq 0 ] && echo -e "${GREEN}✅ 成功${NC}" || echo -e "${RED}❌ 失败${NC}"
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 2)
 nmcli con mod "$CONN_NAME" ipv4.addresses "" ipv4.gateway "" ipv4.dns "" ipv4.method auto
 nmcli con down "$CONN_NAME" >/dev/null 2>&1; nmcli con up "$CONN_NAME" >/dev/null 2>&1
 [ $? -eq 0 ] && echo -e "${GREEN}✅ 已恢复DHCP${NC}" || echo -e "${RED}❌ 失败${NC}"
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 0) return ;;
 esac
}

config_priority() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 多网卡优先级 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 nmcli -t -f NAME,DEVICE,TYPE connection show --active | awk -F: '{print "▶ "$1" ("$2")"}'
 echo "--------------------------------------"
 read -p "优先连接名(回车返回): " pri_conn
 [ -z "$pri_conn" ] && return
 read -p "备用连接名(可跳过): " sec_conn
 nmcli con mod "$pri_conn" ipv4.route-metric 50 && echo -e "${GREEN}优先完成${NC}"
 [ -n "$sec_conn" ] && nmcli con mod "$sec_conn" ipv4.route-metric 100 && echo -e "${GREEN}备用完成${NC}"
 nmcli con up "$pri_conn" >/dev/null 2>&1
 ip route | grep default
 read -n 1 -s -r -p "按任意键返回..."
}

run_speedtest() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 网络测速 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 echo "1. 国内测速 (腾讯/阿里 CDN)"
 echo "2. 国外测速 (Cloudflare/tele2)"
 echo "3. 双向对比 (国内+国外)"
 echo "0. 返回"
 read -p "选项: " st_choice
 [ "$st_choice" = "0" ] && return
 [ -z "$st_choice" ] && st_choice="1"
 echo "--------------------------------------"

 local speed mbps

 _test_urls() {
 local label="$1"; shift
 echo -e "${YELLOW}${label}...${NC}"
 local s
 for url in "$@"; do
 s=$(curl -L -o /dev/null -s -w "%{speed_download}" --connect-timeout 10 --max-time 30 "$url" 2>/dev/null)
 if [ -n "$s" ] && [ "$s" != "0" ] && [ "$s" != "0.000" ]; then
 break
 fi
 done
 if [ -n "$s" ] && [ "$s" != "0" ] && [ "$s" != "0.000" ]; then
		mbps=$(awk -v s=$s 'BEGIN{printf "%.2f", s / 125000}')
 echo -e "  ${label}: ${GREEN}${mbps} Mbps${NC}"
 else
 echo -e "  ${label}: ${RED}❌ 不可达${NC}"
 fi
 }

 case $st_choice in
 1) _test_urls "国内测速" "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso" "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-NetInstall-2009.iso" "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-DVD-2009.iso" ;;
 2) _test_urls "国外测速" "https://speed.cloudflare.com/__down?bytes=10000000" "http://speedtest.tele2.net/10MB.zip" ;;
 3)
 _test_urls "国内测速" "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso" "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-NetInstall-2009.iso" "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-DVD-2009.iso"
 _test_urls "国外测速" "https://speed.cloudflare.com/__down?bytes=10000000" "http://speedtest.tele2.net/10MB.zip" ;;
 *) echo -e "${RED}无效${NC}" ;;
 esac
 echo "--------------------------------------"
 read -n 1 -s -r -p "按任意键返回..."
}

install_driver() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 安装 WiFi 驱动 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 if [ -n "$WIFI_IF" ]; then
 echo -e "${GREEN}已有网卡 ($WIFI_IF)${NC}"
 read -p "强制重装?(y/n): " f; [[ "$f" != "y" ]] && return
 fi
 USB_ID=$(lsusb 2>/dev/null | grep -iE "0bda:8179|0bda:f179" | awk '{print $6}' | head -1)
 DRV=""
 [ "$USB_ID" = "0bda:8179" ] && DRV="rtl8188etv-0808.tar.gz"
 [ "$USB_ID" = "0bda:f179" ] && DRV="rtl8188ftv-0808.tar.gz"
 if [ -z "$DRV" ]; then
 echo "1.RTL8188ETV 2.RTL8188FTV 0.返回"
 read -p "选项: " d
 case $d in 1) DRV="rtl8188etv-0808.tar.gz" ;; 2) DRV="rtl8188ftv-0808.tar.gz" ;; *) return ;; esac
 fi
 mkdir -p /tmp/wifi_driver && cd /tmp/wifi_driver
 wget -q --show-progress -O "$DRV" "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/$DRV"
 wget -q -O wifi_install.sh "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/wifi_install.sh"
 [ -f "$DRV" ] && [ -f wifi_install.sh ] && bash wifi_install.sh -f "$DRV" && echo -e "${GREEN}完成${NC}" || echo -e "${RED}失败${NC}"
 cd /root; rm -rf /tmp/wifi_driver
 read -n 1 -s -r -p "按任意键返回..."
}

connect_wifi() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 扫描并连接 WiFi ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 CURRENT_SSID=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2 | head -1)
 [ -n "$CURRENT_SSID" ] && echo -e "已连接: ${GREEN}$CURRENT_SSID${NC}" || echo -e "${RED}未连接${NC}"
echo -e "${YELLOW}扫描中... (请耐心等待 5-10 秒)${NC}"
 # 修复: 只 rescan 1 次 (多次 rescan 会冲爆 RTL8188FU 芯片)
 # 修复: 去掉 timeout 15 (太短会杀掉还没扫完的 nmcli, 什么都不显示)
 nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1
 sleep 3

 # 先用 nmcli 扫, 不加 timeout 让它慢慢扫完
 NM_SCAN=$(nmcli device wifi list ifname "$WIFI_IF" 2>/dev/null)

 if [ -n "$NM_SCAN" ] && [ "$(echo "$NM_SCAN" | wc -l)" -gt 1 ]; then
  # nmcli 扫到了, 正常显示
  echo "$NM_SCAN"
 else
  # nmcli 没扫到 (RTL8188FU 连着 WiFi 时经常这样)
  # 用 iw 底层扫描做 fallback
  echo -e "${YELLOW}nmcli 扫不到, 尝试 iw 底层扫描...${NC}"
  IW_SCAN=$(timeout 20 iw dev "$WIFI_IF" scan 2>/dev/null)
  if [ -n "$IW_SCAN" ]; then
   # 解析 iw scan 输出, 格式化成类似 nmcli 的表格
   echo -e "  ${GREEN}BSSID${NC}              ${GREEN}SSID${NC}            ${GREEN}信号${NC}   ${GREEN}信道${NC}"
   echo "  ------------------  ---------------  ------  ----"
   echo "$IW_SCAN" | awk '
   /^BSS / {
       if (bssid != "" && ssid != "" && signal != "" && freq != "") {
           ch = int((freq + 0) / 1000 - 2412) / 5 + 1
           if (freq > 5000) ch = int((freq + 0) / 1000 - 5000) / 5 + 36
           printf "  %-18s  %-15s  %6s   %3d
", bssid, ssid, signal, ch
       }
       bssid=$2; gsub(/\(.*\)/, "", bssid)
       ssid=""; signal=""; freq=""
   }
   /	SSID:/ { sub(/.*SSID: /, ""); ssid=$0 }
   /	signal:/ { signal=$2 }
   /	freq:/ { freq=$2 }
   END {
       if (bssid != "" && ssid != "" && signal != "" && freq != "") {
           ch = int((freq + 0) / 1000 - 2412) / 5 + 1
           if (freq > 5000) ch = int((freq + 0) / 1000 - 5000) / 5 + 36
           printf "  %-18s  %-15s  %6s   %3d
", bssid, ssid, signal, ch
       }
   }'
  else
   echo -e "${RED}扫描失败, 请直接输入 WiFi 名称${NC}"
  fi
 fi
 echo "--------------------------------------"
 echo -e "${CYAN}提示: 如果列表不全, 可以直接输入 WiFi 名称${NC}"
 read -p "WiFi名称(回车返回): " ssid; [ -z "$ssid" ] && return
 read -s -p "密码(无密码回车): " password; echo
 if [ -z "$password" ]; then
 nmcli device wifi connect "$ssid" ifname "$WIFI_IF"
 else
 nmcli device wifi connect "$ssid" password "$password" ifname "$WIFI_IF"
 fi
 if [ $? -eq 0 ]; then
 echo -e "${GREEN}✅ 成功${NC}"
 # 省电模式由用户通过菜单15自行控制, 不自动关闭
 # v1.9.5: 禁用后台扫描 (防止扫描时短暂断线)
 local CONN_TMP; CONN_TMP=$(get_wifi_conn)
 [ -n "$CONN_TMP" ] && nmcli con mod "$CONN_TMP" wifi.bgscan "" 2>/dev/null
 # v2.1.0: 默认设 IPv6=ignore (NM不管IPv6, 内核自己处理RA), 避免路由器IPv6不稳定拖垮DHCPv4
 [ -n "$CONN_TMP" ] && nmcli con mod "$CONN_TMP" ipv6.method ignore 2>/dev/null
 sysctl -w net.ipv6.conf.${WIFI_IF}.accept_ra=1 >/dev/null 2>&1
 # v2.3.1: 连接后自动验证连通性
 echo -e "${YELLOW}正在验证连通性...${NC}"
 sleep 3
 local GW; GW=$(ip route 2>/dev/null | awk "/default/ {print $3}" | head -1)
 local NET_OK=0
 if [ -n "$GW" ]; then
 ping -c 2 -W 2 "$GW" >/dev/null 2>&1 && { echo -e "网关($GW): ${GREEN}✅${NC}"; NET_OK=1; } || echo -e "网关($GW): ${RED}❌${NC}"
 else
 echo -e "${RED}❌ 未获取到网关${NC}"
 fi
 ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && echo -e "外网: ${GREEN}✅${NC}" || { echo -e "外网: ${RED}❌ (DNS/外网不通)${NC}"; NET_OK=0; }
 if [ "$NET_OK" = "1" ]; then
 echo -e "${GREEN}✅ 连接验证通过${NC}"
 else
 echo -e "${YELLOW}⚠ 连接已建立但连通性异常, 可能需要换信道或重试${NC}"
 fi
 # 持久化 accept_ra (重启后生效)
 echo "net.ipv6.conf.${WIFI_IF}.accept_ra=1" > /etc/sysctl.d/99-hinaswifi-ipv6.conf 2>/dev/null
 else
 echo -e "${RED}❌ 失败${NC}"
 fi
 read -n 1 -s -r -p "按任意键返回..."
}

dns_optimize() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} DNS 测速优化 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 CONN=$(get_wifi_conn)
 if [ -z "$CONN" ]; then
 echo -e "${RED}❌ 未连接 WiFi${NC}"; read -n 1 -s -r -p "按任意键返回..."; return
 fi
 CURRENT_DNS=$(nmcli -t -f ipv4.dns con show "$CONN" 2>/dev/null | cut -d: -f2)
 echo -e "当前 DNS: ${GREEN}${CURRENT_DNS:-自动}${NC}"
 echo -e "${YELLOW}正在测速...${NC}"
 echo "--------------------------------------"
 DNS_LIST="223.5.5.5:阿里DNS 223.6.6.6:阿里备用 119.29.29.29:腾讯DNS 119.28.28.28:腾讯备用 180.76.76.76:百度DNS 1.1.1.1:Cloudflare"
 BEST_DNS=""
 BEST_TIME=99999
 for entry in $DNS_LIST; do
 IP=$(echo "$entry" | cut -d: -f1)
 NAME=$(echo "$entry" | cut -d: -f2)
 T1=$(ping -c 1 -W 2 "$IP" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
 [ -z "$T1" ] && { echo -e " $NAME ($IP): ${RED}无响应${NC}"; continue; }
 T2=$(ping -c 1 -W 2 "$IP" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
 T3=$(ping -c 1 -W 2 "$IP" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
		AVG=$(awk -v t1=$T1 -v t2=$T2 -v t3=$T3 'BEGIN{printf "%.1f", (t1+t2+t3)/3}')
 printf " %-12s (%s): %6s ms\n" "$NAME" "$IP" "$AVG"
 if [ -n "$AVG" ]; then
		if awk "BEGIN{exit !($AVG < $BEST_TIME)}"; then
			BEST_TIME=$AVG
			BEST_DNS="$IP"
			BEST_NAME="$NAME"
		fi
 fi
 done
 echo "--------------------------------------"
 if [ -z "$BEST_DNS" ]; then
 echo -e "${RED}❌ 所有 DNS 均无响应${NC}"
 read -n 1 -s -r -p "按任意键返回..."; return
 fi
 echo -e "最快: ${GREEN}$BEST_NAME ($BEST_DNS) ${BEST_TIME}ms${NC}"
 read -p "应用到当前连接? (y/n): " confirm
 if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
 nmcli con mod "$CONN" ipv4.dns "$BEST_DNS" ipv4.ignore-auto-dns yes
 nmcli con down "$CONN" >/dev/null 2>&1; nmcli con up "$CONN" >/dev/null 2>&1
 if [ $? -eq 0 ]; then
 echo -e "${GREEN}✅ DNS 已设为 $BEST_DNS${NC}"
 else
 echo -e "${RED}❌ 应用失败，回滚...${NC}"
 nmcli con mod "$CONN" ipv4.dns "" ipv4.ignore-auto-dns no
 nmcli con up "$CONN" >/dev/null 2>&1
 fi
 fi
 read -n 1 -s -r -p "按任意键返回..."
}

channel_analysis() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} WiFi 信道分析 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 echo -e "${YELLOW}正在扫描附近 WiFi...${NC}"
 timeout 10 nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1
 sleep 3
 SCAN=$(nmcli -t -f SSID,CHAN,SIGNAL dev wifi list ifname "$WIFI_IF" 2>/dev/null)
 if [ -z "$SCAN" ]; then
 echo -e "${RED}❌ 扫描失败${NC}"; read -n 1 -s -r -p "按任意键返回..."; return
 fi
 echo "--------------------------------------"
 echo -e "${CYAN}信道 AP数 最强信号 拥挤度${NC}"
 echo "--------------------------------------"
 declare -A CH_COUNT
 declare -A CH_MAXSIG
 while IFS=: read -r SSID CH SIG; do
 [ -z "$CH" ] && continue
 [ "$CH" = "--" ] && continue
 CH=$(echo "$CH" | tr -d ' ')
 CH_COUNT[$CH]=$(( ${CH_COUNT[$CH]:-0} + 1 ))
 if [ -z "${CH_MAXSIG[$CH]}" ] || [ "$SIG" -gt "${CH_MAXSIG[$CH]}" ]; then
 CH_MAXSIG[$CH]=$SIG
 fi
 done <<< "$SCAN"
 for ch in $(seq 1 14); do
 COUNT=${CH_COUNT[$ch]:-0}
 MAXSIG=${CH_MAXSIG[$ch]:-N/A}
 if [ "$COUNT" -eq 0 ]; then
 CROWD="${GREEN}空闲${NC}"
 elif [ "$COUNT" -le 2 ]; then
 CROWD="${GREEN}良好${NC}"
 elif [ "$COUNT" -le 5 ]; then
 CROWD="${YELLOW}一般${NC}"
 else
 CROWD="${RED}拥挤${NC}"
 fi
 printf " %2d %2d %4s " "$ch" "$COUNT" "$MAXSIG"
 echo -e "$CROWD"
 done
 echo "--------------------------------------"
 BEST_CH=1
 BEST_COUNT=${CH_COUNT[1]:-0}
 for ch in 6 11; do
 C=${CH_COUNT[$ch]:-0}
 if [ "$C" -lt "$BEST_COUNT" ]; then
 BEST_COUNT=$C
 BEST_CH=$ch
 fi
 done
 echo -e "推荐信道: ${GREEN}$BEST_CH${NC} (AP最少: $BEST_COUNT 个)"
 echo -e "${YELLOW}提示: 1/6/11 互不干扰，优先选这三个${NC}"
 CUR_CH=$(nmcli -t -f CHAN dev wifi list ifname "$WIFI_IF" 2>/dev/null | grep -v -- "--" | head -1 | cut -d: -f1 | tr -d ' ')
 [ -n "$CUR_CH" ] && echo -e "当前信道: ${CYAN}$CUR_CH${NC}"
 read -n 1 -s -r -p "按任意键返回..."
}

backup_restore() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 网络配置备份/恢复 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 BACKUP_DIR="/root/wifi_backup"
 echo "1. 备份网络配置 (含 watchdog/keepalive crontab)"
 echo "2. 恢复网络配置"
 echo "3. 查看已有备份"
 echo "0. 返回"
 read -p "选项: " br_choice
 case $br_choice in
 1)
 mkdir -p "$BACKUP_DIR"
 TIMESTAMP=$(date +%Y%m%d_%H%M%S)
 BACKUP_FILE="$BACKUP_DIR/wifi_config_$TIMESTAMP.tar.gz"
 echo -e "${YELLOW}正在备份...${NC}"
 CONN_DIR="/etc/NetworkManager/system-connections"
 if [ -d "$CONN_DIR" ]; then
 # 备份 NM 配置 + watchdog/keepalive 脚本 + crontab
 crontab -l 2>/dev/null > /tmp/wifi_crontab_backup.txt
 # v1.9.5: 先创建未压缩 tar, 追加后再 gzip (tar rf 不支持压缩文件)
 local TMP_TAR="${BACKUP_FILE%.tar.gz}.tar"
 tar cf "$TMP_TAR" "$CONN_DIR" \
 /tmp/wifi_crontab_backup.txt 2>/dev/null
 [ -f "$WATCHDOG_SCRIPT" ] && tar rf "$TMP_TAR" "$WATCHDOG_SCRIPT" 2>/dev/null
 [ -f "$KEEPALIVE_SCRIPT" ] && tar rf "$TMP_TAR" "$KEEPALIVE_SCRIPT" 2>/dev/null
 [ -f "$AUTO_HOTSPOT_SCRIPT" ] && tar rf "$TMP_TAR" "$AUTO_HOTSPOT_SCRIPT" 2>/dev/null
 [ -d "/etc/hinaswifi" ] && tar rf "$TMP_TAR" /etc/hinaswifi 2>/dev/null
 gzip "$TMP_TAR" 2>/dev/null && mv "${TMP_TAR}.gz" "$BACKUP_FILE" 2>/dev/null
 nmcli -t -f NAME,TYPE,DEVICE connection show > "$BACKUP_DIR/conn_list_$TIMESTAMP.txt" 2>/dev/null
 SIZE=$(ls -la "$BACKUP_FILE" 2>/dev/null | awk '{print $5}')
 echo -e "${GREEN}✅ 备份成功${NC}"
 echo -e "文件: $BACKUP_FILE (${SIZE} bytes)"
 echo -e "内容: NM配置 + crontab + watchdog/keepalive + 自动热点配置"
 else
 echo -e "${RED}❌ 未找到 NetworkManager 配置目录${NC}"
 fi
 rm -f /tmp/wifi_crontab_backup.txt
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 2)
 if [ ! -d "$BACKUP_DIR" ]; then
 echo -e "${RED}❌ 无备份目录${NC}"; read -n 1 -s -r -p "按任意键返回..."; return
 fi
 echo -e "${CYAN}可用备份:${NC}"
 ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | while read -r f; do
 echo " $(basename "$f") ($(ls -la "$f" | awk '{print $5}') bytes)"
 done
 echo "--------------------------------------"
 read -p "输入备份文件名(回车返回): " restore_name
 [ -z "$restore_name" ] && return
 RESTORE_FILE="$BACKUP_DIR/$restore_name"
 if [ ! -f "$RESTORE_FILE" ]; then
 echo -e "${RED}❌ 文件不存在${NC}"; sleep 2; return
 fi
 echo -e "${YELLOW}警告: 将覆盖当前网络配置！${NC}"
 read -p "确认恢复? (y/n): " confirm
 [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
 tar xzf "$RESTORE_FILE" -C / 2>/dev/null
 # 恢复 crontab
 if [ -f /tmp/wifi_crontab_backup.txt ]; then
 crontab /tmp/wifi_crontab_backup.txt 2>/dev/null
 rm -f /tmp/wifi_crontab_backup.txt
 fi
 systemctl restart NetworkManager 2>/dev/null
 sleep 5
 echo -e "${GREEN}✅ 恢复完成，NetworkManager 已重启${NC}"
 nmcli -t -f NAME,TYPE,DEVICE connection show
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 3)
 if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]; then
 echo -e "${YELLOW}暂无备份${NC}"; read -n 1 -s -r -p "按任意键返回..."; return
 fi
 echo -e "${CYAN}已有备份:${NC}"
 echo "--------------------------------------"
 ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | while read -r f; do
 echo -e " ${GREEN}$(basename "$f")${NC} $(ls -la "$f" | awk '{print $5}')B"
 done
 echo "--------------------------------------"
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 0) return ;;
 *) echo -e "${RED}无效${NC}"; sleep 1 ;;
 esac
}

ipv6_panel() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} IPv6 详细面板 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 echo -e "${YELLOW}正在检测 IPv6 状态...${NC}"
 echo "--------------------------------------"
 echo -e "${CYAN}【接口信息】${NC}"
 echo -e " 接口: ${GREEN}$WIFI_IF${NC}"
 echo -n " IPv6 地址:"
 IPV6_ADDRS=$(ip -6 addr show dev "$WIFI_IF" 2>/dev/null | grep "scope global" | awk '{print $2}')
 if [ -n "$IPV6_ADDRS" ]; then
 echo ""
 echo "$IPV6_ADDRS" | while read -r addr; do
 echo -e " ${GREEN}$addr${NC}"
 done
 else
 echo -e " ${RED}无${NC}"
 fi
 IPV6_PREFIX=$(echo "$IPV6_ADDRS" | head -1)
 if [ -n "$IPV6_PREFIX" ]; then
 echo -e " 前缀长度: ${GREEN}/$(echo "$IPV6_PREFIX" | cut -d/ -f2)${NC}"
 fi
 IPV6_GW=$(ip -6 route 2>/dev/null | awk '/default/ {print $3}' | head -1)
 echo -n " IPv6 网关: "
 [ -n "$IPV6_GW" ] && echo -e "${GREEN}$IPV6_GW${NC}" || echo -e "${RED}无${NC}"
 IPV6_DNS=$(grep -E "nameserver" /etc/resolv.conf 2>/dev/null | grep ":" | awk '{print $2}' | head -1)
 echo -n " IPv6 DNS: "
 [ -n "$IPV6_DNS" ] && echo -e "${GREEN}$IPV6_DNS${NC}" || echo -e "${YELLOW}无(仅IPv4 DNS)${NC}"
 RA_STATE=$(cat /proc/sys/net/ipv6/conf/$WIFI_IF/accept_ra 2>/dev/null)
 echo -n " 接收RA: "
 case "$RA_STATE" in
 0) echo -e "${RED}关闭${NC}" ;;
 1) echo -e "${GREEN}开启${NC}" ;;
 2) echo -e "${GREEN}开启(转发模式)${NC}" ;;
 *) echo -e "${YELLOW}未知($RA_STATE)${NC}" ;;
 esac
 IPV6_DISABLE=$(cat /proc/sys/net/ipv6/conf/$WIFI_IF/disable_ipv6 2>/dev/null)
 echo -n " IPv6启用: "
 [ "$IPV6_DISABLE" = "0" ] && echo -e "${GREEN}是${NC}" || echo -e "${RED}否${NC}"
 echo "--------------------------------------"
 echo -e "${CYAN}【连通性测试】${NC}"
 echo -n " 网关连通: "
 if [ -n "$IPV6_GW" ]; then
 ping6 -c 2 -W 2 "$IPV6_GW" >/dev/null 2>&1 && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
 else
 echo -e "${YELLOW}无网关${NC}"
 fi
 echo -n " 国内(taobao): "
 curl -6 -s --connect-timeout 3 -o /dev/null -w "%{http_code}" https://www.taobao.com 2>/dev/null | grep -q "200\|301\|302" && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
 echo -n " 公网IPv6: "
 PUB6=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org 2>/dev/null)
 [ -n "$PUB6" ] && echo -e "${GREEN}$PUB6${NC}" || echo -e "${RED}获取失败${NC}"
 echo "--------------------------------------"
 echo -e "${CYAN}【地址配置方式】${NC}"
 if echo "$IPV6_ADDRS" | grep -qP ":[0-9a-f:]+/(64|48|56)$"; then
 echo -e " 方式: ${GREEN}SLAAC (无状态自动配置)${NC}"
 elif [ -n "$IPV6_ADDRS" ]; then
 echo -e " 方式: ${YELLOW}DHCPv6 或手动配置${NC}"
 else
 echo -e " 方式: ${RED}未配置${NC}"
 fi
 echo -e "${CYAN}======================================${NC}"
 read -n 1 -s -r -p "按任意键返回..."
}

# --- 断网统计面板 (新增) ---
watchdog_stats() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 断网统计面板 v2.0.0 ${NC}"
 echo -e "${CYAN}======================================${NC}"

 local STATS_FILE="/var/log/wifi_watchdog.stats"
 if [ ! -f "$STATS_FILE" ] || [ ! -s "$STATS_FILE" ]; then
 echo -e "${YELLOW}暂无统计数据。${NC}"
 echo -e "开启自动重连 (菜单3→1) 后, 每次断网恢复都会记录统计。"
 read -n 1 -s -r -p "按任意键返回..."
 return
 fi

 # 统计最近 24 小时
 local now cutoff
 now=$(date +%s)
 cutoff=$((now - 86400))

 local total=0 success=0 fail=0 total_dur=0
 declare -A reason_count

 # 读取并解析 stats 文件
 while IFS='|' read -r ts result level dur reason; do
 # 转换时间戳为 epoch
 local epoch
 epoch=$(date -d "$ts" +%s 2>/dev/null)
 [ -z "$epoch" ] && continue
 # 只统计 24h 内
 [ "$epoch" -lt "$cutoff" ] && continue

 total=$((total + 1))
 if [ "$result" = "success" ]; then
 success=$((success + 1))
 else
 fail=$((fail + 1))
 fi
 # 提取耗时数字
 local dur_num
 dur_num=$(echo "$dur" | grep -oP '[0-9]+')
 [ -n "$dur_num" ] && total_dur=$((total_dur + dur_num))
 # 原因统计
 reason_count[$reason]=$(( ${reason_count[$reason]:-0} + 1 ))
 done < "$STATS_FILE"

 if [ "$total" -eq 0 ]; then
 echo -e "${GREEN}最近 24 小时无断网记录 ✅${NC}"
 echo "--------------------------------------"
 else
 local success_rate=0 avg_dur=0
 [ "$total" -gt 0 ] && success_rate=$((success * 100 / total))
 [ "$total" -gt 0 ] && avg_dur=$((total_dur / total))

 local first_ts last_ts
 first_ts=$(head -1 "$STATS_FILE" | cut -d'|' -f1)
 last_ts=$(tail -1 "$STATS_FILE" | cut -d'|' -f1)
 echo -e " 数据区间: ${first_ts} ~ ${last_ts}"
 echo "--------------------------------------"
 echo -e "${CYAN}【最近 24 小时统计】${NC}"
 echo "--------------------------------------"
 echo -e " 总断网次数: ${YELLOW}${total}${NC}"
 echo -e " 恢复成功: ${GREEN}${success}${NC} (${success_rate}%)"
 echo -e " 恢复失败: ${RED}${fail}${NC}"
 echo -e " 平均耗时: ${CYAN}${avg_dur}s${NC}"

 local today yesterday today_cnt=0 yest_cnt=0
 today=$(date '+%Y-%m-%d')
 yesterday=$(date -d 'yesterday' '+%Y-%m-%d')
 while IFS='|' read -r ts r l d rea; do
 case "$ts" in
 "$today"*) today_cnt=$((today_cnt + 1)) ;;
 "$yesterday"*) yest_cnt=$((yest_cnt + 1)) ;;
 esac
 done < "$STATS_FILE"
 echo ""
 echo -e "${CYAN}【今日 vs 昨日】${NC}"
 if [ "$yest_cnt" -gt 0 ]; then
 local trend=$((today_cnt - yest_cnt))
 if [ "$trend" -lt 0 ]; then
 echo -e " 昨日: ${yest_cnt}次 → 今日: ${GREEN}${today_cnt}次${NC} (↓${trend#-} 🎉)"
 elif [ "$trend" -gt 0 ]; then
 echo -e " 昨日: ${yest_cnt}次 → 今日: ${RED}${today_cnt}次${NC} (↑${trend} ⚠)"
 else
 echo -e " 昨日: ${yest_cnt}次 → 今日: ${today_cnt}次 (持平)"
 fi
 else
 echo -e " 昨日: 0次 → 今日: ${today_cnt}次"
 fi
 echo ""
 echo -e "${CYAN}【断网原因分布】${NC}"
 for reason in "${!reason_count[@]}"; do
 local count=${reason_count[$reason]}
 local pct=$((count * 100 / total))
 printf " %-25s %2d次 (%d%%)\n" "$reason" "$count" "$pct"
 done
 echo "--------------------------------------"
 fi

 # 最近 10 次记录
 echo -e "${CYAN}【最近 10 次记录】${NC}"
 echo "--------------------------------------"
 tail -n 10 "$STATS_FILE" | while IFS='|' read -r ts result level dur reason; do
 if [ "$result" = "success" ]; then
 echo -e " ${GREEN}✅${NC} $ts $level $dur $reason"
 else
 echo -e " ${RED}❌${NC} $ts $level $dur $reason"
 fi
 done
 echo "--------------------------------------"

 # 信号趋势 (从日志提取最近的信号记录)
 local LOG_FILE="/var/log/wifi_watchdog.log"
 if [ -f "$LOG_FILE" ]; then
 echo -e "${CYAN}【最近信号趋势】${NC}"
 grep '信号=' "$LOG_FILE" | tail -n 10 | while read -r line; do
 local ts sig
 ts=$(echo "$line" | grep -oP '\[\K[0-9-]+ [0-9:]+')
 sig=$(echo "$line" | grep -oP '信号=\K[-0-9]+dBm')
 [ -n "$sig" ] && echo " $ts $sig"
 done
 echo "--------------------------------------"
 fi

 echo -e "${CYAN}======================================${NC}"
 read -n 1 -s -r -p "按任意键返回..."
}


# --- 省电模式开关 (用户自行控制) ---
toggle_power_save() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} WiFi 省电模式开关 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 CONN=$(get_wifi_conn)
 PS_STATE=$(iw dev "$WIFI_IF" get power_save 2>/dev/null | awk '{print $3}')
 NM_PS=$(nmcli -t -f 802-11-wireless.powersave con show "$CONN" 2>/dev/null | cut -d: -f2)
 USB_CTRL=$(cat /sys/class/net/${WIFI_IF}/device/power/control 2>/dev/null)
 echo -e "接口: ${GREEN}$WIFI_IF${NC}"
 echo -e "连接: ${GREEN}${CONN:-无}${NC}"
 echo "--------------------------------------"
 echo -e "驱动省电 (iw): ${PS_STATE:-未知}"
 echo -e "NM 省电 (nmcli): ${NM_PS:-未知} (2=关,3=开)"
 echo -e "USB 挂起控制: ${USB_CTRL:-未知} (on=不挂起)"
 echo "--------------------------------------"
 if [ "$PS_STATE" = "on" ]; then
 echo -e "综合状态: ${GREEN}🟢 省电开启 (正常)${NC}"
 else
 echo -e "综合状态: ${YELLOW}🟡 省电已关闭 (可能过热/USB供电不足)${NC}"
 fi
 echo "--------------------------------------"
 echo "1. 关闭省电 (不建议, 可能过热/USB供电不足)"
 echo -e "2. ${GREEN}开启省电${NC} (推荐! RTL8188FU 省电模式稳定)"
 echo "0. 返回"
 echo -e "${CYAN}======================================${NC}"
 read -p "选项: " ps_choice
 case $ps_choice in
 1)
 echo -e "${YELLOW}正在关闭省电...${NC}"
 iw dev "$WIFI_IF" set power_save off 2>/dev/null
 echo " ✅ iw set power_save off"
 if [ -n "$CONN" ]; then
 nmcli con mod "$CONN" 802-11-wireless.powersave 2 2>/dev/null
 echo " ✅ nmcli powersave=2 (持久化)"
 fi
 local dp="/sys/class/net/${WIFI_IF}/device/power/control"
 [ -f "$dp" ] && echo on > "$dp" 2>/dev/null && echo " ✅ USB power control: on"
 echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null && echo " ✅ USB autosuspend: -1"
 sleep 1
 PS_NEW=$(iw dev "$WIFI_IF" get power_save 2>/dev/null | awk '{print $3}')
 if [ "$PS_NEW" = "off" ] || [ -z "$PS_NEW" ]; then
 echo -e "\n${GREEN}✅ 省电已关闭!${NC}"
 else
 echo -e "\n${YELLOW}⚠ iw 显示 $PS_NEW, 但 NM+USB 层已关${NC}"
 fi ;;
 2)
 echo -e "${YELLOW}正在开启省电...${NC}"
 iw dev "$WIFI_IF" set power_save on 2>/dev/null
 [ -n "$CONN" ] && nmcli con mod "$CONN" 802-11-wireless.powersave 3 2>/dev/null
 echo -e "${GREEN}✅ 省电已开启, RTL8188FU 省电模式稳定运行${NC}"
 echo -e "${YELLOW}⚠ RTL8188 省电可能导致频繁断网!${NC}" ;;
 0) return ;;
 esac
 read -n 1 -s -r -p "按任意键返回..."
}


# --- IPv6 模式开关 (v2.1.0 新增) ---
toggle_ipv6() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} IPv6 模式开关 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 CONN=$(get_wifi_conn)
 if [ -z "$CONN" ]; then
 echo -e "${RED}❌ 未连接 WiFi${NC}"
 read -n 1 -s -r -p "按任意键返回..."; return
 fi
 IPV6_MODE=$(nmcli -t -f ipv6.method con show "$CONN" 2>/dev/null | cut -d: -f2)
 RA_STATE=$(cat /proc/sys/net/ipv6/conf/$WIFI_IF/accept_ra 2>/dev/null)
 IPV6_ADDRS=$(ip -6 addr show dev "$WIFI_IF" 2>/dev/null | grep "scope global" | awk '{print $2}' | head -1)
 echo -e "接口: ${GREEN}$WIFI_IF${NC}"
 echo -e "连接: ${GREEN}$CONN${NC}"
 echo "--------------------------------------"
 echo -n " 当前模式: "
 case "$IPV6_MODE" in
 auto)     echo -e "${YELLOW}auto (NM主动管理)${NC}" ;;
 ignore)   echo -e "${GREEN}ignore (NM不管, 内核自处理RA)${NC}" ;;
 disabled) echo -e "${RED}disabled (IPv6已禁用)${NC}" ;;
 *)        echo -e "${YELLOW}$IPV6_MODE${NC}" ;;
 esac
 echo -n " 接收RA: "
 case "$RA_STATE" in
 0) echo -e "${RED}关闭${NC}" ;;
 1) echo -e "${GREEN}开启${NC}" ;;
 2) echo -e "${GREEN}开启(转发)${NC}" ;;
 *) echo -e "${YELLOW}未知($RA_STATE)${NC}" ;;
 esac
 echo -n " IPv6地址: "
 [ -n "$IPV6_ADDRS" ] && echo -e "${GREEN}有${NC}" || echo -e "${RED}无${NC}"
 echo "--------------------------------------"
 if [ "$IPV6_MODE" = "ignore" ]; then
 echo -e "综合状态: ${GREEN}🟢 推荐 — IPv6能用就用, 不影响IPv4${NC}"
 elif [ "$IPV6_MODE" = "auto" ]; then
 echo -e "综合状态: ${YELLOW}🟡 NM主动管理 — 路由器IPv6不稳定时可能拖垮DHCPv4${NC}"
 else
 echo -e "综合状态: ${RED}🔴 IPv6已禁用${NC}"
 fi
 echo "--------------------------------------"
 echo -e "1. ${GREEN}ignore (推荐)${NC} — NM不管IPv6, 内核自己处理RA"
 echo "   IPv6能用就用, 路由器IPv6抽风不影响IPv4"
 echo "2. auto — NM主动管理IPv6 (路由器IPv6稳定时可用)"
 echo "3. disabled — 完全禁用IPv6"
 echo "0. 返回"
 echo -e "${CYAN}======================================${NC}"
 read -p "选项: " ipv6_choice
 case $ipv6_choice in
 1)
 nmcli con mod "$CONN" ipv6.method ignore 2>/dev/null
 sysctl -w net.ipv6.conf.${WIFI_IF}.accept_ra=1 >/dev/null 2>&1
 # 持久化 accept_ra (重启后生效)
 echo "net.ipv6.conf.${WIFI_IF}.accept_ra=1" > /etc/sysctl.d/99-hinaswifi-ipv6.conf 2>/dev/null
 nmcli con up "$CONN" >/dev/null 2>&1
 echo -e "${GREEN}✅ 已设为 ignore${NC}"
 echo -e " NM不再管理IPv6, 内核自己处理RA"
 echo -e " 路由器IPv6好时IPv6可用, 不好时不影响IPv4" ;;
 2)
 nmcli con mod "$CONN" ipv6.method auto 2>/dev/null
 nmcli con up "$CONN" >/dev/null 2>&1
 echo -e "${YELLOW}⚠ 已设为 auto${NC}"
 echo -e " 路由器IPv6不稳定时可能导致DHCPv4超时断线" ;;
 3)
 nmcli con mod "$CONN" ipv6.method disabled 2>/dev/null
 nmcli con up "$CONN" >/dev/null 2>&1
 rm -f /etc/sysctl.d/99-hinaswifi-ipv6.conf 2>/dev/null
 echo -e "${RED}✅ 已禁用IPv6${NC}" ;;
 0) return ;;
 esac
 read -n 1 -s -r -p "按任意键返回..."
}
# ========== 主菜单 ==========
toggle_bssid_lock() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} BSSID 锁定 (防漫游) ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 CONN=$(get_wifi_conn)
 if [ -z "$CONN" ]; then
 echo -e "${RED}❌ 未连接 WiFi${NC}"
 read -n 1 -s -r -p "按任意键返回..."; return
 fi

 LOCKED_BSSID=$(nmcli -t -f 802-11-wireless.bssid con show "$CONN" 2>/dev/null | cut -d: -f2-)
 CUR_BSSID=$(iw dev "$WIFI_IF" link 2>/dev/null | grep -oi "Connected to [0-9a-f:]*" | awk '{print $3}')
 CUR_SSID=$(nmcli -t -f 802-11-wireless.ssid con show "$CONN" 2>/dev/null | cut -d: -f2)

 echo -e "接口: ${GREEN}$WIFI_IF${NC}  连接: ${GREEN}$CONN${NC}  SSID: ${GREEN}$CUR_SSID${NC}"
 echo "--------------------------------------"

 if [ -n "$LOCKED_BSSID" ] && [ "$LOCKED_BSSID" != "--" ]; then
 echo -e "当前状态: ${GREEN}🔒 已锁定${NC}"
 echo -e "锁定 BSSID: ${GREEN}$LOCKED_BSSID${NC}"
 if [ -n "$CUR_BSSID" ]; then
 echo -e "实际连接: ${GREEN}$CUR_BSSID${NC}"
 fi
 echo "--------------------------------------"
 echo -e "${YELLOW}锁定后设备只认这一个 AP, 不漫游到同名 SSID 的其他 AP${NC}"
 echo ""
 echo -e "1. ${RED}解除锁定${NC} — 允许漫游 (不推荐, 双AP环境会互踢)"
 echo -e "2. ${CYAN}换绑其他 MAC${NC} — 重新选择/输入 MAC 地址"
 echo "0. 返回"
 echo -e "${CYAN}======================================${NC}"
 read -p "选项: " bssid_choice
 case $bssid_choice in
 1)
 nmcli con mod "$CONN" 802-11-wireless.bssid "" 2>/dev/null
 nmcli con up "$CONN" >/dev/null 2>&1
 echo -e "${YELLOW}⚠ 已解除 BSSID 锁定${NC}"
 echo -e " 设备可能漫游到其他同名 AP, 导致频繁 deauth"
 ;;
 2)
 LOCKED_BSSID=""
 ;;
 0) return ;;
 esac
 fi

 if [ -z "$LOCKED_BSSID" ] || [ "$LOCKED_BSSID" = "--" ]; then
 echo -e "当前状态: ${YELLOW}🔓 未锁定${NC}"
 if [ -n "$CUR_BSSID" ]; then
 echo -e "当前连接: ${GREEN}$CUR_BSSID${NC}"
 fi
 echo "--------------------------------------"
 echo -e "扫描同名 SSID 的 AP..."
 echo ""

 # 双重扫描: nmcli + iw 底层扫描
 echo -e "${YELLOW}正在扫描 (nmcli + iw 双重扫描)...${NC}"
 timeout 10 nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1; sleep 3

 AP_LIST=$(scan_wifi_all "$WIFI_IF")

 AP_COUNT=0
 AP_BSSIDS=()
 AP_DATA=""

 if [ -n "$AP_LIST" ]; then
 while IFS= read -r line; do
 [ -z "$line" ] && continue
 line_bssid="${line:0:17}"
 rest="${line:18}"
 line_ssid="${rest%%:*}"
 rest2="${rest#*:}"
 line_signal="${rest2%%:*}"
 line_freq="${rest2#*:}"

 [ "$line_ssid" != "$CUR_SSID" ] && continue

 AP_COUNT=$((AP_COUNT + 1))
 AP_BSSIDS[$AP_COUNT]=$line_bssid

 CH=""
 if [[ "$line_freq" =~ ^[0-9]+$ ]]; then
 CH=$(( (line_freq / 1000 - 2412) / 5 + 1 ))
 [ "$line_freq" -gt 5000 ] 2>/dev/null && CH=$(( (line_freq / 1000 - 5000) / 5 + 36 ))
 fi

 MARK=""
 [ "$line_bssid" = "$CUR_BSSID" ] && MARK=" ← 当前"

 AP_DATA="${AP_DATA}${AP_COUNT}|${line_bssid}|${line_signal}|${CH}|${MARK}\n"
 done <<< "$AP_LIST"
 fi

 if [ "$AP_COUNT" -gt 0 ]; then
 echo -e "  序号  BSSID               信号   信道"
 echo "  ----  ------------------  -----  ----"
 echo -e "$AP_DATA" | while IFS='|' read -r num bssid sig ch mark; do
 [ -z "$num" ] && continue
 printf "  ${GREEN}%-3d${NC}   %-18s  %4s   %3s%s\n" "$num" "$bssid" "$sig" "$ch" "$mark"
 done
 echo ""
 echo -e "${YELLOW}建议: 锁定信号最强的 AP (序号 1)${NC}"
 else
 echo -e "${YELLOW}⚠ 扫描未找到同名 AP${NC}"
 echo -e "${YELLOW}  可以直接手动输入 MAC 地址绑定${NC}"
 echo ""
 fi

 echo ""
 echo -e "输入序号 ${GREEN}1-$AP_COUNT${NC} 锁定"
 echo -e "或输入 ${CYAN}m${NC} 手动输入 MAC 地址 (如 f6:1c:71:2a:3a:61)"
 echo -e "或输入 0 返回"
 echo -e "${CYAN}======================================${NC}"
 read -p "选项: " bssid_choice

 if [ "$bssid_choice" = "0" ] || [ -z "$bssid_choice" ]; then
 return
 fi

 if [ "$bssid_choice" = "m" ] || [ "$bssid_choice" = "M" ]; then
 echo -e "${CYAN}请输入要锁定的 MAC 地址 (BSSID)${NC}"
 echo -e "格式: xx:xx:xx:xx:xx:xx (小写大写均可)"
 echo -e "当前连接: ${GREEN}$CUR_BSSID${NC}"
 read -p "MAC 地址: " TARGET_BSSID
 TARGET_BSSID=$(echo "$TARGET_BSSID" | tr 'A-F' 'a-f')
 if ! [[ "$TARGET_BSSID" =~ ^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$ ]]; then
 echo -e "${RED}❌ MAC 地址格式不对, 应为 xx:xx:xx:xx:xx:xx${NC}"
 read -n 1 -s -r -p "按任意键返回..."; return
 fi
 elif [[ "$bssid_choice" =~ ^[0-9]+$ ]] && [ "$bssid_choice" -ge 1 ] && [ "$bssid_choice" -le "$AP_COUNT" ]; then
 TARGET_BSSID=${AP_BSSIDS[$bssid_choice]}
 else
 echo -e "${RED}❌ 无效选项${NC}"
 read -n 1 -s -r -p "按任意键返回..."; return
 fi

 echo -e "锁定到: ${GREEN}$TARGET_BSSID${NC}"
 echo -e "正在应用..."
 nmcli con mod "$CONN" 802-11-wireless.bssid "$TARGET_BSSID" 2>/dev/null
 nmcli con up "$CONN" >/dev/null 2>&1
 sleep 3
 NEW_BSSID=$(iw dev "$WIFI_IF" link 2>/dev/null | grep -oi "Connected to [0-9a-f:]*" | awk '{print $3}')
 if [ "$NEW_BSSID" = "$TARGET_BSSID" ]; then
 echo -e "${GREEN}✅ 已锁定到 $TARGET_BSSID${NC}"
 echo -e " 设备只认这个 AP, 不再漫游到其他同名 AP"
 else
 echo -e "${YELLOW}⚠ 锁定指令已下发, 但当前连接的是 $NEW_BSSID${NC}"
 echo -e " 可能需要等待切换, 或该 AP 信号不足"
 echo -e " BSSID 绑定已保存, 下次连接会优先使用此 MAC"
 fi
 fi
 read -n 1 -s -r -p "按任意键返回..."
}
toggle_auto_hotspot() {
	clear
	echo -e "${CYAN}======================================${NC}"
	echo -e "${CYAN} 自动热点救生通道 v2.3.1 ${NC}"
	echo -e "${CYAN}======================================${NC}"

	local CONFIG_DIR="/etc/hinaswifi"
	local CONFIG_FILE="$AUTO_HOTSPOT_CONFIG"
	local SCRIPT_FILE="$AUTO_HOTSPOT_SCRIPT"

	# 加载当前配置
	local ENABLED=0 SSID="HINAS" PASS="88888888" TIMEOUT=10 INTERVAL=2 PROBE=6
	[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

	# 检查 crontab 状态
	local CRON_ENTRY
	CRON_ENTRY=$(crontab -l 2>/dev/null | grep "$SCRIPT_FILE")

	# 显示状态
	if [ "$ENABLED" = "1" ] && [ -n "$CRON_ENTRY" ]; then
		echo -e "状态: ${GREEN}▶ 已开启${NC}"
	else
		echo -e "状态: ${RED}⏸ 未开启${NC}"
	fi
	echo "--------------------------------------"
	echo -e "热点名称:   ${GREEN}${SSID}${NC}"
	echo -e "热点密码:   ${GREEN}${PASS}${NC}"
	echo -e "超时阈值:   ${GREEN}${TIMEOUT} 分钟${NC} (无WiFi连接多久后开热点)"
	echo -e "检测间隔:   ${GREEN}${INTERVAL} 分钟${NC} (检查频率)"
	echo -e "探测间隔:   ${GREEN}${PROBE} 分钟${NC} (热点时多久尝试重连已保存WiFi)"
	echo "--------------------------------------"
	echo -e " ${YELLOW}开启后: 盒子无WiFi连接 ${TIMEOUT} 分钟 → 自动开热点 '${SSID}'${NC}"
	echo -e " ${YELLOW}热点运行中每 ${PROBE} 分钟探测一次, WiFi恢复则自动切回${NC}"
	echo "--------------------------------------"
	echo "1. 开启/关闭"
	echo "2. 修改热点名称"
	echo "3. 修改热点密码"
	echo "4. 修改超时阈值 (分钟)"
	echo "5. 修改检测间隔 (分钟)"
	echo "6. 修改探测间隔 (分钟)"
	echo "7. 查看日志"
	echo "8. 一键测试 (手动触发一次检测)"
	echo "0. 返回"
	echo -e "${CYAN}======================================${NC}"
	read -p "请输入选项: " ah_choice

	_save_config() {
		mkdir -p "$CONFIG_DIR"
		cat > "$CONFIG_FILE" << EOF
ENABLED=$ENABLED
HOTSPOT_SSID="$SSID"
HOTSPOT_PASS="$PASS"
TIMEOUT_MIN=$TIMEOUT
CHECK_INTERVAL=$INTERVAL
PROBE_INTERVAL=$PROBE
EOF
	}

	_write_daemon() {
		cat > "$SCRIPT_FILE" << 'AHEOF'
#!/bin/bash
# WiFi Auto-Hotspot Daemon — 无已保存WiFi连接时自动开启热点
# 热点运行时定期探测已保存WiFi, 恢复后自动切回

exec 200>/tmp/wifi_auto_hotspot.lock
flock -n 200 || exit 0

CONFIG_FILE="/etc/hinaswifi/auto_hotspot.conf"
STATE_FILE="/tmp/wifi_auto_hotspot_state"
LOG_FILE="/var/log/wifi_auto_hotspot.log"

ENABLED=0
HOTSPOT_SSID="HINAS"
HOTSPOT_PASS="88888888"
TIMEOUT_MIN=10
CHECK_INTERVAL=2
PROBE_INTERVAL=6

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
[ "$ENABLED" != "1" ] && exit 0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; logger -t wifi_auto_hotspot "$*" 2>/dev/null; }

# 日志轮转
if [ -f "$LOG_FILE" ]; then
	_lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
	[ "$_lines" -gt 500 ] && tail -n 250 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

detect_iface() {
	local IF
	IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
	[ -z "$IF" ] && IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
	[ -z "$IF" ] && IF="wlan0"
	echo "$IF"
}

# 是否已连接WiFi (客户端模式, 非热点)
is_wifi_connected() {
	local IF; IF=$(detect_iface)
	local STATE; STATE=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
	[ "$STATE" != "connected" ] && [ "$STATE" != "connecting" ] && return 1
	# 排除AP模式
	local CONN; CONN=$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
	if [ -n "$CONN" ] && [ "$CONN" != "--" ]; then
		local MODE; MODE=$(nmcli -t -f 802-11-wireless.mode con show "$CONN" 2>/dev/null | cut -d: -f2)
		[ "$MODE" = "ap" ] && return 1
	fi
	return 0
}

# 获取正在运行的热点连接名
get_hotspot_conn() {
	local name mode
	while IFS=: read -r name _type active; do
		[ "$active" = "yes" ] || continue
		mode=$(nmcli -t -f 802-11-wireless.mode con show "$name" 2>/dev/null | cut -d: -f2)
		[ "$mode" = "ap" ] && echo "$name" && return
	done < <(nmcli -t -f NAME,TYPE,ACTIVE connection 2>/dev/null | grep ':802-11-wireless:')
}

start_hotspot() {
	local IF; IF=$(detect_iface)
	nmcli device wifi hotspot ifname "$IF" ssid "$HOTSPOT_SSID" password "$HOTSPOT_PASS" >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		log "✅ 热点已开启: $HOTSPOT_SSID (接口=$IF)"
	else
		log "❌ 热点开启失败"
	fi
}

stop_hotspot() {
	local AP_CONN; AP_CONN=$(get_hotspot_conn)
	if [ -n "$AP_CONN" ]; then
		nmcli con down "$AP_CONN" >/dev/null 2>&1
		log "✅ 热点已关闭: $AP_CONN"
	fi
}

# 尝试连接所有已保存的WiFi (排除AP模式连接)
try_saved_wifi() {
	local SAVED
	SAVED=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | cut -d: -f1)
	[ -z "$SAVED" ] && return 1

	local IF; IF=$(detect_iface)
	nmcli device wifi rescan ifname "$IF" >/dev/null 2>&1
	sleep 3

	local conn mode
	while IFS= read -r conn; do
		[ -z "$conn" ] && continue
		mode=$(nmcli -t -f 802-11-wireless.mode con show "$conn" 2>/dev/null | cut -d: -f2)
		[ "$mode" = "ap" ] && continue
		nmcli con up "$conn" >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			sleep 3
			if is_wifi_connected; then
				log "✅ 已保存WiFi连接成功: $conn"
				return 0
			fi
		fi
	done <<< "$SAVED"
	return 1
}

# ========== 主逻辑 ==========
# 状态文件格式: MODE|COUNTER
# MODE: normal / hotspot
# COUNTER: 当前状态下累计分钟数

CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "normal|0")
MODE=$(echo "$CURRENT" | cut -d'|' -f1)
COUNT=$(echo "$CURRENT" | cut -d'|' -f2)
[ -z "$MODE" ] && MODE="normal"
[ -z "$COUNT" ] && COUNT=0

if [ "$MODE" = "hotspot" ]; then
	# --- 热点运行中 ---
	COUNT=$((COUNT + CHECK_INTERVAL))

	if [ "$COUNT" -ge "$PROBE_INTERVAL" ]; then
		# 探测时间到: 关热点 → 尝试已保存WiFi
		log "🔍 探测: 关闭热点, 尝试重连已保存WiFi..."
		stop_hotspot
		sleep 2

		if try_saved_wifi; then
			echo "normal|0" > "$STATE_FILE"
			log "✅ WiFi已恢复, 切回正常模式"
		else
			log "❌ 探测失败, 无已保存WiFi可用, 重新开启热点"
			start_hotspot
			echo "hotspot|0" > "$STATE_FILE"
		fi
	else
		echo "hotspot|$COUNT" > "$STATE_FILE"
	fi
else
	# --- 正常监控中 ---
	if is_wifi_connected; then
		echo "normal|0" > "$STATE_FILE"
		# 如果热点在跑(异常残留), 关掉
		[ -n "$(get_hotspot_conn)" ] && stop_hotspot
		exit 0
	fi

	COUNT=$((COUNT + CHECK_INTERVAL))

	if [ "$COUNT" -ge "$TIMEOUT_MIN" ]; then
		# 超时, 先最后试一次已保存WiFi
		if try_saved_wifi; then
			echo "normal|0" > "$STATE_FILE"
			exit 0
		fi
		log "⚠ 连续 ${COUNT} 分钟无WiFi连接, 开启热点 '${HOTSPOT_SSID}'"
		start_hotspot
		echo "hotspot|0" > "$STATE_FILE"
	else
		echo "normal|$COUNT" > "$STATE_FILE"
	fi
fi
AHEOF
		chmod +x "$SCRIPT_FILE"
	}

	case $ah_choice in
	1)
		if [ "$ENABLED" = "1" ] && [ -n "$CRON_ENTRY" ]; then
			# 关闭
			crontab -l 2>/dev/null | grep -v "$SCRIPT_FILE" | crontab -
			ENABLED=0
			_save_config
			# 关掉正在运行的热点
			local AP_CONN=""
			while IFS=: read -r _n _t _a; do
				[ "$_a" = "yes" ] || continue
				_m=$(nmcli -t -f 802-11-wireless.mode con show "$_n" 2>/dev/null | cut -d: -f2)
				[ "$_m" = "ap" ] && AP_CONN="$_n"
			done < <(nmcli -t -f NAME,TYPE,ACTIVE connection 2>/dev/null | grep ':802-11-wireless:')
			[ -n "$AP_CONN" ] && nmcli con down "$AP_CONN" >/dev/null 2>&1
			rm -f /tmp/wifi_auto_hotspot_state
			echo -e "${GREEN}✅ 已关闭自动热点${NC}"
		else
			# 开启
			ENABLED=1
			_save_config
			_write_daemon
			(crontab -l 2>/dev/null | grep -v "$SCRIPT_FILE"; echo "*/$INTERVAL * * * * $SCRIPT_FILE") | crontab -
			echo -e "${GREEN}✅ 已开启自动热点${NC}"
			echo -e "${YELLOW}无WiFi连接 ${TIMEOUT} 分钟后自动开启热点 '${SSID}'${NC}"
			echo -e "${YELLOW}手机连热点后 SSH 登录盒子, 运行 wifi 连新WiFi${NC}"
		fi
		sleep 3
		;;
	2)
		read -p "新热点名称 (回车保持不变): " new_ssid
		[ -z "$new_ssid" ] && new_ssid="$SSID"
		SSID="$new_ssid"
		_save_config
		echo -e "${GREEN}✅ 热点名称已改为: $SSID${NC}"
		sleep 2
		;;
	3)
		read -s -p "新热点密码 (8位+): " new_pass; echo
		if [ -n "$new_pass" ] && [ ${#new_pass} -ge 8 ]; then
			PASS="$new_pass"
			_save_config
			echo -e "${GREEN}✅ 热点密码已更新${NC}"
		else
			echo -e "${RED}❌ 密码至少8位${NC}"
		fi
		sleep 2
		;;
	4)
		read -p "超时阈值 (分钟, 回车保持不变): " new_timeout
		if [[ "$new_timeout" =~ ^[1-9][0-9]*$ ]]; then
			TIMEOUT="$new_timeout"
			_save_config
			echo -e "${GREEN}✅ 超时阈值已改为: $TIMEOUT 分钟${NC}"
		else
			echo -e "${RED}❌ 请输入正整数${NC}"
		fi
		sleep 2
		;;
	5)
		read -p "检测间隔 (分钟, 回车保持不变): " new_interval
		if [[ "$new_interval" =~ ^[1-9][0-9]*$ ]]; then
			INTERVAL="$new_interval"
			_save_config
			# 更新 crontab
			if [ -n "$(crontab -l 2>/dev/null | grep "$SCRIPT_FILE")" ]; then
				crontab -l 2>/dev/null | grep -v "$SCRIPT_FILE" | crontab -
				(crontab -l 2>/dev/null; echo "*/$INTERVAL * * * * $SCRIPT_FILE") | crontab -
			fi
			echo -e "${GREEN}✅ 检测间隔已改为: $INTERVAL 分钟${NC}"
		else
			echo -e "${RED}❌ 请输入正整数${NC}"
		fi
		sleep 2
		;;
	6)
		read -p "探测间隔 (分钟, 回车保持不变): " new_probe
		if [[ "$new_probe" =~ ^[1-9][0-9]*$ ]]; then
			PROBE="$new_probe"
			_save_config
			echo -e "${GREEN}✅ 探测间隔已改为: $PROBE 分钟${NC}"
		else
			echo -e "${RED}❌ 请输入正整数${NC}"
		fi
		sleep 2
		;;
	7)
		clear
		echo -e "${CYAN}===== 自动热点日志 (最后50行) =====${NC}"
		if [ -f /var/log/wifi_auto_hotspot.log ]; then
			tail -n 50 /var/log/wifi_auto_hotspot.log
		else
			echo -e "${YELLOW}暂无日志${NC}"
		fi
		echo "--------------------------------------"
		local STATE_STR
		STATE_STR=$(cat /tmp/wifi_auto_hotspot_state 2>/dev/null || echo "normal|0")
		echo "当前状态: $STATE_STR"
		read -n 1 -s -r -p "按任意键返回..."
		;;
	8)
		echo -e "${YELLOW}手动触发检测...${NC}"
		bash "$SCRIPT_FILE"
		sleep 1
		local STATE_STR
		STATE_STR=$(cat /tmp/wifi_auto_hotspot_state 2>/dev/null || echo "normal|0")
		echo -e "检测后状态: ${GREEN}$STATE_STR${NC}"
		sleep 3
		;;
	0) return ;;
	esac
}


# --- 热点客户端列表 ---
show_hotspot_clients() {
	clear
	echo -e "${CYAN}======================================${NC}"
	echo -e "${CYAN} 热点客户端列表 ${NC}"
	echo -e "${CYAN}======================================${NC}"

	# 检查热点是否在运行
	local AP_CONN=""
	while IFS=: read -r _n _t _a; do
		[ "$_a" = "yes" ] || continue
		local _m; _m=$(nmcli -t -f 802-11-wireless.mode con show "$_n" 2>/dev/null | cut -d: -f2)
		[ "$_m" = "ap" ] && AP_CONN="$_n"
	done < <(nmcli -t -f NAME,TYPE,ACTIVE connection 2>/dev/null | grep ':802-11-wireless:')

	if [ -z "$AP_CONN" ]; then
		echo -e "${RED}❌ 热点未开启${NC}"
		echo -e "${YELLOW}请先在「热点与救生」中开启热点${NC}"
		read -n 1 -s -r -p "按任意键返回..."
		return
	fi

	echo -e "热点名称: ${GREEN}$AP_CONN${NC}"
	local IF; IF=$(get_wifi_iface)
	echo -e "接口: ${GREEN}$IF${NC}"
	echo "--------------------------------------"

	# 方法1: arp 表 (最可靠)
	local FOUND=0
	echo -e "${CYAN}已连接设备:${NC}"
	echo ""

	# 获取热点网段
	local HOTSPOT_IP; HOTSPOT_IP=$(nmcli -t -f IP4.ADDRESS dev show "$IF" 2>/dev/null | cut -d: -f2 | cut -d/ -f1)
	local SUBNET=""
	if [ -n "$HOTSPOT_IP" ]; then
		SUBNET=$(echo "$HOTSPOT_IP" | awk -F. '{printf "%s.%s.%s", $1, $2, $3}')
	fi

	# 从 arp/neigh 表获取
	while IFS= read -r line; do
		local IP_ADDR MAC_ADDR
		IP_ADDR=$(echo "$line" | awk '{print $1}')
		MAC_ADDR=$(echo "$line" | awk '{print $2}')

		# 跳过空 MAC 或自身
		[ -z "$MAC_ADDR" ] && continue
		[ "$MAC_ADDR" = "00:00:00:00:00:00" ] && continue
		[ "$MAC_ADDR" = "<incomplete>" ] && continue

		# 只显示热点网段的设备
		if [ -n "$SUBNET" ]; then
			case "$IP_ADDR" in
				${SUBNET}.*) ;;  # 匹配, 继续
				*) continue ;;   # 不匹配, 跳过
			esac
		fi

		# 尝试获取主机名
		local HOSTNAME; HOSTNAME=$(nslookup "$IP_ADDR" 2>/dev/null | grep -v "server" | grep "name" | awk '{print $4}' | sed 's/\.$//')
		[ -z "$HOSTNAME" ] && HOSTNAME="-"

		# MAC 厂商前缀
		local VENDOR; VENDOR=$(echo "$MAC_ADDR" | cut -c1-8 | tr 'a-f' 'A-F')

		printf "  %-16s %-18s %s\n" "$IP_ADDR" "$MAC_ADDR" "$HOSTNAME"
		FOUND=$((FOUND + 1))
	done < <(ip neigh show dev "$IF" 2>/dev/null | grep -v FAILED)

	# 补充: 如果 ip neigh 没数据, 试 arp -n
	if [ "$FOUND" -eq 0 ]; then
		while IFS= read -r line; do
			local IP_ADDR MAC_ADDR
			IP_ADDR=$(echo "$line" | awk '{print $1}')
			MAC_ADDR=$(echo "$line" | awk '{print $3}')
			[ -z "$MAC_ADDR" ] && continue
			[ "$MAC_ADDR" = "00:00:00:00:00:00" ] && continue
			[ "$MAC_ADDR" = "*<incomplete>" ] && continue

			if [ -n "$SUBNET" ]; then
				case "$IP_ADDR" in
					${SUBNET}.*) ;;
					*) continue ;;
				esac
			fi

			printf "  %-16s %-18s\n" "$IP_ADDR" "$MAC_ADDR"
			FOUND=$((FOUND + 1))
		done < <(arp -n 2>/dev/null | tail -n +2)
	fi

	echo "--------------------------------------"
	if [ "$FOUND" -gt 0 ]; then
		echo -e "共 ${GREEN}$FOUND${NC} 台设备连接"
	else
		echo -e "${YELLOW}暂无设备连接${NC}"
	fi

	echo "--------------------------------------"
	echo "0. 返回"
	read -n 1 -s -r -p "按任意键返回..."
}

# --- WiFi 密码查看 ---
show_wifi_passwords() {
	clear
	echo -e "${CYAN}======================================${NC}"
	echo -e "${CYAN} 已保存 WiFi 密码查看 ${NC}"
	echo -e "${CYAN}======================================${NC}"

	local IF; IF=$(get_wifi_iface)
	local ACTIVE_SSID; ACTIVE_SSID=$(nmcli -t -f CONNECTION dev show "$IF" 2>/dev/null | cut -d: -f2)

	# 列出所有已保存的 WiFi 连接 (排除 AP 模式)
	local SAVED
	SAVED=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | cut -d: -f1)

	if [ -z "$SAVED" ]; then
		echo -e "${RED}❌ 没有已保存的 WiFi 连接${NC}"
		read -n 1 -s -r -p "按任意键返回..."
		return
	fi

	local COUNT=0
	echo -e "${CYAN}SSID                            密码              状态${NC}"
	echo "--------------------------------------"

	while IFS= read -r conn; do
		[ -z "$conn" ] && continue

		# 跳过 AP 模式连接
		local MODE; MODE=$(nmcli -t -f 802-11-wireless.mode con show "$conn" 2>/dev/null | cut -d: -f2)
		[ "$MODE" = "ap" ] && continue

		# 获取 SSID (可能和连接名不同)
		local SSID; SSID=$(nmcli -t -f 802-11-wireless.ssid con show "$conn" 2>/dev/null | cut -d: -f2)
		[ -z "$SSID" ] && SSID="$conn"

		# 获取密码
		local PASS; PASS=$(nmcli -s -t -f 802-11-wireless-security.psk con show "$conn" 2>/dev/null | cut -d: -f2)
		[ -z "$PASS" ] && PASS="(无密码/未知)"

		# 获取状态
		local STATUS
		if [ "$conn" = "$ACTIVE_SSID" ]; then
			STATUS="🟢 已连接"
		else
			STATUS="⚪ 已保存"
		fi

		# 截断 SSID 到 30 字符
		local SSID_DISPLAY="$SSID"
		[ ${#SSID_DISPLAY} -gt 30 ] && SSID_DISPLAY="${SSID_DISPLAY:0:28}.."

		printf " %-30s %-16s %s\n" "$SSID_DISPLAY" "$PASS" "$STATUS"
		COUNT=$((COUNT + 1))
	done <<< "$SAVED"

	echo "--------------------------------------"
	echo -e "共 ${GREEN}$COUNT${NC} 个已保存的 WiFi"
	echo "--------------------------------------"
	echo "0. 返回"
	read -n 1 -s -r -p "按任意键返回..."
}


# --- 一键诊断报告 ---
diagnostic_report() {
	clear
	echo -e "${CYAN}======================================${NC}"
	echo -e "${CYAN} 一键诊断报告 ${NC}"
	echo -e "${CYAN}======================================${NC}"
	echo -e "${YELLOW}正在收集诊断信息...${NC}"

	local REPORT="/root/wifi_diagnostic_$(date +%Y%m%d_%H%M%S).txt"
	local IF; IF=$(get_wifi_iface)

	{
		echo "=========================================="
		echo "HiNAS WiFi 诊断报告"
		echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "脚本版本: v${VERSION}"
		echo "=========================================="
		echo ""

		echo "===== 1. 系统信息 ====="
		echo "主机名: $(hostname 2>/dev/null)"
		echo "系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
		echo "内核: $(uname -r 2>/dev/null)"
		echo "架构: $(uname -m 2>/dev/null)"
		echo "运行时间: $(uptime 2>/dev/null)"
		echo ""

		echo "===== 2. WiFi 接口 ====="
		echo "接口: $IF"
		echo "驱动: $(get_wifi_driver 2>/dev/null)"
		echo "MAC: $(cat /sys/class/net/$IF/address 2>/dev/null)"
		echo "IP: $(nmcli -t -f IP4.ADDRESS dev show "$IF" 2>/dev/null | cut -d: -f2)"
		echo "网关: $(ip route 2>/dev/null | awk '/default/ {print $3}' | head -1)"
		echo "DNS: $(cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -3)"
		echo ""

		echo "===== 3. WiFi 连接状态 ====="
		nmcli dev status 2>/dev/null
		echo ""
		echo "活跃连接:"
		nmcli -t -f NAME,TYPE,ACTIVE connection show 2>/dev/null | grep ':802-11-wireless:yes'
		echo ""
		echo "已保存连接:"
		nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless'
		echo ""

		echo "===== 4. 信号强度 ====="
		iw dev "$IF" link 2>/dev/null
		echo ""

		echo "===== 5. USB 设备 ====="
		lsusb 2>/dev/null
		echo ""

		echo "===== 6. 网络配置 ====="
		echo "--- /etc/resolv.conf ---"
		cat /etc/resolv.conf 2>/dev/null
		echo ""
		echo "--- sysctl IPv6 ---"
		cat /etc/sysctl.d/99-hinaswifi-ipv6.conf 2>/dev/null || echo "(无)"
		echo ""

		echo "===== 7. Crontab ====="
		crontab -l 2>/dev/null || echo "(无)"
		echo ""

		echo "===== 8. Watchdog 日志 (最后30行) ====="
		tail -n 30 /var/log/wifi_watchdog.log 2>/dev/null || echo "(无日志)"
		echo ""

		echo "===== 9. 断网统计 ====="
		cat /var/log/wifi_watchdog.stats 2>/dev/null | tail -n 20 || echo "(无统计)"
		echo ""

		echo "===== 10. 自动热点日志 (最后20行) ====="
		tail -n 20 /var/log/wifi_auto_hotspot.log 2>/dev/null || echo "(无日志)"
		echo ""

		echo "===== 11. dmesg WiFi 相关 (最后20行) ====="
		dmesg 2>/dev/null | grep -iE 'wifi|wlan|rtl|usb.*net|deauth|disassoc' | tail -n 20
		echo ""

		echo "===== 12. NetworkManager 状态 ====="
		nmcli general 2>/dev/null
		echo ""
		nmcli networking connectivity check 2>/dev/null
		echo ""

		echo "=========================================="
		echo "诊断报告结束"
		echo "=========================================="
	} > "$REPORT" 2>/dev/null

	local SIZE; SIZE=$(ls -la "$REPORT" 2>/dev/null | awk '{print $5}')
	echo -e "${GREEN}✅ 诊断报告已生成${NC}"
	echo "--------------------------------------"
	echo -e "文件: ${GREEN}$REPORT${NC} (${SIZE} bytes)"
	echo ""
	echo "可用以下方式查看:"
	echo "  cat $REPORT"
	echo "  scp root@<盒子IP>:$REPORT ./  # 传到电脑"
	echo "--------------------------------------"
	echo "1. 立即查看"
	echo "2. 清除所有诊断报告"
	echo "0. 返回"
	read -p "选项: " dr_choice
	if [ "$dr_choice" = "1" ]; then
		less "$REPORT" 2>/dev/null || cat "$REPORT" 2>/dev/null | head -80
		echo -e "${CYAN}--------------------------------------${NC}"
		read -n 1 -s -r -p "按任意键返回..."
	elif [ "$dr_choice" = "2" ]; then
		local OLD_COUNT=$(ls -1 /root/wifi_diagnostic_*.txt 2>/dev/null | wc -l)
		if [ "$OLD_COUNT" -eq 0 ]; then
			echo -e "${YELLOW}没有诊断报告文件${NC}"
		else
			echo -e "${YELLOW}找到 $OLD_COUNT 个诊断报告，确认清除? (y/n)${NC}"
			read -p "" confirm
			if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
				rm -f /root/wifi_diagnostic_*.txt
				echo -e "${GREEN}✅ 已清除 $OLD_COUNT 个诊断报告${NC}"
			else
				echo -e "${YELLOW}已取消${NC}"
			fi
		fi
		read -n 1 -s -r -p "按任意键返回..."
	fi

}
# --- 定时重连 ---
toggle_scheduled_reconnect() {
	clear
	echo -e "${CYAN}======================================${NC}"
	echo -e "${CYAN} 定时重连 WiFi ${NC}"
	echo -e "${CYAN}======================================${NC}"

	local RECONNECT_SCRIPT="/usr/local/bin/wifi_scheduled_reconnect.sh"
	local CRON_ENTRY; CRON_ENTRY=$(crontab -l 2>/dev/null | grep "$RECONNECT_SCRIPT")

	# 读取当前设置
	local CRON_TIME="3"  # 默认凌晨3点
	if [ -n "$CRON_ENTRY" ]; then
		CRON_TIME=$(echo "$CRON_ENTRY" | awk '{print $2}')
	fi

	if [ -n "$CRON_ENTRY" ]; then
		echo -e "状态: ${GREEN}▶ 已开启${NC} (每天 ${CRON_TIME}:00 重连)"
	else
		echo -e "状态: ${RED}⏸ 未开启${NC}"
	fi
	echo "--------------------------------------"
	echo -e "${YELLOW}定时重连: 每天指定时间自动断开重连WiFi${NC}"
	echo -e "${YELLOW}预防长时间运行导致驱动内存泄漏${NC}"
	echo "--------------------------------------"
	echo "1. 开启/关闭"
	echo "2. 设置重连时间 (当前: ${CRON_TIME}点)"
	echo "0. 返回"
	read -p "选项: " sr_choice

	case $sr_choice in
	1)
		if [ -n "$CRON_ENTRY" ]; then
			# 关闭
			crontab -l 2>/dev/null | grep -v "$RECONNECT_SCRIPT" | crontab -
			echo -e "${GREEN}✅ 已关闭定时重连${NC}"
		else
			# 生成重连脚本
			cat > "$RECONNECT_SCRIPT" << 'RCEOF'
#!/bin/bash
# 定时重连 WiFi — 预防驱动内存泄漏
IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | head -1)
[ -z "$IF" ] && exit 0
CONN=$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
[ -z "$CONN" ] || [ "$CONN" = "--" ] && exit 0
logger -t wifi_reconnect "定时重连: $CONN"
nmcli con down "$CONN" >/dev/null 2>&1
sleep 2
nmcli con up "$CONN" >/dev/null 2>&1
RCEOF
			chmod +x "$RECONNECT_SCRIPT"
			(crontab -l 2>/dev/null | grep -v "$RECONNECT_SCRIPT"; echo "0 $CRON_TIME * * * $RECONNECT_SCRIPT") | crontab -
			echo -e "${GREEN}✅ 已开启定时重连 (每天 ${CRON_TIME}:00)${NC}"
		fi
		sleep 3
		;;
	2)
		read -p "重连时间 (小时 0-23, 回车保持不变): " new_time
		if [[ "$new_time" =~ ^[0-9]$|^1[0-9]$|^2[0-3]$ ]]; then
			CRON_TIME="$new_time"
			# 如果已开启, 更新 crontab
			if [ -n "$CRON_ENTRY" ] || [ -n "$(crontab -l 2>/dev/null | grep "$RECONNECT_SCRIPT")" ]; then
				crontab -l 2>/dev/null | grep -v "$RECONNECT_SCRIPT" | crontab -
				(crontab -l 2>/dev/null; echo "0 $CRON_TIME * * * $RECONNECT_SCRIPT") | crontab -
			fi
			echo -e "${GREEN}✅ 重连时间已设为 ${CRON_TIME}:00${NC}"
		else
			echo -e "${RED}❌ 请输入 0-23${NC}"
		fi
		sleep 2
		;;
	0) return ;;
	esac
}

# --- 多 WiFi 优先级 ---
wifi_priority() {
	clear
	echo -e "${CYAN}======================================${NC}"
	echo -e "${CYAN} 多 WiFi 优先级 ${NC}"
	echo -e "${CYAN}======================================${NC}"

	local IF; IF=$(get_wifi_iface)

	# 列出已保存的 WiFi (排除 AP)
	local SAVED
	SAVED=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | cut -d: -f1)

	if [ -z "$SAVED" ]; then
		echo -e "${RED}❌ 没有已保存的 WiFi 连接${NC}"
		echo -e "${YELLOW}请先扫描连接 WiFi${NC}"
		read -n 1 -s -r -p "按任意键返回..."
		return
	fi

	echo -e "${YELLOW}已保存的 WiFi (按 autoconnect-priority 排序)${NC}"
	echo "--------------------------------------"
	echo -e "${CYAN}序号  优先级  SSID                            状态${NC}"
	echo "--------------------------------------"

	local COUNT=0
	local CONN_ARRAY=()
	while IFS= read -r conn; do
		[ -z "$conn" ] && continue
		local MODE; MODE=$(nmcli -t -f 802-11-wireless.mode con show "$conn" 2>/dev/null | cut -d: -f2)
		[ "$MODE" = "ap" ] && continue

		COUNT=$((COUNT + 1))
		CONN_ARRAY[$COUNT]="$conn"

		local PRIO; PRIO=$(nmcli -t -f connection.autoconnect-priority con show "$conn" 2>/dev/null | cut -d: -f2)
		[ -z "$PRIO" ] && PRIO="0"

		local SSID; SSID=$(nmcli -t -f 802-11-wireless.ssid con show "$conn" 2>/dev/null | cut -d: -f2)
		[ -z "$SSID" ] && SSID="$conn"

		local ACTIVE; ACTIVE=$(nmcli -t -f NAME,ACTIVE con show 2>/dev/null | grep "^${conn}:yes" | cut -d: -f2)
		local STATUS
		if [ "$ACTIVE" = "yes" ]; then
			STATUS="🟢 已连接"
		else
			STATUS="⚪"
		fi

		local SSID_DISPLAY="$SSID"
		[ ${#SSID_DISPLAY} -gt 30 ] && SSID_DISPLAY="${SSID_DISPLAY:0:28}.."

		printf "  %-4s  %-6s  %-30s  %s\n" "$COUNT" "$PRIO" "$SSID_DISPLAY" "$STATUS"
	done <<< "$SAVED"

	echo "--------------------------------------"
	echo -e "${YELLOW}优先级越高越先连接 (数字大的优先)${NC}"
	echo "--------------------------------------"
	echo "1. 设置优先级"
	echo "2. 一键按信号强度自动排序"
	echo "0. 返回"
	read -p "选项: " wp_choice

	case $wp_choice in
	1)
		read -p "输入序号 (1-$COUNT): " idx
		if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$COUNT" ]; then
			read -p "优先级 (数字, 越大越优先): " prio
			if [[ "$prio" =~ ^-?[0-9]+$ ]]; then
				local TARGET=${CONN_ARRAY[$idx]}
				nmcli con mod "$TARGET" connection.autoconnect-priority "$prio" 2>/dev/null
				echo -e "${GREEN}✅ 已设置 '$TARGET' 优先级为 $prio${NC}"
			else
				echo -e "${RED}❌ 请输入数字${NC}"
			fi
		else
			echo -e "${RED}❌ 无效序号${NC}"
		fi
		sleep 2
		;;
	2)
		# 按当前信号强度自动排序
		echo -e "${YELLOW}正在扫描信号...${NC}"
		timeout 10 nmcli device wifi rescan ifname "$IF" >/dev/null 2>&1
		sleep 3

		local PRIORITY=100
		while IFS= read -r conn; do
			[ -z "$conn" ] && continue
			local MODE; MODE=$(nmcli -t -f 802-11-wireless.mode con show "$conn" 2>/dev/null | cut -d: -f2)
			[ "$MODE" = "ap" ] && continue

			local SSID; SSID=$(nmcli -t -f 802-11-wireless.ssid con show "$conn" 2>/dev/null | cut -d: -f2)
			[ -z "$SSID" ] && continue

			# 从扫描结果找信号
			local SIG; SIG=$(nmcli -t -f SSID,SIGNAL dev wifi list 2>/dev/null | grep "^${SSID}:" | cut -d: -f2 | sort -rn | head -1)
			if [ -n "$SIG" ]; then
				nmcli con mod "$conn" connection.autoconnect-priority "$((SIG * 10))" 2>/dev/null
				echo "  $SSID → 优先级 $((SIG * 10)) (信号 ${SIG})"
			else
				nmcli con mod "$conn" connection.autoconnect-priority "$PRIORITY" 2>/dev/null
				echo "  $SSID → 优先级 $PRIORITY (未扫描到)"
				PRIORITY=$((PRIORITY - 10))
			fi
		done <<< "$SAVED"
		echo -e "${GREEN}✅ 已按信号强度自动排序${NC}"
		sleep 3
		;;
	0) return ;;
	esac
}

while true; do
 clear
 echo -e "${CYAN}=================================================${NC}"
 echo -e "${CYAN} HiNAS WiFi 控制面板 v${VERSION} ${NC}"
 echo -e "${CYAN}=================================================${NC}"
 echo -e " 1. 网络连接  (扫描/密码/BSSID/优先级/多WiFi)"
 echo -e " 2. 热点与救生 (热点/客户端/自动热点)"
 echo -e " 3. 防掉线守护 (watchdog/统计/省电/定时重连)"
 echo -e " 4. 网络配置  (IP/IPv6/DNS)"
 echo -e " 5. 诊断与工具 (信息/测速/信道/备份/诊断报告)"
 echo -e " 6. 驱动与更新 (驱动/在线更新)"
 echo " 0. 退出"
 echo -e "${CYAN}-------------------------------------------------${NC}"
 echo -e " ${GREEN}wifi${NC} 快速打开 | v${VERSION}"
 echo -e "${CYAN}=================================================${NC}"
 read -p "选项 [0-6]: " choice
 case $choice in
 1)
  while true; do
   clear
   echo -e "${CYAN}========== 网络连接 ==========${NC}"
   echo " 1. 扫描并连接 WiFi"
   echo " 2. WiFi 密码查看"
   _BSSID_LOCK=""
   _ACTIVE_CONN=$(nmcli -t -f NAME,ACTIVE con show 2>/dev/null | grep ':yes' | cut -d: -f1)
   if [ -n "$_ACTIVE_CONN" ]; then
     _BSSID_VAL=$(nmcli -t -f 802-11-wireless.bssid con show "$_ACTIVE_CONN" 2>/dev/null | cut -d: -f2-)
     [ -n "$_BSSID_VAL" ] && [ "$_BSSID_VAL" != "--" ] && _BSSID_LOCK="${GREEN}"
   fi
   [ -n "$_BSSID_LOCK" ] && echo -e " 3. ${_BSSID_LOCK}BSSID 锁定/解除${NC} 🔒已锁定" || echo " 3. BSSID 锁定/解除"
   echo " 4. 多网卡优先级"
   echo " 5. 多 WiFi 优先级"
   echo " 0. 返回主菜单"
   echo -e "${CYAN}==============================${NC}"
   read -p "选项: " sub
   case $sub in
   1) connect_wifi ;;
   2) show_wifi_passwords ;;
   3) toggle_bssid_lock ;;
   4) config_priority ;;
   5) wifi_priority ;;
   0) break ;;
   *) echo -e "${RED}无效${NC}"; sleep 1 ;;
   esac
  done ;;
 2)
  while true; do
   clear
   echo -e "${CYAN}========== 热点与救生 ==========${NC}"
   echo " 1. WiFi 热点 (AP模式)"
   echo " 2. 热点客户端列表"
   _AH=""; crontab -l 2>/dev/null | grep -q "wifi_auto_hotspot.sh" && _AH="${GREEN}"
   [ -n "$_AH" ] && echo -e " 3. ${_AH}自动热点救生${NC} ▶已开启" || echo " 3. 自动热点救生"
   echo " 0. 返回主菜单"
   echo -e "${CYAN}================================${NC}"
   read -p "选项: " sub
   case $sub in
   1) toggle_hotspot ;;
   2) show_hotspot_clients ;;
   3) toggle_auto_hotspot ;;
   0) break ;;
   *) echo -e "${RED}无效${NC}"; sleep 1 ;;
   esac
  done ;;
 3)
  while true; do
   clear
   echo -e "${CYAN}======== 防掉线守护 ========${NC}"
   _WD=""; crontab -l 2>/dev/null | grep -q "wifi_watchdog.sh" && _WD="${GREEN}"
   [ -n "$_WD" ] && echo -e " 1. ${_WD}守护开关${NC} ▶已开启" || echo " 1. 守护开关 (watchdog v3.5)"
   echo " 2. 断网统计面板"
   _PS=""; _IF=$(get_wifi_iface); iw dev "$_IF" get power_save 2>/dev/null | grep -q on && _PS="${GREEN}"
   [ -n "$_PS" ] && echo -e " 3. ${_PS}省电模式${NC} ▶已开启" || echo " 3. 省电模式开关"
   _RC=""; crontab -l 2>/dev/null | grep -q "wifi_scheduled_reconnect.sh" && _RC="${GREEN}"
   [ -n "$_RC" ] && echo -e " 4. ${_RC}定时重连${NC} ▶已开启" || echo " 4. 定时重连"
   echo " 0. 返回主菜单"
   echo -e "${CYAN}============================${NC}"
   read -p "选项: " sub
   case $sub in
   1) toggle_watchdog ;;
   2) watchdog_stats ;;
   3) toggle_power_save ;;
   4) toggle_scheduled_reconnect ;;
   0) break ;;
   *) echo -e "${RED}无效${NC}"; sleep 1 ;;
   esac
  done ;;
 4)
  while true; do
   clear
   echo -e "${CYAN}========== 网络配置 ==========${NC}"
   echo " 1. 配置静态/动态 IP"
   _IF6=$(get_wifi_iface); _IPV6=""; [ "$(nmcli -t -f ipv6.method con show "$(nmcli -t -f NAME,ACTIVE con show 2>/dev/null | grep :yes | cut -d: -f1)" 2>/dev/null | cut -d: -f2)" = "ignore" ] && _IPV6="${GREEN}"
   [ -n "$_IPV6" ] && echo -e " 2. ${_IPV6}IPv6 模式${NC} ▶ignore" || echo " 2. IPv6 模式开关"
   echo " 3. IPv6 详细面板"
   echo " 4. DNS 测速优化"
   echo " 0. 返回主菜单"
   echo -e "${CYAN}==============================${NC}"
   read -p "选项: " sub
   case $sub in
   1) config_ip_mode ;;
   2) toggle_ipv6 ;;
   3) ipv6_panel ;;
   4) dns_optimize ;;
   0) break ;;
   *) echo -e "${RED}无效${NC}"; sleep 1 ;;
   esac
  done ;;
 5)
  while true; do
   clear
   echo -e "${CYAN}======== 诊断与工具 ========${NC}"
   echo " 1. 网络信息与体检 (含信号强度)"
   echo " 2. 网络测速 (国内/国外)"
   echo " 3. WiFi 信道分析"
   echo " 4. 配置备份/恢复"
   echo " 5. 一键诊断报告"
   echo " 0. 返回主菜单"
   echo -e "${CYAN}============================${NC}"
   read -p "选项: " sub
   case $sub in
   1) show_network_info ;;
   2) run_speedtest ;;
   3) channel_analysis ;;
   4) backup_restore ;;
   5) diagnostic_report ;;
   0) break ;;
   *) echo -e "${RED}无效${NC}"; sleep 1 ;;
   esac
  done ;;
 6)
  while true; do
   clear
   echo -e "${CYAN}======== 驱动与更新 ========${NC}"
   echo " 1. 安装 WIFI 驱动 (RTL8188等)"
   echo " 2. 在线更新 (当前 v${VERSION})"
   echo " 0. 返回主菜单"
   echo -e "${CYAN}============================${NC}"
   read -p "选项: " sub
   case $sub in
   1) install_driver ;;
   2) update_script ;;
   0) break ;;
   *) echo -e "${RED}无效${NC}"; sleep 1 ;;
   esac
  done ;;
 0) clear; echo "已退出。"; exit 0 ;;
 *) echo -e "${RED}无效${NC}"; sleep 1 ;;
 esac
done
[/Untrusted web content]
