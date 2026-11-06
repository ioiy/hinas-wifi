#!/bin/bash

# ==========================================
# HiNAS WiFi 控制面板 (终极进化版)
# 项目地址: https://github.com/ioiy/hinas-wifi
# ==========================================

VERSION="1.9.0"
UPDATE_URL="https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh"
WATCHDOG_SCRIPT="/usr/local/bin/wifi_watchdog.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")

if [ ! -x "/usr/bin/wifi" ] || [ "$(readlink -f /usr/bin/wifi)" != "$SCRIPT_PATH" ]; then
 ln -sf "$SCRIPT_PATH" /usr/bin/wifi
 chmod +x "$SCRIPT_PATH"
fi

get_wifi_iface() {
 local IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
 [ -z "$IF" ] && IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
 [ -z "$IF" ] && IF="wlan0"
 echo "$IF"
}

get_wifi_conn() {
 local IF=$(get_wifi_iface)
 local CONN=$(nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
 [ -z "$CONN" ] || [ "$CONN" == "--" ] && CONN=""
 echo "$CONN"
}

get_wifi_driver() {
 local DRV=$(lsmod 2>/dev/null | grep -iE "rtl8188|rtl8xxxu|8188" | awk '{print $1}' | head -n 1)
 [ -z "$DRV" ] && DRV="rtl8188fu"
 echo "$DRV"
}

disable_power_save() {
 local IF=$(get_wifi_iface)
 iw dev "$IF" set power_save off 2>/dev/null
 local CONN=$(get_wifi_conn)
 if [ -n "$CONN" ]; then
 nmcli con mod "$CONN" 802-11-wireless.powersave 2 2>/dev/null
 fi
 for dev in /sys/bus/usb/devices/*/power/control; do
 echo on > "$dev" 2>/dev/null
 done
}

disable_power_save

check_network() {
 local IF=$(get_wifi_iface)
 local WIFI_STATE=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${IF}:" | cut -d: -f2)
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

toggle_watchdog() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} WiFi 断网自动重连守护进程 v2.0 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 EXISTING_CRON=$(crontab -l 2>/dev/null | grep "$WATCHDOG_SCRIPT")
 if [ -n "$EXISTING_CRON" ]; then
 CURRENT_INTERVAL=$(echo "$EXISTING_CRON" | awk '{print $1}' | cut -d'/' -f2)
 [ "$CURRENT_INTERVAL" = "*" ] && CURRENT_INTERVAL="1"
 [ -z "$CURRENT_INTERVAL" ] && CURRENT_INTERVAL="未知"
 echo -e "当前状态: ${GREEN}▶ 已开启 (每 $CURRENT_INTERVAL 分钟守护)${NC}"
 else
 echo -e "当前状态: ${RED}⏸ 未开启${NC}"
 fi
 local IF=$(get_wifi_iface)
 local PS_STATE=$(iw dev "$IF" get power_save 2>/dev/null | awk '{print $3}')
 if [ "$PS_STATE" = "on" ]; then
 echo -e "省电模式: ${RED}开启 (可能导致断网！)${NC}"
 else
 echo -e "省电模式: ${GREEN}已关闭${NC}"
 fi
 echo "--------------------------------------"
 echo "1. 开启/修改自动重连 (可自定义检测间隔)"
 echo "2. 关闭自动重连"
 echo "3. 查看自动重连日志"
 echo "4. 一键优化 WiFi 稳定性 (关省电+禁USB挂起)"
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
 cat > $WATCHDOG_SCRIPT << 'WDEOF'
#!/bin/bash
# WiFi Watchdog v2.0
exec 200>/tmp/wifi_watchdog.lock
flock -n 200 || exit 0

WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
[ -z "$WIFI_IFACE" ] && WIFI_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
[ -z "$WIFI_IFACE" ] && WIFI_IFACE="wlan0"
WIFI_CONN=$(nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null | grep "^${WIFI_IFACE}:" | cut -d: -f2)
[ "$WIFI_CONN" = "--" ] && WIFI_CONN=""
WIFI_DRIVER=$(lsmod 2>/dev/null | grep -iE "rtl8188|rtl8xxxu|8188" | awk '{print $1}' | head -n 1)
[ -z "$WIFI_DRIVER" ] && WIFI_DRIVER="rtl8188fu"
LOG_FILE="/var/log/wifi_watchdog.log"
mkdir -p /var/log 2>/dev/null

disable_ps() {
    iw dev "$WIFI_IFACE" set power_save off 2>/dev/null
    if [ -n "$WIFI_CONN" ]; then
        nmcli con mod "$WIFI_CONN" 802-11-wireless.powersave 2 2>/dev/null
    fi
    for dev in /sys/bus/usb/devices/*/power/control; do
        echo on > "$dev" 2>/dev/null
    done
}
disable_ps

check_wifi_associated() {
    local state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${WIFI_IFACE}:" | cut -d: -f2)
    [ "$state" = "connected" ] || [ "$state" = "connecting" ]
}

check_net() {
    if ! check_wifi_associated; then return 1; fi
    ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && return 0
    ping -c 2 -W 3 119.29.29.29 >/dev/null 2>&1 && return 0
    ping6 -c 2 -W 3 2408:8899::8 >/dev/null 2>&1 && return 0
    return 1
}

recover() {
    local level=$1
    case $level in
    1)
        echo "[$(date)] L1: nmcli con up..." >> $LOG_FILE
        [ -n "$WIFI_CONN" ] && nmcli con up "$WIFI_CONN" 2>/dev/null
        sleep 10
        ;;
    2)
        echo "[$(date)] L2: radio off/on + con up..." >> $LOG_FILE
        nmcli radio wifi off 2>/dev/null; sleep 3
        nmcli radio wifi on 2>/dev/null; sleep 5
        [ -n "$WIFI_CONN" ] && nmcli con up "$WIFI_CONN" 2>/dev/null
        sleep 10
        ;;
    3)
        echo "[$(date)] L3: rmmod+modprobe $WIFI_DRIVER..." >> $LOG_FILE
        nmcli radio wifi off 2>/dev/null; sleep 2
        rmmod "$WIFI_DRIVER" 2>/dev/null; sleep 2
        modprobe "$WIFI_DRIVER" 2>/dev/null; sleep 5
        nmcli radio wifi on 2>/dev/null; sleep 5
        [ -n "$WIFI_CONN" ] && nmcli con up "$WIFI_CONN" 2>/dev/null
        sleep 15
        ;;
    4)
        echo "[$(date)] L4: restart NetworkManager..." >> $LOG_FILE
        systemctl restart NetworkManager 2>/dev/null; sleep 20
        [ -n "$WIFI_CONN" ] && nmcli con up "$WIFI_CONN" 2>/dev/null
        sleep 10
        ;;
    esac
    disable_ps
}

if ! check_net; then
    WIFI_STATE=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${WIFI_IFACE}:" | cut -d: -f2)
    echo "[$(date)] 断网检测 (WiFi:$WIFI_STATE)，开始分级恢复..." >> $LOG_FILE
    for level in 1 2 3 4; do
        if check_net; then
            echo "[$(date)] L$level 恢复成功" >> $LOG_FILE
            break
        fi
        recover $level
        if check_net; then
            echo "[$(date)] L$level 恢复成功" >> $LOG_FILE
            break
        fi
    done
    if ! check_net; then
        echo "[$(date)] 所有恢复失败，需手动检查" >> $LOG_FILE
    fi
    tail -n 500 $LOG_FILE > ${LOG_FILE}.tmp 2>/dev/null && mv ${LOG_FILE}.tmp $LOG_FILE
fi
WDEOF
 chmod +x $WATCHDOG_SCRIPT
 (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_JOB") | crontab -
 disable_power_save
 echo -e "${GREEN}✅ 自动重连已开启 (每 $interval 分钟检测)${NC}"
 echo -e "${GREEN}✅ 已关闭省电模式和 USB 挂起${NC}"
 echo -e "${YELLOW}改进: 4级恢复 | 驱动重载 | 省电关闭 | IPv6检测 | 日志持久化${NC}"
 sleep 4
 ;;
 2)
 crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT" | crontab -
 rm -f $WATCHDOG_SCRIPT
 echo -e "${YELLOW}❌ 自动重连已移除。${NC}"
 sleep 2
 ;;
 3)
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 自动重连监控日志 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 if [ -f "/var/log/wifi_watchdog.log" ]; then
 cat /var/log/wifi_watchdog.log
 else
 echo -e "${YELLOW}暂无断网恢复记录。${NC}"
 fi
 [ -f "/tmp/wifi_watchdog.log" ] && echo -e "\n${YELLOW}旧日志:${NC}" && cat /tmp/wifi_watchdog.log
 echo "--------------------------------------"
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 4)
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} WiFi 稳定性优化 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 local IF=$(get_wifi_iface)
 local CONN=$(get_wifi_conn)
 echo -n "1. 关闭省电模式... "
 iw dev "$IF" set power_save off 2>/dev/null
 [ -n "$CONN" ] && nmcli con mod "$CONN" 802-11-wireless.powersave 2 2>/dev/null
 echo -e "${GREEN}✅${NC}"
 echo -n "2. 禁用 USB 自动挂起... "
 for dev in /sys/bus/usb/devices/*/power/control; do echo on > "$dev" 2>/dev/null; done
 echo -e "${GREEN}✅${NC}"
 echo -n "3. 验证省电状态... "
 local PS=$(iw dev "$IF" get power_save 2>/dev/null | awk '{print $3}')
 if [ "$PS" = "off" ]; then
 echo -e "${GREEN}✅ 已关闭${NC}"
 else
 echo -e "${RED}❌ 仍开启${NC}"
 fi
 echo -e "\n${GREEN}优化完成！RTL8188 省电模式是断网主因。${NC}"
 sleep 3
 read -n 1 -s -r -p "按任意键返回..."
 ;;
 0) return ;;
 *) echo -e "${RED}输入无效。${NC}"; sleep 1 ;;
 esac
}

show_network_info() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 查看详细网络信息 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 WIFI_IF=$(get_wifi_iface)
 echo -e "${YELLOW}正在获取...${NC}"
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
 echo "--------------------------------------"
 echo -e "接口:     ${GREEN}$WIFI_IF${NC}"
 echo -e "驱动:     ${GREEN}$WIFI_DRIVER${NC}"
 echo -e "MAC:      ${GREEN}$MAC_ADDR${NC}"
 echo -e "IPv4:     ${GREEN}$LAN_IP${NC}"
 echo -e "IPv6:     ${GREEN}$IPV6_ADDR${NC}"
 echo -e "网关:     ${GREEN}$GATEWAY${NC}"
 echo -e "DNS:      ${GREEN}$DNS${NC}"
 echo -e "公网IP:   ${GREEN}$PUBLIC_IP${NC}"
 if [ "$PS_STATE" = "on" ]; then
 echo -e "省电:     ${RED}开启(建议关闭! 菜单3→4)${NC}"
 else
 echo -e "省电:     ${GREEN}已关闭${NC}"
 fi
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
 read -p "前缀(默认24): " prefix; [ -z "$prefix" ] && prefix=24
 read -p "网关: " gateway; [ -z "$gateway" ] && return
 read -p "DNS(默认223.5.5.5): " dns; [ -z "$dns" ] && dns="223.5.5.5"
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

network_diagnose() {
 clear
 echo -e "${CYAN}======================================${NC}"
 echo -e "${CYAN} 网络体检 ${NC}"
 echo -e "${CYAN}======================================${NC}"
 DEF_IF=$(ip route | grep default | head -1 | awk '{print $5}')
 echo -n "[1] 网卡($DEF_IF): "
 ip link show "$DEF_IF" >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}"
 GATEWAY=$(ip route | awk '/default/ {print $3}' | head -1)
 echo -n "[2] 网关($GATEWAY): "
 ping -c 2 -W 2 "$GATEWAY" >/dev/null 2>&1 && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
 echo -n "[3] DNS(223.5.5.5): "
 ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && echo -e "${GREEN}正常${NC}" || echo -e "${RED}无响应${NC}"
 echo -n "[4] 公网: "
 { ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 2 -W 2 119.29.29.29 >/dev/null 2>&1; } && echo -e "${GREEN}通${NC}" || echo -e "${RED}不通${NC}"
 echo -n "[5] IPv6: "
 ping6 -c 2 -W 2 2408:8899::8 >/dev/null 2>&1 && echo -e "${GREEN}正常${NC}" || echo -e "${RED}不通${NC}"
 local IF=$(get_wifi_iface)
 local PS=$(iw dev "$IF" get power_save 2>/dev/null | awk '{print $3}')
 echo -n "[6] 省电: "
 [ "$PS" = "off" ] && echo -e "${GREEN}已关${NC}" || echo -e "${RED}开启(建议关)${NC}"
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
 read -p "密码(8位+): " pwd; [ ${#pwd} -lt 8 ] && return
 nmcli device wifi hotspot ifname "$WIFI_IF" ssid "$ssid" password "$pwd"
 [ $? -eq 0 ] && echo -e "${GREEN}✅ $ssid${NC}" || echo -e "${RED}❌ 失败${NC}"
 ;;
 2)
 local C=$(nmcli -t -f NAME,TYPE,ACTIVE connection | awk -F: '$3=="yes"&&$2=="802-11-wireless"{print $1}'|head -1)
 [ -n "$C" ] && nmcli con down "$C" >/dev/null 2>&1 && echo -e "${GREEN}✅ 已关${NC}" || echo "无热点"
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
 read -p "密码(无密码回车): " password
 if [ -z "$password" ]; then
 nmcli device wifi connect "$ssid" ifname "$WIFI_IF"
 else
 nmcli device wifi connect "$ssid" password "$password" ifname "$WIFI_IF"
 fi
 if [ $? -eq 0 ]; then
 echo -e "${GREEN}✅ 成功${NC}"; disable_power_save
 else
 echo -e "${RED}❌ 失败${NC}"
 fi
 read -n 1 -s -r -p "按任意键返回..."
}

while true; do
 clear
 echo -e "${CYAN}=================================================${NC}"
 echo -e "${CYAN} HiNAS WiFi 控制面板 v${VERSION} ${NC}"
 echo -e "${CYAN}=================================================${NC}"
 echo " 1. 安装 WIFI 驱动 (RTL8188等)"
 echo " 2. 扫描并连接 WIFI"
 echo " 3. 防掉线自动重连 (watchdog v2.0)"
 echo " 4. 查看网络信息 (含IPv6/省电状态)"
 echo " 5. 配置静态/动态 IP"
 echo " 6. WiFi 热点 (AP模式)"
 echo " 7. 多网卡优先级"
 echo " 8. 网络测速"
 echo " 9. 网络体检 (含IPv6检测)"
 echo -e " 10. ${GREEN}在线更新${NC} (当前 v${VERSION})"
 echo " 0. 退出"
 echo -e "${CYAN}-------------------------------------------------${NC}"
 echo -e " 💡 终端输入 ${GREEN}wifi${NC} 快速打开 | v1.9.0 改进: 省电关闭+4级恢复+驱动重载"
 echo -e "${CYAN}=================================================${NC}"
 read -p "选项 [0-10]: " choice
 case $choice in
 1) install_driver ;;
 2) connect_wifi ;;
 3) toggle_watchdog ;;
 4) show_network_info ;;
 5) config_ip_mode ;;
 6) toggle_hotspot ;;
 7) config_priority ;;
 8) run_speedtest ;;
 9) network_diagnose ;;
 10) update_script ;;
 0) clear; echo "已退出。"; exit 0 ;;
 *) echo -e "${RED}无效${NC}"; sleep 1 ;;
 esac
done
