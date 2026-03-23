#!/bin/bash

# ==========================================
# HiNAS WiFi 控制面板 (终极进化版)
# 项目地址: https://github.com/ioiy/hinas-wifi
# ==========================================

VERSION="1.8.1"
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
        # 从 cron 表达式中提取分钟间隔
        CURRENT_INTERVAL=$(echo "$EXISTING_CRON" | awk '{print $1}' | cut -d'/' -f2)
        [ "$CURRENT_INTERVAL" = "*" ] && CURRENT_INTERVAL="1" 
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
    
    if command -v nmcli >/dev/null 2>&1; then
        nmcli radio wifi off
        sleep 2
        nmcli radio wifi on
    fi
fi
EOF
            chmod +x $WATCHDOG_SCRIPT
            
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
        0) return ;;
        *) echo -e "${RED}输入无效。${NC}"; sleep 1 ;;
    esac
}

# --- 功能: 查看详细网络信息 ---
show_network_info() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}          查看详细网络信息            ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

    echo -e "${YELLOW}正在获取系统网络信息，请稍候...${NC}"
    
    MAC_ADDR=$(ip link show "$WIFI_IF" 2>/dev/null | awk '/ether/ {print $2}')
    [ -z "$MAC_ADDR" ] && MAC_ADDR="未知"
    
    LAN_IP=$(ip -4 addr show dev "$WIFI_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    [ -z "$LAN_IP" ] && LAN_IP="未分配/未连接"
    
    GATEWAY=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
    [ -z "$GATEWAY" ] && GATEWAY="未知/未配置"
    
    DNS=$(grep -m 1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}')
    [ -z "$DNS" ] && DNS="未知"
    
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

    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

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
            [ -z "$static_ip" ] && return
            
            read -p "请输入子网掩码前缀 (通常为 24, 直接回车默认24): " prefix
            [ -z "$prefix" ] && prefix=24
            
            read -p "请输入默认网关 (如路由器 IP 192.168.1.1): " gateway
            [ -z "$gateway" ] && return
            
            read -p "请输入 DNS (直接回车默认使用 223.5.5.5): " dns
            [ -z "$dns" ] && dns="223.5.5.5"
            
            echo -e "${YELLOW}正在将 $CONN_NAME 配置为静态 IP...${NC}"
            nmcli con mod "$CONN_NAME" ipv4.addresses "$static_ip/$prefix" ipv4.gateway "$gateway" ipv4.dns "$dns" ipv4.method manual
            nmcli con down "$CONN_NAME" >/dev/null 2>&1
            nmcli con up "$CONN_NAME" >/dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 静态 IP [$static_ip] 设置成功！网络已重新连接。${NC}"
            else
                echo -e "${RED}❌ 设置失败。正在尝试回滚...${NC}"
                nmcli con mod "$CONN_NAME" ipv4.method auto
                nmcli con up "$CONN_NAME" >/dev/null 2>&1
            fi
            read -n 1 -s -r -p "按任意键返回..."
            ;;
        2)
            echo -e "${YELLOW}正在将 $CONN_NAME 恢复为 DHCP 自动获取 IP...${NC}"
            nmcli con mod "$CONN_NAME" ipv4.addresses "" ipv4.gateway "" ipv4.dns "" ipv4.method auto
            nmcli con down "$CONN_NAME" >/dev/null 2>&1
            nmcli con up "$CONN_NAME" >/dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                WIFI_IF_NEW=$(nmcli -t -f DEVICE,NAME connection show --active | awk -F: '$2=="'"$CONN_NAME"'" {print $1}')
                NEW_IP=$(ip -4 addr show dev "$WIFI_IF_NEW" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
                echo -e "${GREEN}✅ 已成功恢复动态 IP！当前新 IP 为: ${NEW_IP}${NC}"
            else
                echo -e "${RED}❌ 恢复 DHCP 失败，请检查网络环境。${NC}"
            fi
            read -n 1 -s -r -p "按任意键返回..."
            ;;
        0) return ;;
        *) echo -e "${RED}输入无效。${NC}"; sleep 1 ;;
    esac
}

# --- 功能: 多网卡优先级设定 (新增) ---
config_priority() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}      多网卡优先级设定 (网线/WiFi)    ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "当 NAS 同时连接网线和 WiFi 时，可通过修改 Metric 决定流量走哪边。"
    echo -e "💡 ${YELLOW}说明: Metric 值越小，优先级越高。${NC}\n"
    
    if ! command -v nmcli >/dev/null 2>&1; then
        echo -e "${RED}未检测到 nmcli，该功能不可用。${NC}"
        sleep 2; return
    fi

    # 获取当前所有的活动连接
    echo -e "${CYAN}当前活动的网络连接：${NC}"
    nmcli -t -f NAME,DEVICE,TYPE connection show --active | awk -F: '{print "▶ 连接名: \033[0;32m"$1"\033[0m (接口: "$2" | 类型: "$3")"}'
    echo "--------------------------------------"
    
    read -p "请输入要优先使用的网络连接名 (如 Wired connection 1，输入 q 返回): " pri_conn
    [[ "$pri_conn" == "q" || "$pri_conn" == "Q" || -z "$pri_conn" ]] && return
    
    read -p "请输入要作为备用的次要网络连接名 (如不设置可直接回车跳过): " sec_conn
    
    echo -e "${YELLOW}正在配置路由优先级...${NC}"
    
    # 优先连接 Metric 设为 50，备用设为 100
    nmcli con mod "$pri_conn" ipv4.route-metric 50
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}优先通道 [$pri_conn] 配置完成。${NC}"
    else
        echo -e "${RED}设置失败，请检查名称是否输入正确。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi
    
    if [ -n "$sec_conn" ]; then
        nmcli con mod "$sec_conn" ipv4.route-metric 100
        echo -e "${GREEN}备用通道 [$sec_conn] 配置完成。${NC}"
    fi
    
    # 重启连接以生效
    echo -e "${YELLOW}正在重启网络接口使优先级生效...${NC}"
    nmcli con up "$pri_conn" >/dev/null 2>&1
    [ -n "$sec_conn" ] && nmcli con up "$sec_conn" >/dev/null 2>&1
    
    echo -e "${GREEN}✅ 多网卡优先级配置成功！${NC}"
    echo "当前的默认路由规则如下 (留意 default 行末尾的 metric 值):"
    ip route | grep default
    
    read -n 1 -s -r -p "按任意键返回..."
}

# --- 功能: 终端全链路测速 (新增) ---
run_speedtest() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        终端全链路网络测速            ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "正在检测系统测速环境，请稍候..."
    
    if command -v python3 >/dev/null 2>&1; then
        echo -e "${GREEN}检测到 Python3 环境，正在拉取 Speedtest-cli 工具测速...${NC}"
        echo -e "${YELLOW}(测速过程约需 30秒-1分钟，请耐心等待测速节点匹配)${NC}"
        echo "--------------------------------------"
        wget -qO- https://ghfast.top/https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -u - | sed -u \
            -e 's/Retrieving speedtest.net configuration.../正在获取测速配置.../' \
            -e 's/Testing from/当前客户端:/' \
            -e 's/Retrieving speedtest.net server list.../正在获取服务器列表.../' \
            -e 's/Selecting best server based on ping.../正在评估寻找最佳测速节点.../' \
            -e 's/Hosted by/目标节点:/' \
            -e 's/Testing download speed/正在测试下载速度/' \
            -e 's/Download:/下载速度:/' \
            -e 's/Testing upload speed/正在测试上传速度/' \
            -e 's/Upload:/上传速度:/'
    elif command -v python >/dev/null 2>&1; then
        echo -e "${GREEN}检测到 Python 环境，正在拉取 Speedtest-cli 工具测速...${NC}"
        echo -e "${YELLOW}(测速过程约需 30秒-1分钟，请耐心等待测速节点匹配)${NC}"
        echo "--------------------------------------"
        wget -qO- https://ghfast.top/https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python -u - | sed -u \
            -e 's/Retrieving speedtest.net configuration.../正在获取测速配置.../' \
            -e 's/Testing from/当前客户端:/' \
            -e 's/Retrieving speedtest.net server list.../正在获取服务器列表.../' \
            -e 's/Selecting best server based on ping.../正在评估寻找最佳测速节点.../' \
            -e 's/Hosted by/目标节点:/' \
            -e 's/Testing download speed/正在测试下载速度/' \
            -e 's/Download:/下载速度:/' \
            -e 's/Testing upload speed/正在测试上传速度/' \
            -e 's/Upload:/上传速度:/'
    else
        echo -e "${RED}未检测到 Python 环境，已降级为基础模式测速。${NC}"
        echo -e "将使用 wget 工具从全球可用节点盲测下载速度...\n"
        echo -e "${CYAN}▶ 正在进行下载测速 (按 Ctrl+C 可提前中断)...${NC}"
        wget -O /dev/null http://speedtest.tele2.net/10MB.zip --show-progress
        echo -e "\n${GREEN}✅ 基础测速完成。${NC}"
    fi
    
    echo "--------------------------------------"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# --- 功能: 网络全身体检大夫 (新增) ---
network_diagnose() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}         网络全身体检大夫             ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "${YELLOW}正在逐步排查网络连通性，请耐心等待...${NC}"
    echo "--------------------------------------"
    
    # 1. 检查物理网卡状态
    DEF_IF=$(ip route | grep default | head -n 1 | awk '{print $5}')
    [ -z "$DEF_IF" ] && DEF_IF="未知网卡"
    echo -n "[节点 1] 本地活动网卡 ($DEF_IF) 状态: "
    if ip link show "$DEF_IF" >/dev/null 2>&1; then
        echo -e "${GREEN}工作正常 (UP)${NC}"
    else
        echo -e "${RED}异常 (DOWN 或不存在)，请检查网线或驱动。${NC}"
    fi
    sleep 1
    
    # 2. 检查网关连通性
    GATEWAY=$(ip route | awk '/default/ {print $3}' | head -n 1)
    echo -n "[节点 2] 局域网网关 ($GATEWAY) 连通性: "
    if [ -n "$GATEWAY" ] && ping -c 2 -W 2 "$GATEWAY" >/dev/null 2>&1; then
        echo -e "${GREEN}畅通 (本机可连通路由器)${NC}"
    else
        echo -e "${RED}不通！可能 IP 冲突、密码错误或路由器已关机。${NC}"
    fi
    sleep 1
    
    # 3. 检查 DNS 解析
    DNS=$(grep -m 1 nameserver /etc/resolv.conf | awk '{print $2}')
    echo -n "[节点 3] DNS 解析服务器 ($DNS) 状态: "
    if [ -n "$DNS" ] && ping -c 2 -W 2 "$DNS" >/dev/null 2>&1; then
        echo -e "${GREEN}正常响应${NC}"
    else
        echo -e "${RED}无响应！可能导致无法打开网页，建议配置静态 DNS。${NC}"
    fi
    sleep 1
    
    # 4. 检查外网连通性
    echo -n "[节点 4] 互联网公网节点连通性: "
    if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 2 -W 2 114.114.114.114 >/dev/null 2>&1; then
        echo -e "${GREEN}完美连通 (你的 NAS 已成功接入广域网)${NC}"
    else
        echo -e "${RED}失败！可能路由器欠费断网，或 NAS 受到网络限制。${NC}"
    fi
    
    echo "--------------------------------------"
    echo -e "${CYAN}体检完毕！如果某一项显示红字，请着重排查对应设备。${NC}"
    read -n 1 -s -r -p "按任意键返回..."
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

# --- 功能: 安装WiFi驱动 (带智能硬件探测) ---
install_driver() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}           安装 WiFi 驱动             ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    echo -e "${YELLOW}正在检测系统硬件与驱动状态...${NC}"
    sleep 1

    WIFI_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n 1)
    if [ -n "$WIFI_IF" ]; then
        echo -e "${GREEN}✅ 检测到系统已有可工作的无线网卡接口 ($WIFI_IF)！${NC}"
        echo -e "${GREEN}这通常意味着您的驱动已经安装完毕且正常运行。${NC}"
        read -p "是否仍然强制重新安装驱动？(y/n): " force_install
        if [[ "$force_install" != "y" && "$force_install" != "Y" ]]; then
            echo "已取消安装。"
            sleep 1
            return
        fi
    fi

    USB_ID="unknown"
    if command -v lsusb >/dev/null 2>&1; then
        USB_ID=$(lsusb | grep -i -E "0bda:8179|0bda:f179" | awk '{print $6}' | head -n 1)
    fi

    DRV_FILE=""
    if [ "$USB_ID" == "0bda:8179" ]; then
        echo -e "${GREEN}🔍 自动检测到网卡芯片: RTL8188ETV/EUS (硬件ID: 0bda:8179)${NC}"
        DRV_FILE="rtl8188etv-0808.tar.gz"
    elif [ "$USB_ID" == "0bda:f179" ]; then
        echo -e "${GREEN}🔍 自动检测到网卡芯片: RTL8188FTV/FUS (硬件ID: 0bda:f179)${NC}"
        DRV_FILE="rtl8188ftv-0808.tar.gz"
    else
        echo -e "${RED}❌ 未能自动识别到受支持的 RTL8188 系列网卡。${NC}"
        echo -e "请确认网卡已插紧，或您的网卡芯片不属于 8188ETV/FTV。\n"
        echo "您仍可以强制手动选择要尝试安装的驱动型号:"
        echo "1. RTL8188ETV (多见于水星/迅捷等老款无线网卡)"
        echo "2. RTL8188FTV (多见于杂牌免驱版/微型无线网卡)"
        echo "0. 返回主菜单"
        echo "--------------------------------------"
        read -p "请输入选项: " drv_choice

        case $drv_choice in
            1) DRV_FILE="rtl8188etv-0808.tar.gz" ;;
            2) DRV_FILE="rtl8188ftv-0808.tar.gz" ;;
            0) return ;;
            *) echo -e "${RED}无效选项。${NC}"; sleep 1; return ;;
        esac
    fi

    echo -e "${YELLOW}正在拉取驱动包 [$DRV_FILE] 和安装脚本...${NC}"
    mkdir -p /tmp/wifi_driver && cd /tmp/wifi_driver
    wget -q --show-progress -O "$DRV_FILE" "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/$DRV_FILE"
    wget -q -O wifi_install.sh "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/wifi_install.sh"

    if [ -f "$DRV_FILE" ] && [ -f "wifi_install.sh" ]; then
        echo -e "${GREEN}下载完成，开始向系统注入驱动...${NC}"
        bash wifi_install.sh -f "$DRV_FILE"
        echo -e "${GREEN}安装流程结束！如果未报错，您可以拔插一次网卡尝试连接了。${NC}"
    else
        echo -e "${RED}❌ 驱动文件下载失败，请检查网络是否畅通。${NC}"
    fi
    
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

    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1}' | grep -v 'p2p' | head -n 1)
    [ -z "$WIFI_IF" ] && WIFI_IF="wlan0"

    CURRENT_SSID=$(nmcli -t -f ACTIVE,SSID dev wifi | grep '^yes' | cut -d: -f2 | head -n 1)
    if [ -n "$CURRENT_SSID" ]; then
        CURRENT_IP=$(ip -4 addr show dev "$WIFI_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
        [ -z "$CURRENT_IP" ] && CURRENT_IP="获取中/无"
        echo -e "当前状态: ${GREEN}已连接 [${CURRENT_SSID}]${NC}  IP: ${GREEN}${CURRENT_IP}${NC}"
    else
        echo -e "当前状态: ${RED}未连接${NC}"
    fi
    echo "--------------------------------------"
    
    echo "正在扫描附近 WiFi (请耐心等待3-5秒)..."
    nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1
    sleep 2
    
    nmcli device wifi list ifname "$WIFI_IF" | sed 's/IN-USE/状态/g; s/BSSID/MAC地址/g; s/SSID/网络名称/g; s/MODE/模式/g; s/CHAN/信道/g; s/RATE/速率/g; s/SIGNAL/信号/g; s/BARS/强度/g; s/SECURITY/加密方式/g'
    
    echo "--------------------------------------"
    read -p "请输入要连接的 WiFi 名称 (直接回车返回主菜单): " ssid
    
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
    echo "  7. 多网卡优先级设定 (网线/WiFi 冲突管理)"
    echo "  8. 终端全链路网络测速 (宽带速度测试)"
    echo "  9. 网络全身体检大夫 (一键诊断断网原因)"
    echo -e " 10. ${GREEN}在线更新控制面板${NC} (当前版本 v${VERSION})"
    echo "  0. 退出面板"
    echo -e "${CYAN}-------------------------------------------------${NC}"
    echo -e "  💡 提示: 在终端任意位置输入 ${GREEN}wifi${NC} 即可快速打开本面板"
    echo -e "${CYAN}=================================================${NC}"
    read -p "请输入选项数字 [0-10]: " choice

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
        0) clear; echo "已退出 WiFi 控制面板。"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新输入 0-10 之间的数字。${NC}"; sleep 1 ;;
    esac
done
