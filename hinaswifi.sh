#!/bin/bash

# ==========================================
# HiNAS WiFi 控制面板 (定制升级版)
# 项目地址: https://github.com/ioiy/hinas-wifi
# ==========================================

VERSION="1.1.0"
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
# 只要运行过一次本脚本，以后就可以在任意目录直接输入 wifi 命令唤出面板
if [ ! -x "/usr/local/bin/wifi" ] || [ "$(readlink -f /usr/local/bin/wifi)" != "$SCRIPT_PATH" ]; then
    ln -sf "$SCRIPT_PATH" /usr/local/bin/wifi
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
    echo -e "${YELLOW}当前版本: v${VERSION}${NC}"
    echo -e "${YELLOW}正在检测外网连接...${NC}"
    
    if ! check_network; then
        echo -e "${RED}❌ 无网络连接，无法获取更新！请先连接 WiFi 或网线。${NC}"
        sleep 3
        return
    fi

    echo -e "${GREEN}✅ 网络连接正常。正在从 ioiy/hinas-wifi 获取最新版本...${NC}"
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
    
    if [ -f "$WATCHDOG_SCRIPT" ]; then
        echo -e "当前状态: ${GREEN}▶ 已开启 (后台实时守护中)${NC}"
    else
        echo -e "当前状态: ${RED}⏸ 未开启${NC}"
    fi
    echo "--------------------------------------"
    echo "1. 开启自动重连 (可自定义检测时间)"
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

# --- 功能: 安装WiFi驱动 ---
install_driver() {
    echo -e "${YELLOW}准备安装 WiFi 驱动...${NC}"
    # 如果同目录下有 wifi_install.sh 则执行它，否则去远程仓库下载执行
    if [ -f "$(dirname "$SCRIPT_PATH")/wifi_install.sh" ]; then
        bash "$(dirname "$SCRIPT_PATH")/wifi_install.sh"
    else
        echo "未在本地找到 wifi_install.sh，正在从你的 GitHub 下载安装逻辑..."
        wget -qO- "https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/wifi_install.sh" | bash
    fi
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

    echo "正在扫描附近 WiFi (请耐心等待3-5秒)..."
    # 强制刷新扫描缓存
    nmcli device wifi rescan >/dev/null 2>&1
    sleep 2
    
    # 获取列表，替换英文表头为中文，并使用 awk 过滤掉重复行 (解决虚拟网卡导致的重复输出问题)
    nmcli device wifi list | sed 's/IN-USE/状态/g; s/BSSID/MAC地址/g; s/SSID/网络名称/g; s/MODE/模式/g; s/CHAN/信道/g; s/RATE/速率/g; s/SIGNAL/信号/g; s/BARS/强度/g; s/SECURITY/加密方式/g' | awk '!seen[$0]++'
    
    echo "--------------------------------------"
    read -p "请输入要连接的 WiFi 名称 (网络名称): " ssid
    read -p "请输入 WiFi 密码: " password
    
    echo -e "${YELLOW}正在尝试连接到 [$ssid] ...${NC}"
    nmcli device wifi connect "$ssid" password "$password"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 连接成功！当前网络信息：${NC}"
        ip -4 addr show | grep -E 'wl|wlan'
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
    echo "  3. 开启/关闭防掉线自动重连 (无人值守必备)"
    echo -e "  4. ${GREEN}在线更新控制面板${NC} (当前版本 v${VERSION})"
    echo "  0. 退出面板"
    echo -e "${CYAN}=================================================${NC}"
    read -p "请输入选项数字 [0-4]: " choice

    case $choice in
        1) install_driver ;;
        2) connect_wifi ;;
        3) toggle_watchdog ;;
        4) update_script ;;
        0) clear; echo "已退出 WiFi 控制面板。"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新输入 0-4 之间的数字。${NC}"; sleep 1 ;;
    esac
done
