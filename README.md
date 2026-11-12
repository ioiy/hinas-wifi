# HiNAS WiFi 控制面板 (IOIY 定制增强版)

专为海思机顶盒 (如 Hi3798MV100 / E酷 NAS 等) 打造的终端可视化 WiFi 管理工具。
告别繁琐的 Linux 命令行，一键傻瓜式完成 WiFi 驱动安装、网络连接、防断流守护与进阶网络配置！

## ✨ 核心功能

- 🔌 **智能驱动安装**: 自动检测底层 USB 硬件芯片 (识别 RTL8188ETV/FTV)，一键全自动下载并注入驱动。
- 📡 **可视化扫描与连接**: 全中文界面，自动过滤重复网卡接口，快速扫描附近 WiFi 并输入密码连接。
- 🛡️ **防掉线守护 (watchdog v3.5)**: ping-only 监控模式 — 正常时只 ping 不碰驱动，断线才介入恢复。四级恢复策略 (nmcli → radio 重启 → ip link → 重启网卡)，无人值守挂机必备。
- 📊 **断网统计面板**: 记录每次断网的时间、原因 (deauth/dhcp_fail/unknown)、恢复耗时、恢复方式，支持今日 vs 昨日对比。
- 🌐 **网络详情状态面板**: 一键查看当前网卡的物理 MAC 地址、局域网 IP、默认网关、DNS 以及公网 IP。
- 📌 **静态/动态 IP 切换**: 支持一键将当前 IP 锁定为静态 IP (防路由器重启丢失机器)，或一键恢复 DHCP 动态获取。
- 🚀 **WiFi 热点 (AP 模式)**: 让你的 NAS 摇身一变成为无线路由器，无网环境下也可发射热点供手机直连管理。
- 🔋 **省电模式开关**: RTL8188FU 省电模式控制。实测开启省电更稳定 (关省电可能过热/USB 供电不足)。
- 🌐 **IPv6 模式开关**: 三种模式可选 — `ignore` (推荐, NM 不管 IPv6, 内核自处理 RA)、`auto`、`disabled`。解决路由器 IPv6 不稳定拖垮 DHCPv4 的问题。
- 🔒 **BSSID 锁定/解除**: 双 AP 同名 SSID 环境下，锁定到信号最强的 AP，防止 RTL8188FU 驱动漫游导致双 AP 互踢 deauth。自动扫描同名 AP，按信号排序，输入序号即可锁定。
- 🔄 **一键热更新**: 脚本内置在线检测与更新功能，发现新版本可一键自动覆盖升级，无需重复输命令下载。
- ⚡ **全局快捷指令**: 运行一次后自动写入系统环境变量，在任意目录下输入 `wifi` 即可秒开控制面板。

## 📋 菜单一览

```
 1. 安装 WIFI 驱动 (RTL8188等)
 2. 扫描并连接 WIFI
 3. 防掉线守护 (watchdog v3.5 ping-only)
 4. 网络信息与体检 (含信号强度)
 5. 配置静态/动态 IP
 6. WiFi 热点 (AP模式)
 7. 多网卡优先级
 8. 网络测速
 9. IPv6 详细面板
10. 在线更新
11. DNS 测速优化
12. WiFi 信道分析
13. 配置备份/恢复
14. 断网统计面板
15. 省电模式开关
16. IPv6 模式开关
17. BSSID 锁定/解除
 0. 退出
```

## 📥 安装与运行

通过 SSH 登录到你的 NAS (需 `root` 权限)，直接复制并运行以下命令：

```bash
cd /root
wget -O hinaswifi.sh https://ghfast.top/https://raw.githubusercontent.com/ioiy/hinas-wifi/main/hinaswifi.sh
chmod +x hinaswifi.sh
./hinaswifi.sh
```

运行一次后，后续在任意目录输入 `wifi` 即可打开控制面板。

## 🔧 版本历史

| 版本 | 核心改动 |
|------|---------|
| v1.8.3 | 早期版本，简单 ping-only watchdog |
| v1.9.7 | **watchdog v3.5 ping-only** — 正常时只 ping 不碰驱动，解决频繁断线 |
| v2.0.0 | 省电模式保持开启 (实测稳定)，修正提示文字 |
| v2.1.0 | **IPv6 模式开关** — `ipv6.method=ignore` 避免路由器 IPv6 不稳定拖垮 DHCPv4 |
| v2.2.0 | **BSSID 锁定/解除** — 双 AP 同名 SSID 环境防漫游互踢 |

## 🐛 已解决的问题

1. **watchdog 过度干预驱动** → v1.9.7 ping-only，正常时不碰驱动
2. **IPv6 拖垮 DHCPv4** → v2.1.0 `ipv6.method=ignore`，dhcp_fail 消失
3. **双 AP 同名 SSID 漫游冲突** → v2.2.0 BSSID 锁定，deauth 消失

> 详细排查过程见 [hinas-wifi-排查记录.md](https://github.com/ioiy/hinas-wifi/blob/main/hinas-wifi-排查记录.md)

## 📝 适用环境

- 设备: Hi3798MV100 / E酷 NAS 等海思机顶盒
- 系统: Ubuntu 20.04 (armv7l, 32-bit)
- WiFi 芯片: RTL8188FU (USB) / RTL8188ETV
- 依赖: NetworkManager, nmcli, iw
