#!/bin/bash

# ==========================================
# HiNAS WiFi 控制面板 (定制升级版)
# 项目地址: https://github.com/ioiy/hinas-wifi
# ==========================================

VERSION="1.6.1"
# 远程脚本地址 (已添加国内加速代理，用于一键更新)
UPDATE_URL="https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh"
# 守护进程脚本路径
WATCHDOG_SCRIPT="/usr/local/bin/wifi_watchdog.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 获取当前脚本的绝对路径（用于自我更新时覆盖原文件）
SCRIPT_PATH=$(readlink -f "$0")

# --- 自动配置全局快捷命令 ---
# 解决 bash 缓存旧路径的问题，直接覆盖回 /usr/bin/wifi
if [ ! -x "/usr/bin/wifi" ] || [ "$(readlink -f /usr/bin/wifi)" != "$SCRIPT_PATH" ]; then
    ln -sf "$SCRIPT_PATH" /usr/bin/wifi
    chmod +x "$SCRIPT_PATH"
fi

# --- 功能: 检查网络 ---
check_network() {
    ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && return 0
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

# --- 功能: 一键检测与更新本脚本 ---
update_script() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}         在线检测与更新控制面板       ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "${YELLOW}正在检测外网连接与云端版本...${NC}"
    
    if ! check_network; then
        echo -e "${RED}❌ 无网络连接，无法获取更新！请先连接 WiFi 或网线。${NC}"
        sleep 3
        return
    fi

    # 抓取云端最新版本号
    CLOUD_VERSION=$(wget -qO- "$UPDATE_URL" | grep -E '^VERSION=' | head -n 1 | cut -d'"' -f2)
    
    if [ -z "$CLOUD_VERSION" ]; then
        echo -e "${RED}❌ 获取云端版本失败，请检查 GitHub 仓库地址或网络。${NC}"
        sleep 3
        return
    fi

    echo -e "当前本地版本: ${CYAN}v${VERSION}${NC}"
    echo -e "发现云端版本: ${GREEN}v${CLOUD_VERSION}${NC}"
    echo "--------------------------------------"
    
    if [ "$VERSION" == "$CLOUD_VERSION" ]; then
        echo -e "${GREEN}✅ 当前已是最新版本，无需更新！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return
    fi

    # 二次确认
    read -p "是否确认更新到 v${CLOUD_VERSION}？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消更新。${NC}"
        sleep 1
        return
    fi

    echo -e "${GREEN}正在从 ioiy/hinas-wifi 下载最新代码...${NC}"
    # 下载到临时文件，防止下载中断导致脚本损坏
    if wget -q -O /tmp/hinaswifi.sh.tmp "$UPDATE_URL"; then
        # 将新代码覆盖当前正在运行的文件
        cat /tmp/hinaswifi.sh.tmp > "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        rm -f /tmp/hinaswifi.sh.tmp
        
        echo -e "${GREEN}🎉 更新成功！正在重新启动面板...${NC}"
        sleep 2
        # 杀死当前进程并用新脚本重新启动面板
        exec bash "$SCRIPT_PATH"
    else
        echo -e "${RED}❌ 下载失败，请稍后再试或检查 GitHub 访问情况。${NC}"
        rm -f /tmp/hinaswifi.sh.tmp
        sleep 3
    fi
}

# --- 功能: 开启/关闭断网自动重连 ---
toggle_watchdog() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}       WiFi 断网自动重连守护进程      ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    # 动态检测当前 cron 任务的状态和设定的时间
    EXISTING_CRON=$(crontab -l 2>/dev/null | grep "$WATCHDOG_SCRIPT")
    if [ -n "$EXISTING_CRON" ]; then
        # 从 cron 表达式中提取分钟间隔 (例如 */3 中的 3)
        CURRENT_INTERVAL=$(echo "$EXISTING_CRON" | awk '{print $1}' | cut -d'/' -f2)
        [ "$CURRENT_INTERVAL" = "*" ] && CURRENT_INTERVAL="1" # 兼容 * * * * * 的情况
        [ -z "$CURRENT_INTERVAL" ] && CURRENT_INTERVAL="未知"
        
        echo -e "当前状态: ${GREEN}▶ 已开启 (后台每 $CURRENT_INTERVAL 分钟守护中)${NC}"
    else
        echo -e "当前状态: ${RED}⏸ 未开启${NC}"
    fi
    echo "--------------------------------------"
    echo "1. 开启/修改自动重连 (可自定义检测时间)"
    echo "2. 关闭自动重连"
    echo "0. 返回主菜单"
    echo -e "${CYAN}======================================${NC}"
    read -p "请输入选项: " wd_choice

    case $wd_choice in
        1)
            read -p "请输入后台检测间隔(分钟，直接回车默认3分钟): " interval
            # 校验输入是否为正整数，否则使用默认值 3
            if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
                interval=3
                echo -e "${YELLOW}输入无效或为空，自动使用默认间隔: 3 分钟${NC}"
            fi
            
            CRON_JOB="*/$interval * * * * $WATCHDOG_SCRIPT"
            
            echo "正在配置后台守护进程..."
            cat > $WATCHDOG_SCRIPT << 'EOF'
#!/bin/bash
WIFI_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
[ -z "$WIFI_IFACE" ] && WIFI_IFACE="wlan0"

check_net() {
    ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && return 0
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

if ! check_net; then
    ip link set $WIFI_IFACE down
    sleep 3
    ip link set $WIFI_IFACE up
    
    # 如果系统使用 NetworkManager 管理网络，则同时触发 nmcli 重置
    if command -v nmcli >/dev/null 2>&1; then
        nmcli radio wifi off
        sleep 2
        nmcli radio wifi on
    fi
fi
EOF
            chmod +x $WATCHDOG_SCRIPT
            
            # 写入 crontab 定时任务，同时剔除旧任务避免重复
            (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_JOB") | crontab -
            echo -e "${GREEN}✅ 自动重连已成功开启！即使面板关闭，后台也会每 $interval 分钟守护一次 WiFi 状态。${NC}"
            sleep 3
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT" | crontab -
            rm -f $WATCHDOG_SCRIPT
            echo -e "${YELLOW}❌ 自动重连守护进程已移除。${NC}"
            sleep 2
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}输入无效。${NC}"
            sleep 1
            ;;
    esac
}

# --- 功能: 查看详细网络信息 ---
show_network_info() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}          查看详细网络信息            ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

    echo -e "${YELLOW}正在获取系统网络信息，请稍候...${NC}"
    
    # 获取 MAC 地址
    MAC_ADDR=$(ip link show "$WIFI_IF" | awk '/ether/ {print $2}')
    [ -z "$MAC_ADDR" ] && MAC_ADDR="未知"
    
    # 获取局域网 IP
    LAN_IP=$(ip -4 addr show dev "$WIFI_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    [ -z "$LAN_IP" ] && LAN_IP="未分配/未连接"
    
    # 获取默认网关
    GATEWAY=$(ip route | awk '/default/ {print $3}' | head -n 1)
    [ -z "$GATEWAY" ] && GATEWAY="未知/未配置"
    
    # 获取 DNS
    DNS=$(grep -m 1 nameserver /etc/resolv.conf | awk '{print $2}')
    [ -z "$DNS" ] && DNS="未知"
    
    # 获取公网 IP (设置 3 秒超时防卡死)
    PUBLIC_IP=$(curl -s --connect-timeout 3 ifconfig.me || echo "获取失败/无外网")

    echo "--------------------------------------"
    echo -e "接口名称: ${GREEN}$WIFI_IF${NC}"
    echo -e "物理 MAC: ${GREEN}$MAC_ADDR${NC}"
    echo -e "局域网IP: ${GREEN}$LAN_IP${NC}"
    echo -e "默认网关: ${GREEN}$GATEWAY${NC}"
    echo -e "当前 DNS: ${GREEN}$DNS${NC}"
    echo -e "公网 IP : ${GREEN}$PUBLIC_IP${NC}"
    echo -e "${CYAN}======================================${NC}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# --- 功能: 配置静态/动态 IP ---
config_ip_mode() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        配置静态 / 动态 IP 地址       ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    if ! command -v nmcli >/dev/null 2>&1; then
        echo -e "${RED}未检测到 nmcli，该功能不可用。${NC}"
        sleep 2; return
    fi

    # 动态获取主要的物理无线网卡接口
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

    # 精准获取当前正在该网卡上活动的连接配置名称 (解决部分系统类型不匹配问题)
    CONN_NAME=$(nmcli -t -f DEVICE,CONNECTION device status | grep "^$WIFI_IF:" | cut -d: -f2)
    
    if [ -z "$CONN_NAME" ] || [ "$CONN_NAME" == "--" ]; then
        echo -e "${RED}❌ 当前未连接任何 WiFi。请先在菜单中连接 WiFi 后再配置 IP。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi
    
    echo -e "当前活动 WiFi: ${GREEN}$CONN_NAME${NC}"
    echo "--------------------------------------"
    echo "1. 配置静态 IP (固定局域网 IP 防变更)"
    echo "2. 恢复动态 IP (恢复 DHCP 自动获取)"
    echo "0. 返回主菜单"
    echo "--------------------------------------"
    read -p "请输入选项: " ip_choice
    
    case $ip_choice in
        1)
            echo -e "${YELLOW}警告: 若设置错误可能导致 NAS 断网失联！${NC}"
            read -p "请输入静态 IP (如 192.168.1.100, 直接回车取消): " static_ip
            [ -z "$static_ip" ] && { echo "已取消设置。"; sleep 1; return; }
            
            read -p "请输入子网掩码前缀 (通常为 24，代表 255.255.255.0，直接回车默认24): " prefix
            [ -z "$prefix" ] && prefix=24
            
            read -p "请输入默认网关 (如路由器 IP 192.168.1.1): " gateway
            [ -z "$gateway" ] && { echo "已取消设置。"; sleep 1; return; }
            
            read -p "请输入 DNS (直接回车默认使用 223.5.5.5): " dns
            [ -z "$dns" ] && dns="223.5.5.5"
            
            echo -e "${YELLOW}正在将 $CONN_NAME 配置为静态 IP...${NC}"
            
            # 写入静态配置
            nmcli con mod "$CONN_NAME" ipv4.addresses "$static_ip/$prefix" ipv4.gateway "$gateway" ipv4.dns "$dns" ipv4.method manual
            
            # 重启连接以生效
            nmcli con down "$CONN_NAME" >/dev/null 2>&1
            nmcli con up "$CONN_NAME" >/dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 静态 IP [$static_ip] 设置成功！网络已重新连接。${NC}"
            else
                echo -e "${RED}❌ 设置失败，请检查网段参数是否与路由器匹配。${NC}"
                # 尝试回滚到 DHCP
                nmcli con mod "$CONN_NAME" ipv4.method auto
                nmcli con up "$CONN_NAME" >/dev/null 2>&1
            fi
            read -n 1 -s -r -p "按任意键返回..."
            ;;
        2)
            echo -e "${YELLOW}正在将 $CONN_NAME 恢复为 DHCP 自动获取 IP...${NC}"
            
            # 清理之前的静态配置信息，并设置为自动获取
            nmcli con mod "$CONN_NAME" ipv4.addresses "" ipv4.gateway "" ipv4.dns "" ipv4.method auto
            
            # 重启连接以生效
            nmcli con down "$CONN_NAME" >/dev/null 2>&1
            nmcli con up "$CONN_NAME" >/dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                # 获取系统重新分配的 IP
                WIFI_IF=$(nmcli -t -f DEVICE,NAME connection show --active | awk -F: '$2=="'"$CONN_NAME"'" {print $1}')
                NEW_IP=$(ip -4 addr show dev "$WIFI_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
                echo -e "${GREEN}✅ 已成功恢复为动态 IP！当前自动获取的新 IP 为: ${NEW_IP}${NC}"
            else
                echo -e "${RED}❌ 恢复 DHCP 失败，请检查网络环境。${NC}"
            fi
            read -n 1 -s -r -p "按任意键返回..."
            ;;
        0) return ;;
        *) echo -e "${RED}输入无效。${NC}"; sleep 1 ;;
    esac
}

# --- 功能: 开启/关闭 WiFi 热点 (AP模式) ---
toggle_hotspot() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}         WiFi 热点 (AP 模式)          ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

    echo "1. 开启 WiFi 热点 (将 NAS 作为路由器)"
    echo "2. 关闭 WiFi 热点 (恢复普通联网模式)"
    echo "0. 返回主菜单"
    echo "--------------------------------------"
    read -p "请输入选项: " hs_choice
    
    case $hs_choice in
        1)
            read -p "请输入想要设置的热点名称 (SSID): " hs_ssid
            [ -z "$hs_ssid" ] && return
            
            read -p "请输入热点密码 (最少 8 位): " hs_pwd
            if [ ${#hs_pwd} -lt 8 ]; then
                echo -e "${RED}密码长度不能小于 8 位！${NC}"
                sleep 2; return
            fi
            
            echo -e "${YELLOW}正在配置并启动热点 (如果已连接WiFi将会断开)...${NC}"
            nmcli device wifi hotspot ifname "$WIFI_IF" ssid "$hs_ssid" password "$hs_pwd"
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ WiFi 热点已成功开启！您的手机现在可以搜索并连接了。${NC}"
                echo -e "热点名称: ${GREEN}$hs_ssid${NC}"
                echo -e "热点密码: ${GREEN}$hs_pwd${NC}"
            else
                echo -e "${RED}❌ 热点开启失败！可能是由于您的无线网卡不支持 AP 模式。${NC}"
            fi
            read -n 1 -s -r -p "按任意键返回..."
            ;;
        2)
            echo -e "${YELLOW}正在尝试关闭热点...${NC}"
            # 查找类型为 wifi 且被标记为 hotspot 的活动连接，并断开它
            HOTSPOT_CONN=$(nmcli -t -f NAME,TYPE,ACTIVE connection | awk -F: '$3=="yes" && $2=="802-11-wireless" {print $1}' | head -n 1)
            if [ -n "$HOTSPOT_CONN" ]; then
                nmcli con down "$HOTSPOT_CONN" >/dev/null 2>&1
                echo -e "${GREEN}✅ 热点已关闭。您可以回到菜单 2 重新连接外部 WiFi。${NC}"
            else
                echo -e "${YELLOW}未检测到正在运行的热点。${NC}"
            fi
            read -n 1 -s -r -p "按任意键返回..."
            ;;
        0) return ;;
        *) echo -e "${RED}输入无效。${NC}"; sleep 1 ;;
    esac
}

# --- 功能: 安装WiFi驱动 ---
install_driver() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}           安装 WiFi 驱动             ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo "请选择要安装的驱动型号 (由本仓库提供):"
    echo "1. RTL8188ETV (多见于水星/迅捷等老款无线网卡)"
    echo "2. RTL8188FTV (多见于杂牌免驱版/微型无线网卡)"
    echo "0. 返回主菜单"
    echo "--------------------------------------"
    read -p "请输入选项: " drv_choice

    DRV_FILE=""
    case $drv_choice in
        1) DRV_FILE="rtl8188etv-0808.tar.gz" ;;
        2) DRV_FILE="rtl8188ftv-0808.tar.gz" ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${NC}"; sleep 1; return ;;
    esac

    echo -e "${YELLOW}正在拉取驱动包和安装脚本...${NC}"
    
    # 创建临时工作目录
    mkdir -p /tmp/wifi_driver && cd /tmp/wifi_driver
    
    # 自动下载仓库中对应的驱动压缩包
    wget -q --show-progress -O "$DRV_FILE" "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/$DRV_FILE"
    
    # 自动下载执行逻辑脚本
    wget -q -O wifi_install.sh "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/wifi_install.sh"

    if [ -f "$DRV_FILE" ] && [ -f "wifi_install.sh" ]; then
        echo -e "${GREEN}下载完成，开始向系统注入驱动...${NC}"
        # 喂入 -f 参数执行真正安装，解决光弹帮助文档的问题
        bash wifi_install.sh -f "$DRV_FILE"
        echo -e "${GREEN}安装流程结束！如果未报错，您可以插入网卡尝试连接了。${NC}"
    else
        echo -e "${RED}❌ 驱动文件下载失败，请检查网络是否畅通。${NC}"
    fi
    
    # 清理现场
    cd /root
    rm -rf /tmp/wifi_driver
    
    echo "按任意键返回..."
    read -n 1
}

# --- 功能: 连接WiFi ---
connect_wifi() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}         扫描并连接无线网络           ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    if ! command -v nmcli >/dev/null 2>&1; then
        echo -e "${RED}未检测到 nmcli 命令。请确保设备已正确安装 NetworkManager。${NC}"
        sleep 3
        return
    fi

    # 动态获取主要的物理无线网卡接口 (排除 p2p-dev 等虚拟接口)
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

    # 获取当前连接状态和IP
    CURRENT_SSID=$(nmcli -t -f ACTIVE,SSID dev wifi | grep '^yes' | cut -d: -f2 | head -n 1)
    if [ -n "$CURRENT_SSID" ]; then
        # 尝试获取该网卡的 IPv4 地址
        CURRENT_IP=$(ip -4 addr show dev "$WIFI_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
        [ -z "$CURRENT_IP" ] && CURRENT_IP="获取中/无"
        echo -e "当前状态: ${GREEN}已连接 [${CURRENT_SSID}]${NC}  IP: ${GREEN}${CURRENT_IP}${NC}"
    else
        echo -e "当前状态: ${RED}未连接${NC}"
    fi
    echo "--------------------------------------"
    
    echo "正在扫描附近 WiFi (请耐心等待3-5秒)..."
    # 指定网卡强制刷新扫描缓存
    nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1
    sleep 2
    
    # 获取列表，替换英文表头为中文，并强制指定 ifname 避免双层重复输出
    nmcli device wifi list ifname "$WIFI_IF" | sed 's/IN-USE/状态/g; s/BSSID/MAC地址/g; s/SSID/网络名称/g; s/MODE/模式/g; s/CHAN/信道/g; s/RATE/速率/g; s/SIGNAL/信号/g; s/BARS/强度/g; s/SECURITY/加密方式/g'
    
    echo "--------------------------------------"
    read -p "请输入要连接的 WiFi 名称 (直接回车返回主菜单): " ssid
    
    # 增加直接回车返回功能判断
    if [ -z "$ssid" ]; then
        return
    fi
    
    read -p "请输入 WiFi 密码 (无密码直接回车): " password
    
    echo -e "${YELLOW}正在尝试连接到 [$ssid] ...${NC}"
    
    if [ -z "$password" ]; then
        nmcli device wifi connect "$ssid" ifname "$WIFI_IF"
    else
        nmcli device wifi connect "$ssid" password "$password" ifname "$WIFI_IF"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 连接成功！当前网络信息：${NC}"
        ip -4 addr show dev "$WIFI_IF" | grep inet
    else
        echo -e "${RED}❌ 连接失败！请检查密码是否正确，或驱动是否正常工作。${NC}"
    fi
    echo "按任意键返回..."
    read -n 1
}

# --- 主菜单循环 ---
while true; do
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}     HiNAS WiFi 控制面板 (IOIY 定制增强版) v${VERSION}  ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo "  1. 一键安装 WIFI 驱动 (RTL8188等)"
    echo "  2. 扫描并连接 WIFI 网络"
    echo "  3. 开启/修改防掉线自动重连 (无人值守必备)"
    echo "  4. 查看详细网络信息 (IP/MAC/网关/公网IP等)"
    echo "  5. 配置静态/动态 IP (固定IP或恢复DHCP)"
    echo "  6. 开启 WiFi 热点 (将 NAS 作为路由器使用)"
    echo -e "  7. ${GREEN}在线更新控制面板${NC} (当前版本 v${VERSION})"
    echo "  0. 退出面板"
    echo -e "${CYAN}-------------------------------------------------${NC}"
    echo -e "  💡 提示: 在终端任意位置输入 ${GREEN}wifi${NC} 即可快速打开本面板"
    echo -e "${CYAN}=================================================${NC}"
    read -p "请输入选项数字 [0-7]: " choice

    case $choice in
        1) install_driver ;;
        2) connect_wifi ;;
        3) toggle_watchdog ;;
        4) show_network_info ;;
        5) config_ip_mode ;;
        6) toggle_hotspot ;;
        7) update_script ;;
        0) clear; echo "已退出 WiFi 控制面板。"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新输入 0-7 之间的数字。${NC}"; sleep 1 ;;
    esac
done
