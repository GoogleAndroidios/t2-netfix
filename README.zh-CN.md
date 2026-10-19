# t2-netfix

[![shellcheck](https://github.com/GoogleAndroidios/t2-netfix/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/GoogleAndroidios/t2-netfix/actions/workflows/shellcheck.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) | **简体中文**

T2 芯片的 Intel Mac 上，睡眠唤醒、重新登录之后 Wi-Fi 和蓝牙经常掉驱动。这个工具会自动检测并修好它，全程不需要去碰你的 macOS 分区、不需要重新提取固件。

```
$ sudo t2-netfix --status
time: 2026-10-19 18:53:59
wifi: ok (wlp115s0f0)
bluetooth: ok (hci0)
action: recovered after 1 round(s), connected: Magic Keyboard, MX Master
--- current state ---
wifi: ok (wlp115s0f0)
bluetooth: ok (hci0)
devices: connected: Magic Keyboard, MX Master
```

---

## 问题在哪

T2 Mac 上 Wi-Fi 和蓝牙是**同一颗 Broadcom 组合芯片**（BCM4377，分别由 `brcmfmac` 和 `hci_bcm4377` 驱动）。睡眠一轮或者重新登录之后，芯片被复位了，但驱动经常没能正确重新绑定，于是出现下面这些状态：

| 你看到的现象 | 实际坏在哪 |
| --- | --- |
| 完全没有 `wl*` 网卡 | 唤醒后驱动没绑上 |
| 有 `wl*`，网络管理器里空的，一个热点都搜不到 | 无线固件半死 |
| `hci0` 在，但是 `DOWN`，提示 "No default controller available" | 控制器没重新初始化 |
| `hci0` 能上电，但每次扫描都超时，`bluetoothctl show` 显示 `Powered: no` | HCI 层卡死（`tx timeout`、`probe -110`） |
| 控制器正常，但键鼠死活连不回来 | bluez 残留了发现/连接状态 |

这些情况重载驱动基本都能救回来；芯片真的卡死时，把它的 PCI 功能复位一次也能救。固件本来就在 `/lib/firmware/brcm` 里，**不需要**再去碰 macOS。

## 为什么不直接用 `get-apple-firmware get_from_macos`

因为那条命令末尾是这几行：

```sh
modprobe -r brcmfmac_wcc; modprobe -r brcmfmac; modprobe brcmfmac
modprobe -r hci_bcm4377;  modprobe hci_bcm4377
```

真正让网络恢复的是**重载**这一步。提取固件是副作用：多花 30 多秒，会去挂载你的 APFS 分区，而加密卷上读出来的数据并不可靠（内核原话是 `volume is encrypted, may not be read correctly`）。更糟的是，如果 `hci_bcm4377` 正在初始化时被卸载，蓝牙功能可能整场会话都绑不回来。

`t2-netfix` 只做重载，跳过提取；只有在重载确实救不了的时候，才升级到 PCI 复位。

## 环境要求

- **Intel T2 的 Mac**（MacBookPro 2018–2020、MacBookAir 2018–2020、Mac mini 2018、iMac 2019–2020、Mac Pro 2019）。Apple Silicon 是另一套平台，不需要这个工具。
- 用 **systemd** + **BlueZ** 的发行版（Ubuntu、Fedora、Arch、Debian 等）。
- 驱动本身是能工作的：Wi-Fi 用 `brcmfmac`，蓝牙用 `hci_bcm4377`（一般通过 [t2linux] 的内核包获得）。
- `bash`、`modprobe`、`bluetoothctl` 必须有；`nmcli`、`iw`、`hciconfig`、`notify-send` 都是可选的，运行时自动探测。

[t2linux]: https://wiki.t2linux.org/

## 安装

```sh
git clone https://github.com/GoogleAndroidios/t2-netfix.git
cd t2-netfix
sudo ./install.sh
```

装完验证一下：

```sh
sudo t2-netfix --check        # 应该输出 ok / ok
sudo systemctl suspend        # 唤醒后修复会自己跑
t2-netfix --status            # 看上一次自动执行做了什么
```

除了下面列出的路径，什么都不改。`sudo ./install.sh --uninstall` 会把装的全删掉。

## 用法

```
sudo t2-netfix              诊断，有问题才修
sudo t2-netfix --login      同上，但先等网卡出现
sudo t2-netfix --notify     带桌面通知，实时显示进度
sudo t2-netfix --status     上一次运行结果 + 当前状态
sudo t2-netfix --check      只诊断，不改任何东西
sudo t2-netfix --connect    只重连已配对的键鼠
sudo t2-netfix --force      强制走完整修复流程
sudo t2-netfix --quiet      不输出（开机服务用）
```

退出码：`0` 正常或已修好，`1` 仍然坏着，`2` 参数用错。

## 怎么判断"好没好"

所有判断都是**功能性**的。"设备节点还在"从来不算证据——那恰好就是芯片卡死后留下的状态。

| 检查项 | `ok` | 降级 | 缺失 |
| --- | --- | --- | --- |
| Wi-Fi | 至少能扫到 1 个热点 | 接口在但 0 个热点（`half`） | 没有无线网卡 |
| 蓝牙 | 扫描能启动也能停止 | 能上电但扫描失败（`broken`） | 没有控制器节点 |

修复从轻到重，**每轮结束都重新实测**，所以芯片本来就正常时代价只有一轮空跑：

```
软复位    接口 down/up、重启 bluetoothd、重新扫描
   ↓ 还是不行
重载模块  brcmfmac / hci_bcm4377 的 modprobe -r + modprobe
   ↓ 还是不行
PCI 复位  unbind，往 .../reset 写 1，modprobe，再 bind
```

控制器节点直接消失时会跳过重载这一级：设备 probe 都失败了（`-110`），再卸一次驱动只会更糟。

## 装了什么

| 路径 | 作用 |
| --- | --- |
| `/usr/local/sbin/t2-netfix` | 主程序 |
| `/usr/lib/systemd/system-sleep/t2-netfix` | 睡眠前后跑 `pre`（关蓝牙射频）和 `post`（修复） |
| `/etc/systemd/system/t2-netfix-resume.service` | 唤醒后执行，hook 的兜底 |
| `/etc/systemd/system/t2-netfix.service` | 开机执行一次 |
| `/etc/sudoers.d/t2-netfix` | 免密码 sudo，**只**对这一支脚本生效 |
| `~/.config/autostart/t2-netfix.desktop` | 桌面登录时执行 |
| `/etc/t2-netfix.conf` | 可选配置，参考示例文件 |

sleep hook 故意装在 `/usr/lib/systemd/system-sleep`：systemd 258 之后**静默忽略** `/etc/systemd/system-sleep` 里的 hook，这正是"我的 hook 从来不跑"最常见的原因。

## 配置

`/etc/t2-netfix.conf` 会被主程序和 sleep hook 读取，每个键也都可以用环境变量传。

| 键 | 默认值 | 含义 |
| --- | --- | --- |
| `T2_MAX_ROUNDS` | `3` | 走 PCI 复位兜底前最多重载几轮 |
| `T2_RECONNECT_MAX` | `60` | 重连键鼠最多花几秒 |
| `T2_RECONNECT_ICONS` | `input-*` | 哪些 `bluetoothctl` 图标的设备会被重连 |
| `T2_SCAN_CACHE_TTL` | `20` | 热点数量缓存有效期（秒） |
| `T2_PCI_VENDOR` | `0x14e4` | 组合芯片的 PCI 厂商号 |
| `T2_BT_PCI_IDS` | `0x5fa0\|0x5f69\|0x5f71\|0x5f72` | 蓝牙功能的设备号，只在驱动没绑定时用 |
| `T2_PRE_POWEROFF_BT` | `1` | 挂起前是否关闭蓝牙射频 |

`T2_PRE_POWEROFF_BT` 值得单独说：睡前把射频关掉可以从根上避开固件卡死，代价是**没法用蓝牙设备唤醒**。下一节详细讲。

## 唤醒：到底什么能叫醒机器

**蓝牙键鼠唤醒不了挂起的 T2 Mac。** `deep`（S3）睡眠下射频是断电的，没有东西在监听。

按方便程度排的几个办法：

1. **干脆不挂起。** 接外接显示器的话，把 `lid-close-ac-action` 设成 `nothing`（GNOME：设置 → 电源 → 关掉自动挂起，再执行 `gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing'`）。然后让它超时熄屏就行——敲一下蓝牙键盘，外接屏直接亮，没有唤醒延迟。
2. 用**盖子**、**电源键**，或者**重新插拔 USB-C 显示器线**唤醒（USB-C 控制器支持唤醒）。
3. 允许**充电器**唤醒：`echo ADP1 | sudo tee /proc/acpi/wakeup`（不持久，而且 ACPI 名字各机型不同）。

## 测试环境

到目前只在**一台实机**上跑过。下面是这套环境完整的清单，不是"理论上应该能跑"的推测。

| 项目 | 值 |
| --- | --- |
| 机型 | `MacBookAir9,1`（MacBook Air 2020, Intel） |
| CPU | Intel Core i3-1000NG4（4 线程） |
| 主板 | `Mac-0CFF9C7C2B63DF8D` |
| iBridge 固件 | `24.16.6005.0.0` |
| 发行版 | Ubuntu 26.04.1 LTS |
| 内核 | `7.2.11-3-t2-resolute`（[t2linux]） |
| 会话 | GNOME Shell 50.1，Wayland |
| systemd | 259（`259.5-0ubuntu3.4`） |
| BlueZ | 5.85（`5.85-4ubuntu0.4`） |
| NetworkManager | 1.54.3 |
| wpa_supplicant | 2.11 |
| Wi-Fi 功能 | `73:00.0` — BCM4377b，`14e4:4488`（rev 04） |
| 蓝牙功能 | `73:00.1` — BRCM4377，`14e4:5fa0`（rev 04） |
| 驱动 | `brcmfmac`、`brcmfmac_wcc`、`hci_bcm4377` |
| 固件 | `brcmfmac4377b3-pcie.apple,formosa.bin`、`brcmbt4377b3-apple,formosa.bin` |
| 睡眠模式 | `deep`（S3）；`s2idle` 可用但不是默认 |

### 实际验证过的场景

- **睡眠 → 唤醒**（`deep`）整个循环后 Wi-Fi 和蓝牙都能恢复，hook 在你能用桌面之前就修完了。
- **桌面登录**和**开机**两个触发点，包括多个触发点同时命中时 `flock` 的串行化。
- **Wi-Fi 半死**：接口在、`iw` 有响应、但一个热点都扫不到 —— 判成 `half` 并修好。这就是当初只看节点存在与否时被漏掉的那种状态。
- **蓝牙半死**：`hci0` 在、`Powered: yes`，但 `scan off` 报错、每次扫描都超时 —— 判成 `broken` 并修好。
- **`probe -110` 卡死**：最糟的状态，`hci_bcm4377` 直接 probe 失败、控制器节点整个消失。用 PCI 功能复位救回过多次，这也是修复阶梯存在的原因。
- 驱动重载后**自动重连蓝牙键盘和鼠标**，包括清掉 bluez 残留的 `Discovering` 标志。
- root 服务向已登录用户的会话总线**发通知**（`runuser` + `DBUS_SESSION_BUS_ADDRESS`），并实时刷新进度。
- `--check`、`--status`、`--connect`、`--force`、`--quiet`、`--login` 的退出码。

### 其他机型

非常欢迎反馈。在别的 T2 机型上跑过的话，开个 issue 带上这些：

```sh
uname -a
cat /sys/class/dmi/id/product_name
lspci -nn | grep -i 14e4
journalctl -t t2-netfix -n 50
```

## 局限性

装之前先看这一节。下面都是实际测出来的约束，不是免责声明。

**平台相关**

- **只支持 Intel T2。** Apple Silicon（M1 及之后）没有 T2，也没有这种 `brcmfmac`/`hci_bcm4377` 组合，这工具对它没用。
- **只针对 Broadcom 组合芯片。** 目标是 BCM4377/4378（`14e4:4488`、`14e4:5fa0`）。用 Intel、Qualcomm、MediaTek 无线网卡的机器不在支持范围。
- **驱动必须本来就是好的。** 如果 `brcmfmac` 或 `hci_bcm4377` 根本没装，或者 `/lib/firmware/brcm` 里缺对应的 `.bin`，怎么重载都没用 —— 得先装 [t2linux] 的内核和固件包。本仓库不下载、也不再分发任何固件。
- **只在一台机器上验证过。** MacBookPro 2018–2020、Mac mini 2018、iMac 2019–2020、Mac Pro 2019 用的是同一颗芯片和同一套驱动，**理论上**适用，但都没实测。第一次在别的机型上装，请当成实验性操作，留一个终端在旁边。
- **只支持 systemd。** 触发点是 `systemd-sleep` hook 加两个 unit。OpenRC、runit 之类的 init 系统不支持。

**睡眠与唤醒**

- **蓝牙键鼠叫不醒挂起的 T2 Mac。** `deep`（S3）下射频断电，这是硬件属性，工具修不了，详见[唤醒](#唤醒到底什么能叫醒机器)。
- **默认配置会在睡前关掉蓝牙**（`T2_PRE_POWEROFF_BT=1`）。这是有意的：从根上避开唤醒后的固件卡死，代价是彻底断了蓝牙唤醒的可能。设成 `0` 能保住唤醒，但 `-110` 卡死的概率明显上升。
- **`s2idle` 没测过。** 参考机用的是 `deep`。如果你强制 `s2idle`（改 `/sys/power/mem_sleep`），芯片不会按同样的方式复位，修复阶梯的表现可能不一样。
- **不支持也不测试休眠到磁盘（`disk`）。** hook 只处理 `pre`/`post` suspend。
- **冷启动时就没枚举到芯片的情况救不了。** 如果 PCI 设备在固件层就缺失，脚本只会记一条日志然后退出，只能重启。

**运行行为**

- **`--force` 会断网几秒。** 重载驱动意味着接口消失，走 Wi-Fi 的 SSH 会话会掉。
- **必须 root**，而且 `install.sh` 会给**一个文件**开免密 sudo（`/etc/sudoers.d/t2-netfix` → `/usr/local/sbin/t2-netfix`）。反过来说，谁能改这支脚本，谁就能以 root 身份执行任意代码。装之前自己过一眼；不想要自动触发的话，把 sudoers 文件删掉即可。
- **只重连输入设备。** `bluetoothctl` 里 `Icon` 是 `input-*` 的设备（键盘、鼠标、手柄）才会被重连；耳机、音箱、手机一律不动，免得抢走你没打算连的链路。
- **重连是尽力而为，上限 60 秒。** 重载之后 bluez 大概要 10–20 秒才肯接受新连接；如果设备关机了、不在范围内、或者还挂着旧的链路状态，就连不上，工具会继续往下走而不是卡住登录。
- **登录后的头几秒是竞态。** `--login` 会等网卡出现（最多 20 秒）再加一点沉降时间；磁盘慢或者会话启动项特别多时，单次运行仍可能启动得太早。唤醒服务和开机服务是兜底。
- **开机那次没有通知。** 开机阶段没有桌面会话，修复结果只进 journal。用 `--status` 或 `journalctl -b -u t2-netfix.service` 看。
- **修复是事后的，不是预防的。** 它是在芯片坏掉之后修，并不能阻止驱动再坏。`T2_PRE_POWEROFF_BT=1` 能降低频率，但消不掉。

**范围**

- **不提取固件，也不碰 macOS。** 工具刻意从不挂载你的 APFS 分区。如果你以前在加密卷上跑过 `get_from_macos`，可能已经写进了坏固件 —— 恢复一份已知良好的固件包得手动做，本仓库不代劳。
- **没有任何遥测，不联网。** 脚本全程不访问互联网。

## 排错

```sh
t2-netfix --check                     # 现在到底哪坏了
sudo t2-netfix --force --notify        # 看着它修
journalctl -t t2-netfix -n 50          # 上一次自动执行干了什么
journalctl -b -u t2-netfix.service     # 开机那次
journalctl -b -u t2-netfix-resume.service
```

- **hook 从来不跑。** 确认文件在 `/usr/lib/systemd/system-sleep/`（不是 `/etc`）且有执行权限。如果你把 systemd 升到 258 以上，留在 `/etc` 里的 hook 会被静默忽略。
- **蓝牙反复掉到 `probe failed -110`。** 别再拿 `get_from_macos` 重载它；用 `sudo t2-netfix --force`，它走的是 PCI 功能复位而不是反复折腾驱动。如果每次唤醒都犯，保持 `T2_PRE_POWEROFF_BT=1`。
- **Wi-Fi 显示 `half` 但你知道附近有热点。** 先查监管域和接口状态：`nmcli radio wifi on`、`iw reg get`、`rfkill list`。
- **没有通知。** 通知来自桌面会话，开机那次没有会话可发。登录后执行 `sudo t2-netfix --notify --force` 测一下这条链路。
- **它说 `ok` 但你觉得还是不对。** `--check` 连跑两次：热点数量缓存 20 秒，刚唤醒就扫描有可能在射频还没稳定时返回空结果。

## 参与改进

在这里，带日志的 bug 报告比代码补丁更有价值，因为故障模式跟具体硬件强相关。有用的材料：

- `uname -a`、`cat /sys/class/dmi/id/product_name`、`lspci -nn | grep -i 14e4`
- `journalctl -t t2-netfix -n 100`
- 出问题之后的 `sudo t2-netfix --status` 和 `t2-netfix --check`
- 坏之前你做了什么（睡眠、登出、跑过 `get_from_macos`……）

提交补丁前请先跑 `shellcheck t2-netfix.sh install.sh`，CI 用的是同一个检查。

## 卸载

```sh
sudo ./install.sh --uninstall
```

会删掉主程序、两个 service、hook、sudoers 文件、自启动项和 `/etc/t2-netfix.conf`。

## 说明

- 与 Apple 无关。不修改也不再分发任何固件；脚本只重载驱动、复位本来就在的 PCI 功能。
- 脚本做的每件事都会以 `t2-netfix` 标签记进 journal。
- `--status` 读的是 `/run/t2-netfix.status`，重启后会清空。

## 许可

MIT —— 见 [LICENSE](LICENSE)。
