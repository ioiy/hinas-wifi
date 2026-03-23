# HiNAS WiFi 控制面板 (IOIY 定制增强版)

专为海思机顶盒 (如 Hi3798MV100 / E酷 NAS 等) 打造的终端可视化 WiFi 管理工具。
告别繁琐的 Linux 命令行，一键傻瓜式完成 WiFi 驱动安装、网络连接、防断流守护与进阶网络配置！

## ✨ 核心功能

- 🔌 **智能驱动安装**: 自动检测底层 USB 硬件芯片 (识别 RTL8188ETV/FTV)，一键全自动下载并注入驱动。
- 📡 **可视化扫描与连接**: 全中文界面，自动过滤重复网卡接口，快速扫描附近 WiFi 并输入密码连接。
- 🛡️ **断网自动重连 (守护进程)**: 注入系统底层定时任务，支持自定义检测频率，掉线秒重连，无人值守挂机必备。
- 🌐 **网络详情状态面板**: 一键查看当前网卡的物理 MAC 地址、局域网 IP、默认网关、DNS 以及公网 IP。
- 📌 **静态/动态 IP 切换**: 支持一键将当前 IP 锁定为静态 IP (防路由器重启丢失机器)，或一键恢复 DHCP 动态获取。
- 🚀 **WiFi 热点 (AP 模式)**: 让你的 NAS 摇身一变成为无线路由器，无网环境下也可发射热点供手机直连管理。
- 🔄 **一键热更新**: 脚本内置在线检测与更新功能，发现新版本可一键自动覆盖升级，无需重复输命令下载。
- ⚡ **全局快捷指令**: 运行一次后自动写入系统环境变量，在任意目录下输入 `wifi` 即可秒开控制面板。

## 📥 安装与运行

通过 SSH 登录到你的 NAS (需 `root` 权限)，直接复制并运行以下命令：

```bash
cd /root
wget -O hinaswifi.sh [https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh](https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh)
chmod +x hinaswifi.sh
./hinaswifi.sh
