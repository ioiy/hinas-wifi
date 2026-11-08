#!/bin/bash

# ==========================================
# HiNAS WiFi 控制面板 (终极进化版)
# 项目地址: https://github.com/ioiy/hinas-wifi
# v1.9.3: 全面优化 — 去重+修复+保活+信号+统计
# ==========================================

VERSION="1.9.3"
UPDATE_URL="https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh"
WATCHDOG_SCRIPT="/usr/local/bin/wifi_watchdog.sh"
KEEPALIVE_SCRIPT="/usr/local/bin/wifi_keepalive.sh"

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
    echo "$CONN"
}

get_wifi_driver() {
    local DRV
    DRV=$(lsmod 2>/dev/null | grep -iE "rtl8188|rtl8xxxu|8188" | awk '{print $1}' | head -n 1)
    [ -z "$DRV" ] && DRV="rtl8188fu"
    echo "$DRV"
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

# --- 省电关闭 (统一: 只写 WiFi 设备 sysfs, 不碰所有 USB) ---
disable_power_save() {
    local IF
    IF=$(get_wifi_iface)
    iw dev "$IF" set power_save off 2>/dev/null
    local CONN
    CONN=$(get_wifi_conn)
    if [ -n "$CONN" ]; then
        nmcli con mod "$CONN" 802-11-wireless.powersave 2 2>/dev/null
    fi
    # 只写 WiFi 设备对应的 USB power control, 不写所有 USB 设备
    local dev_path="/sys/class/net/${IF}/device/power/control"
    [ -f "$dev_path" ] && echo on > "$dev_path" 2>/dev/null
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
    ping6 -c 2 -W 3 2408:8899::8 >/dev/null 2>&1 && return 0
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
    CLOUD_VERSION=$(wget -qO- "$UPDATE_URL" | grep -E '^VERSION=' | head -n 1 | cut -d'"' -f2)
    if [ -z "$CLOUD_VERSION" ]; then
        echo -e "${RED}❌ 获取云端版本失败。${NC}"
        sleep 3; return
    fi
    echo -e "当前本地版本: ${CYAN}v${VERSION}${NC}"
    echo -e "发现云端版本: ${GREEN}v${CLOUD_VERSION}${NC}"
    echo "--------------------------------------"
    if [ "$VERSION" == "$CLOUD_VERSION" ]; then
        echo -e "${GREEN}✅ 当前已是最新版本，无需更新！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."; return
    fi
    read -p "是否确认更新到 v${CLOUD_VERSION}？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消更新。${NC}"; sleep 1; return
    fi
    echo -e "${GREEN}正在下载最新代码...${NC}"
    if wget -q -O /tmp/hinaswifi.sh.tmp "$UPDATE_URL"; then
        # 校验下载的文件是否合法 (必须包含 VERSION= 行)
        if ! grep -q '^VERSION=' /tmp/hinaswifi.sh.tmp; then
            echo -e "${RED}❌ 下载的文件不合法(缺少VERSION行)，已放弃更新。${NC}"
            rm -f /tmp/hinaswifi.sh.tmp; sleep 3; return
        fi
        # 备份当前版本
        cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak" 2>/dev/null
        echo -e "${YELLOW}已备份当前版本到 ${SCRIPT_PATH}.bak${NC}"
        # 覆盖并重启
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
    local action=$1  # on/off
    cat > "$KEEPALIVE_SCRIPT" << 'KAEOF'
#!/bin/bash
# WiFi Keepalive — 每分钟 ping 网关, 保持连接活跃, 防止路由器踢掉空闲客户端
GATEWAY=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -1)
[ -z "$GATEWAY" ] && exit 0
ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1
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
    echo -e "${CYAN} WiFi 防掉线守护进程 v3.1 ${NC}"
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
        echo -e "省电模式: ${RED}开启 (可能导致断网！)${NC}"
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
    echo -e "4. ${GREEN}开启/关闭 连接保活${NC} (防路由器踢空闲)"
    echo -e "5. ${GREEN}查看故障快照${NC} (断网诊断)"
    echo "0. 返回主菜单"
    echo -e "${CYAN}======================================${NC}"
    read -p "请输入选项: " wd_choice
    case $wd_choice in
    1)
        read -p "请输入检测间隔(分钟，回车默认2分钟): " interval
        if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
            interval=2
            echo -e "${YELLOW}使用默认间隔: 2 分钟${NC}"
        fi
        CRON_JOB="*/$interval * * * * $WATCHDOG_SCRIPT"
        echo "正在配置后台守护进程..."
        cat > "$WATCHDOG_SCRIPT" << 'WD1'
#!/bin/bash
# WiFi Watchdog v3.1 — 增强日志 + 安全恢复 + 信号记录 + 断网原因归类
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
    echo "$CONN"
}

get_signal() { iw dev "$1" link 2>/dev/null | grep -oP 'signal: \K[-0-9]+'; }

categorize_reason() {
    local IF=$1 reason="unknown" recent_dmesg
    recent_dmesg=$(dmesg 2>&1 | tail -20)
    if echo "$recent_dmesg" | grep -qiE "deauth|disassoc"; then
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

disable_ps() {
    local IF=$1
    iw dev "$IF" set power_save off 2>/dev/null
    local CONN; CONN=$(detect_conn)
    [ -n "$CONN" ] && nmcli con mod "$CONN" 802-11-wireless.powersave 2 2>/dev/null
    local dp="/sys/class/net/${IF}/device/power/control"
    [ -f "$dp" ] && echo on > "$dp" 2>/dev/null
}

check_associated() { [ -n "$(iw dev "$1" link 2>/dev/null | grep 'Connected to')" ]; }
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
    log "  快照已保存: $snapdir"
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
            log "  L1: nmcli con up ($CONN), 等待 ${patience}s..."
            nmcli con up "$CONN" >/dev/null 2>&1; rc=$?
            log "  L1: nmcli 返回 $rc"
            sleep "$patience"
            if check_net; then rc=0; log "  L1: ✅ 网络恢复"; fi
        else
            log "  L1: 无连接名, 跳过"
        fi ;;
    2)
        log "  L2: WiFi radio off→on, 等待 ${patience}s..."
        nmcli radio wifi off >/dev/null 2>&1; sleep 3
        nmcli radio wifi on  >/dev/null 2>&1; sleep 5
        local CONN; CONN=$(detect_conn)
        [ -n "$CONN" ] && nmcli con up "$CONN" >/dev/null 2>&1; rc=$?
        log "  L2: radio 重启完成, nmcli 返回 $rc"
        sleep "$patience"
        if check_net; then rc=0; log "  L2: ✅ 网络恢复"; fi ;;
    3)
        log "  L3: ip link down→up (软重启网卡), 等待 ${patience}s..."
        log "    (不使用 rmmod/modprobe — 内置USB WiFi热拔驱动不安全)"
        ip link set "$IF" down 2>/dev/null; sleep 3
        ip link set "$IF" up   2>/dev/null; sleep 5
        local CONN; CONN=$(detect_conn)
        [ -n "$CONN" ] && nmcli con up "$CONN" >/dev/null 2>&1; rc=$?
        log "  L3: ip link 重启完成, nmcli 返回 $rc"
        sleep "$patience"
        if check_net; then rc=0; log "  L3: ✅ 网络恢复"; fi ;;
    4)
        log "  L4: 重启 NetworkManager, 等待 ${patience}s..."
        systemctl restart NetworkManager >/dev/null 2>&1; rc=$?
        log "  L4: NM 重启返回 $rc"
        sleep "$patience"
        IF=$(detect_iface)
        local CONN; CONN=$(detect_conn)
        [ -n "$CONN" ] && nmcli con up "$CONN" >/dev/null 2>&1
        if check_net; then rc=0; log "  L4: ✅ 网络恢复"; fi ;;
    esac
    return $rc
}
WD2
        cat >> "$WATCHDOG_SCRIPT" << 'WD3'

# ========== 主循环 ==========
rotate_log
IF=$(detect_iface)
CONN=$(detect_conn)
SIG=$(get_signal "$IF")
if [ -n "$SIG" ]; then
    log "检测开始 — IF=$IF CONN=$CONN 信号=${SIG}dBm"
else
    log "检测开始 — IF=$IF CONN=$CONN 信号=无"
fi
disable_ps "$IF"

if ! check_associated "$IF"; then
    log "⚠ WiFi 未关联到任何 AP"
    start_timer
    REASON=$(categorize_reason "$IF")
    log "  断网原因: $REASON"
    for level in 1 2 3 4; do
        case $level in 1) p=60 ;; 2) p=90 ;; 3) p=120 ;; 4) p=60 ;; esac
        recover_with_patience "$level" "$p" "$IF"
        if [ $? -eq 0 ]; then
            DUR=$(elapsed_time)
            log "✅ 恢复成功 (L${level}), 耗时 ${DUR}s, 原因: $REASON"
            log_stats "success" "L${level}" "$DUR" "$REASON"
            exit 0
        fi
    done
    DUR=$(elapsed_time)
    log "❌ 全部恢复失败, 耗时 ${DUR}s, 原因: $REASON"
    log_stats "fail" "L4" "$DUR" "$REASON"
    capture_snapshot "recovery_failed" "$IF"
    exit 1
fi

if ! check_net; then
    log "⚠ 已关联但无网络"
    start_timer
    REASON=$(categorize_reason "$IF")
    log "  断网原因: $REASON"
    for level in 1 2 3 4; do
        case $level in 1) p=60 ;; 2) p=90 ;; 3) p=120 ;; 4) p=60 ;; esac
        recover_with_patience "$level" "$p" "$IF"
        if [ $? -eq 0 ]; then
            DUR=$(elapsed_time)
            log "✅ 恢复成功 (L${level}), 耗时 ${DUR}s, 原因: $REASON"
            log_stats "success" "L${level}" "$DUR" "$REASON"
            exit 0
        fi
    done
    DUR=$(elapsed_time)
    log "❌ 全部恢复失败, 耗时 ${DUR}s, 原因: $REASON"
    log_stats "fail" "L4" "$DUR" "$REASON"
    capture_snapshot "recovery_failed" "$IF"
    exit 1
fi

# 网络正常, 静默退出
exit 0
WD3
        chmod +x "$WATCHDOG_SCRIPT"
        (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_JOB") | crontab -
        echo -e "${GREEN}✅ 自动重连已开启 (每 $interval 分钟检测)${NC}"
        echo -e "${YELLOW}watchdog v3.1: 耐心恢复(5.5分钟) | 安全ip link | 信号记录 | 断网归类 | 统计数据${NC}"
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
            echo -e "${GREEN}✅ 已开启连接保活 (每分钟 ping 网关, 防路由器踢空闲)${NC}"
        fi
        sleep 2
        ;;
    5)
        clear
        echo -e "${CYAN}===== 故障快照查看 =====${NC}"
        if [ -d /var/log/wifi_debug ] && [ -n "$(ls -A /var/log/wifi_debug 2>/dev/null)" ]; then
            echo "可用快照:"
            ls -dt /var/log/wifi_debug/*_* 2>/dev/null | head -10 | while read -r d; do
                echo "  $(basename "$d")"
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
    echo -e "接口:     ${GREEN}$WIFI_IF${NC}"
    echo -e "驱动:     ${GREEN}$WIFI_DRIVER${NC}"
    echo -e "SSID:     ${GREEN}$SSID${NC}"
    echo -e "MAC:      ${GREEN}$MAC_ADDR${NC}"
    echo -e "IPv4:     ${GREEN}$LAN_IP${NC}"
    echo -e "IPv6:     ${GREEN}$IPV6_ADDR${NC}"
    echo -e "网关:     ${GREEN}$GATEWAY${NC}"
    echo -e "DNS:      ${GREEN}$DNS${NC}"
    echo -e "公网IP:   ${GREEN}$PUBLIC_IP${NC}"
    if [ -n "$SIG" ]; then
        if [ "$SIG" -lt -70 ]; then
            echo -e "信号:     ${RED}${SIG} dBm (较弱)${NC}"
        elif [ "$SIG" -lt -60 ]; then
            echo -e "信号:     ${YELLOW}${SIG} dBm (一般)${NC}"
        else
            echo -e "信号:     ${GREEN}${SIG} dBm (良好)${NC}"
        fi
    else
        echo -e "信号:     ${YELLOW}未获取${NC}"
    fi
    if [ "$PS_STATE" = "on" ]; then
        echo -e "省电:     ${RED}开启(建议关闭! 菜单3→1开启watchdog自动关)${NC}"
    else
        echo -e "省电:     ${GREEN}已关闭${NC}"
    fi

    # 体检 (ping 测试)
    echo "--------------------------------------"
    echo -e "${CYAN}网络体检:${NC}"
    echo -n "  [1] 网卡($WIFI_IF): "
    ip link show "$WIFI_IF" >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}"
    echo -n "  [2] 网关($GATEWAY): "
    ping -c 2 -W 2 "$GATEWAY" >/dev/null 2>&1 && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
    echo -n "  [3] DNS(223.5.5.5): "
    ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && echo -e "${GREEN}正常${NC}" || echo -e "${RED}无响应${NC}"
    echo -n "  [4] 公网: "
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
    echo "1.静态IP  2.动态IP  0.返回"
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
    read -p "优先连接名(q返回): " pri_conn
    [[ "$pri_conn" == "q" || -z "$pri_conn" ]] && return
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
    if command -v python3 >/dev/null 2>&1; then
        wget -qO- https://ghfast.top/https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -u -
    elif command -v python >/dev/null 2>&1; then
        wget -qO- https://ghfast.top/https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python -u -
    else
        wget -O /dev/null http://speedtest.tele2.net/10MB.zip --show-progress
    fi
    read -n 1 -s -r -p "按任意键返回..."
}

toggle_hotspot() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN} WiFi 热点 ${NC}"
    echo -e "${CYAN}======================================${NC}"
    WIFI_IF=$(get_wifi_iface)
    echo "1.开启 2.关闭 0.返回"
    read -p "选项: " hs
    case $hs in
    1)
        read -p "SSID: " ssid; [ -z "$ssid" ] && return
        read -s -p "密码(8位+): " pwd; echo
        [ ${#pwd} -lt 8 ] && return
        nmcli device wifi hotspot ifname "$WIFI_IF" ssid "$ssid" password "$pwd"
        [ $? -eq 0 ] && echo -e "${GREEN}✅ $ssid${NC}" || echo -e "${RED}❌ 失败${NC}"
        ;;
    2)
        # 只关闭 AP/hotspot 连接, 不关闭正常的 WiFi client 连接
        local AP_CONN
        AP_CONN=$(nmcli -t -f NAME,TYPE,ACTIVE connection 2>/dev/null | awk -F: '$3=="yes" && $2=="802-11-wireless" {print $1}' | while read -r name; do
            mode=$(nmcli -t -f 802-11-wireless.mode con show "$name" 2>/dev/null | cut -d: -f2)
            [ "$mode" = "ap" ] && echo "$name"
        done | head -1)
        if [ -n "$AP_CONN" ]; then
            nmcli con down "$AP_CONN" >/dev/null 2>&1 && echo -e "${GREEN}✅ 已关闭热点 ($AP_CONN)${NC}" || echo -e "${RED}❌ 关闭失败${NC}"
        else
            echo -e "${YELLOW}未找到活跃的热点连接${NC}"
        fi
        ;;
    0) return ;;
    esac
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
    echo "扫描中..."
    nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1; sleep 2
    nmcli device wifi list ifname "$WIFI_IF"
    echo "--------------------------------------"
    read -p "WiFi名称(回车返回): " ssid; [ -z "$ssid" ] && return
    read -s -p "密码(无密码回车): " password; echo
    if [ -z "$password" ]; then
        nmcli device wifi connect "$ssid" ifname "$WIFI_IF"
    else
        nmcli device wifi connect "$ssid" password "$password" ifname "$WIFI_IF"
    fi
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 成功${NC}"
        disable_power_save  # 连接成功后关省电
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
        [ -z "$T1" ] && { echo -e "  $NAME ($IP):    ${RED}无响应${NC}"; continue; }
        T2=$(ping -c 1 -W 2 "$IP" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
        T3=$(ping -c 1 -W 2 "$IP" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
        AVG=$(echo "scale=1; ($T1+$T2+$T3)/3" | bc 2>/dev/null || echo "$T1")
        printf "  %-12s (%s):  %6s ms\n" "$NAME" "$IP" "$AVG"
        if [ -n "$AVG" ]; then
            CMP=$(echo "$AVG < $BEST_TIME" | bc 2>/dev/null)
            if [ "$CMP" = "1" ]; then
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
    nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1
    sleep 3
    SCAN=$(nmcli -t -f SSID,CHAN,SIGNAL dev wifi list ifname "$WIFI_IF" 2>/dev/null)
    if [ -z "$SCAN" ]; then
        echo -e "${RED}❌ 扫描失败${NC}"; read -n 1 -s -r -p "按任意键返回..."; return
    fi
    echo "--------------------------------------"
    echo -e "${CYAN}信道  AP数  最强信号  拥挤度${NC}"
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
        printf "  %2d    %2d    %4s    " "$ch" "$COUNT" "$MAXSIG"
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
            tar czf "$BACKUP_FILE" "$CONN_DIR" \
                /tmp/wifi_crontab_backup.txt 2>/dev/null
            [ -f "$WATCHDOG_SCRIPT" ] && tar rf "$BACKUP_FILE" "$WATCHDOG_SCRIPT" 2>/dev/null
            [ -f "$KEEPALIVE_SCRIPT" ] && tar rf "$BACKUP_FILE" "$KEEPALIVE_SCRIPT" 2>/dev/null
            # tar 不支持追加压缩文件, 重新压缩
            nmcli -t -f NAME,TYPE,DEVICE connection show > "$BACKUP_DIR/conn_list_$TIMESTAMP.txt" 2>/dev/null
            SIZE=$(ls -la "$BACKUP_FILE" 2>/dev/null | awk '{print $5}')
            echo -e "${GREEN}✅ 备份成功${NC}"
            echo -e "文件: $BACKUP_FILE (${SIZE} bytes)"
            echo -e "内容: NM配置 + crontab + watchdog/keepalive脚本"
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
            echo "  $(basename "$f")  ($(ls -la "$f" | awk '{print $5}') bytes)"
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
            echo -e "  ${GREEN}$(basename "$f")${NC}  $(ls -la "$f" | awk '{print $5}')B"
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
    echo -e "  接口: ${GREEN}$WIFI_IF${NC}"
    echo -n "  IPv6 地址:"
    IPV6_ADDRS=$(ip -6 addr show dev "$WIFI_IF" 2>/dev/null | grep "scope global" | awk '{print $2}')
    if [ -n "$IPV6_ADDRS" ]; then
        echo ""
        echo "$IPV6_ADDRS" | while read -r addr; do
            echo -e "    ${GREEN}$addr${NC}"
        done
    else
        echo -e "  ${RED}无${NC}"
    fi
    IPV6_PREFIX=$(echo "$IPV6_ADDRS" | head -1)
    if [ -n "$IPV6_PREFIX" ]; then
        echo -e "  前缀长度: ${GREEN}/$(echo "$IPV6_PREFIX" | cut -d/ -f2)${NC}"
    fi
    IPV6_GW=$(ip -6 route 2>/dev/null | awk '/default/ {print $3}' | head -1)
    echo -n "  IPv6 网关: "
    [ -n "$IPV6_GW" ] && echo -e "${GREEN}$IPV6_GW${NC}" || echo -e "${RED}无${NC}"
    IPV6_DNS=$(grep -E "nameserver" /etc/resolv.conf 2>/dev/null | grep ":" | awk '{print $2}' | head -1)
    echo -n "  IPv6 DNS:  "
    [ -n "$IPV6_DNS" ] && echo -e "${GREEN}$IPV6_DNS${NC}" || echo -e "${YELLOW}无(仅IPv4 DNS)${NC}"
    RA_STATE=$(cat /proc/sys/net/ipv6/conf/$WIFI_IF/accept_ra 2>/dev/null)
    echo -n "  接收RA:    "
    case "$RA_STATE" in
        0) echo -e "${RED}关闭${NC}" ;;
        1) echo -e "${GREEN}开启${NC}" ;;
        2) echo -e "${GREEN}开启(转发模式)${NC}" ;;
        *) echo -e "${YELLOW}未知($RA_STATE)${NC}" ;;
    esac
    IPV6_DISABLE=$(cat /proc/sys/net/ipv6/conf/$WIFI_IF/disable_ipv6 2>/dev/null)
    echo -n "  IPv6启用:  "
    [ "$IPV6_DISABLE" = "0" ] && echo -e "${GREEN}是${NC}" || echo -e "${RED}否${NC}"
    echo "--------------------------------------"
    echo -e "${CYAN}【连通性测试】${NC}"
    echo -n "  网关连通:  "
    if [ -n "$IPV6_GW" ]; then
        ping6 -c 2 -W 2 "$IPV6_GW" >/dev/null 2>&1 && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
    else
        echo -e "${YELLOW}无网关${NC}"
    fi
    echo -n "  国内(taobao): "
    curl -6 -s --connect-timeout 3 -o /dev/null -w "%{http_code}" https://www.taobao.com 2>/dev/null | grep -q "200\|301\|302" && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
    echo -n "  公网IPv6:  "
    PUB6=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org 2>/dev/null)
    [ -n "$PUB6" ] && echo -e "${GREEN}$PUB6${NC}" || echo -e "${RED}获取失败${NC}"
    echo "--------------------------------------"
    echo -e "${CYAN}【地址配置方式】${NC}"
    if echo "$IPV6_ADDRS" | grep -qP ":[0-9a-f:]+/(64|48|56)$"; then
        echo -e "  方式: ${GREEN}SLAAC (无状态自动配置)${NC}"
    elif [ -n "$IPV6_ADDRS" ]; then
        echo -e "  方式: ${YELLOW}DHCPv6 或手动配置${NC}"
    else
        echo -e "  方式: ${RED}未配置${NC}"
    fi
    echo -e "${CYAN}======================================${NC}"
    read -n 1 -s -r -p "按任意键返回..."
}

# --- 断网统计面板 (新增) ---
watchdog_stats() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN} 断网统计面板 ${NC}"
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

        echo -e "${CYAN}【最近 24 小时统计】${NC}"
        echo "--------------------------------------"
        echo -e "  总断网次数: ${YELLOW}${total}${NC}"
        echo -e "  恢复成功:   ${GREEN}${success}${NC} (${success_rate}%)"
        echo -e "  恢复失败:   ${RED}${fail}${NC}"
        echo -e "  平均耗时:   ${CYAN}${avg_dur}s${NC}"
        echo ""
        echo -e "${CYAN}【断网原因分布】${NC}"
        for reason in "${!reason_count[@]}"; do
            local count=${reason_count[$reason]}
            local pct=$((count * 100 / total))
            printf "  %-25s %2d次 (%d%%)\n" "$reason" "$count" "$pct"
        done
        echo "--------------------------------------"
    fi

    # 最近 10 次记录
    echo -e "${CYAN}【最近 10 次记录】${NC}"
    echo "--------------------------------------"
    tail -n 10 "$STATS_FILE" | while IFS='|' read -r ts result level dur reason; do
        if [ "$result" = "success" ]; then
            echo -e "  ${GREEN}✅${NC} $ts  $level  $dur  $reason"
        else
            echo -e "  ${RED}❌${NC} $ts  $level  $dur  $reason"
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
            [ -n "$sig" ] && echo "  $ts  $sig"
        done
        echo "--------------------------------------"
    fi

    echo -e "${CYAN}======================================${NC}"
    read -n 1 -s -r -p "按任意键返回..."
}

# ========== 主菜单 ==========
while true; do
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN} HiNAS WiFi 控制面板 v${VERSION} ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo " 1. 安装 WIFI 驱动 (RTL8188等)"
    echo " 2. 扫描并连接 WIFI"
    echo -e " 3. 防掉线守护 ${GREEN}(watchdog v3.1 + 保活)${NC}"
    echo -e " 4. 网络信息与体检 ${GREEN}(含信号强度)${NC}"
    echo " 5. 配置静态/动态 IP"
    echo " 6. WiFi 热点 (AP模式)"
    echo " 7. 多网卡优先级"
    echo " 8. 网络测速"
    echo " 9. IPv6 详细面板"
    echo -e "10. ${GREEN}在线更新${NC} (当前 v${VERSION})"
    echo "11. DNS 测速优化"
    echo "12. WiFi 信道分析"
    echo "13. 配置备份/恢复"
    echo -e "14. ${GREEN}断网统计面板${NC} (新增)"
    echo " 0. 退出"
    echo -e "${CYAN}-------------------------------------------------${NC}"
    echo -e " 终端输入 ${GREEN}wifi${NC} 快速打开 | v1.9.3: 去重+修复+保活+信号+统计"
    echo -e "${CYAN}=================================================${NC}"
    read -p "选项 [0-14]: " choice
    case $choice in
        1) install_driver ;;
        2) connect_wifi ;;
        3) toggle_watchdog ;;
        4) show_network_info ;;
        5) config_ip_mode ;;
        6) toggle_hotspot ;;
        7) config_priority ;;
        8) run_speedtest ;;
        9) ipv6_panel ;;
        10) update_script ;;
        11) dns_optimize ;;
        12) channel_analysis ;;
        13) backup_restore ;;
        14) watchdog_stats ;;
        0) clear; echo "已退出。"; exit 0 ;;
        *) echo -e "${RED}无效${NC}"; sleep 1 ;;
    esac
done
