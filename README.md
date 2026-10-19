# t2-netfix

Restore Wi-Fi and Bluetooth on Apple T2 Macs after suspend/resume, on wake, or
after logging back in — automatically, and without re-extracting firmware from
your macOS partition.

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

## The problem

On Intel T2 Macs the Wi-Fi and Bluetooth function is **one Broadcom combo chip**
(BCM4377, driven by `brcmfmac` + `hci_bcm4377`). Across a suspend cycle, or
after re-login, the chip is reset but the drivers are frequently left in a bad
state. Typical symptoms:

| Symptom | What is actually broken |
| --- | --- |
| No `wl*` interface at all | driver not bound after resume |
| `wl*` exists, NetworkManager shows nothing, no APs appear | wireless firmware half-dead |
| `hci0` exists but is `DOWN`, "No default controller available" | controller not re-initialised |
| `hci0` powers on, but every scan times out, `bluetoothctl show` says `Powered: no` | HCI layer hung (`tx timeout`, `probe -110`) |
| Controller fine, but your keyboard/mouse never reconnect | bluez stale discovery / connection state |

All of these come back if you reload the drivers — or, when the chip has really
hung, reset its PCI function. The firmware is **already** in
`/lib/firmware/brcm`; there is no need to touch macOS again.

## Why not just run `get-apple-firmware get_from_macos`?

Because that command ends with:

```sh
modprobe -r brcmfmac_wcc; modprobe -r brcmfmac; modprobe brcmfmac
modprobe -r hci_bcm4377;  modprobe hci_bcm4377
```

The *reload* is what fixes your network — the firmware extraction is a
side effect that costs 30+ seconds, mounts your APFS volumes, and on encrypted
volumes reads unreliable data (the kernel literally logs
`volume is encrypted, may not be read correctly`). Worse, killing `hci_bcm4377`
while it is mid-initialisation can leave the Bluetooth function unbound for the
rest of the session.

`t2-netfix` does the reload, skips the extraction, and escalates to a PCI reset
only when a reload genuinely cannot help.

## Requirements

- An **Intel T2 Mac** (MacBookPro 2018–2020, MacBookAir 2018–2020, Mac mini 2018,
  iMac 2019–2020, Mac Pro 2019). Apple Silicon is a different platform and does
  not need this.
- A distro using **systemd** and **BlueZ** (Ubuntu, Fedora, Arch, Debian, …).
- Working Wi-Fi/Bluetooth drivers in the first place: `brcmfmac` for Wi-Fi,
  `hci_bcm4377` for Bluetooth (for example via the [t2linux] kernel packages).
- `bash`, `modprobe`, `bluetoothctl`. Everything else (`nmcli`, `iw`,
  `hciconfig`, `notify-send`) is optional and detected at runtime.

[t2linux]: https://wiki.t2linux.org/

## Install

```sh
git clone https://github.com/GoogleAndroidios/t2-netfix.git
cd t2-netfix
sudo ./install.sh
```

Then verify:

```sh
sudo t2-netfix --check        # should report ok / ok
sudo systemctl suspend        # wake it up, and the repair runs by itself
t2-netfix --status            # shows what the last automatic run did
```

Nothing is installed outside these paths, and `sudo ./install.sh --uninstall`
removes all of it.

## Usage

```
sudo t2-netfix              diagnose, repair only if something is wrong
sudo t2-netfix --login      same, but first wait for the interface to appear
sudo t2-netfix --notify     desktop notifications with live progress
sudo t2-netfix --status     last run + current live state
sudo t2-netfix --check      diagnose only, change nothing
sudo t2-netfix --connect    only reconnect paired keyboards/mice
sudo t2-netfix --force      force the full repair sequence
sudo t2-netfix --quiet      no stdout (used by the boot service)
```

Exit codes: `0` healthy or repaired, `1` still broken, `2` bad usage.

## How health is judged

Every check is **functional**. "The device node exists" is never taken as proof
of anything — that is exactly the state a hung chip leaves behind.

| Check | `ok` | degraded | missing |
| --- | --- | --- | --- |
| Wi-Fi | at least one AP visible | interface up but zero APs (`half`) | no wireless interface |
| Bluetooth | a scan can be started and stopped | powers on but scanning fails (`broken`) | no controller node |

Repair escalates from cheap to drastic, and **re-checks after every round**, so
a healthy chip costs one round and nothing else:

```
soft reset   interface down/up, restart bluetoothd, rescan
   ↓ still broken
module       modprobe -r + modprobe for brcmfmac / hci_bcm4377
   ↓ still broken
PCI reset    unbind, echo 1 > .../reset, modprobe, bind
```

A missing controller node skips the module stage entirely: unloading a driver
whose device failed to probe (`-110`) only makes it worse.

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/local/sbin/t2-netfix` | the tool |
| `/usr/lib/systemd/system-sleep/t2-netfix` | runs `pre` (power BT off) and `post` (repair) around suspend |
| `/etc/systemd/system/t2-netfix-resume.service` | runs after resume, backup for the hook |
| `/etc/systemd/system/t2-netfix.service` | runs once at boot |
| `/etc/sudoers.d/t2-netfix` | passwordless sudo, **only** for this one script |
| `~/.config/autostart/t2-netfix.desktop` | runs at desktop login |
| `/etc/t2-netfix.conf` | optional settings, see the example file |

The systemd sleep hook lives in `/usr/lib/systemd/system-sleep` on purpose:
systemd 258+ silently stopped executing hooks from `/etc/systemd/system-sleep`,
which is the single most common reason "my hook never runs" reports.

## Configuration

`/etc/t2-netfix.conf` is sourced by the tool and by the suspend hook. Every key
can also be passed as an environment variable.

| Key | Default | Meaning |
| --- | --- | --- |
| `T2_MAX_ROUNDS` | `3` | reload rounds before the PCI reset fallback |
| `T2_RECONNECT_MAX` | `60` | seconds spent reconnecting keyboards/mice |
| `T2_RECONNECT_ICONS` | `input-*` | which `bluetoothctl` icons are reconnected |
| `T2_SCAN_CACHE_TTL` | `20` | AP-count cache lifetime, seconds |
| `T2_PCI_VENDOR` | `0x14e4` | PCI vendor of the combo chip |
| `T2_BT_PCI_IDS` | `0x5fa0\|0x5f69\|0x5f71\|0x5f72` | Bluetooth function IDs, used when no driver is bound |
| `T2_PRE_POWEROFF_BT` | `1` | power Bluetooth off before suspend |

`T2_PRE_POWEROFF_BT` is worth knowing about: powering the radio down *before*
sleeping avoids the firmware hang entirely, at the cost of not being able to
wake the machine from a Bluetooth device. See the next section.

## Wake-up: what can actually wake the machine

A Bluetooth keyboard or mouse **cannot** wake a suspended T2 Mac. In `deep`
(S3) sleep the radio is unpowered, so there is nothing listening.

Practical options, in order of convenience:

1. **Don't suspend at all.** With an external monitor, set
   `lid-close-ac-action` to `nothing` (GNOME: *Settings → Power → Automatic
   Suspend* off, and `gsettings set org.gnome.settings-daemon.plugins.power
   lid-close-ac-action 'nothing'`). Turn the panel off after an idle timeout
   instead — pressing a key on the Bluetooth keyboard brings the external
   display back with no resume delay.
2. Wake with the **lid**, the **power button**, or by re-plugging the
   **USB-C display cable** (USB-C controllers are wake-capable).
3. Allow the **charger** to wake the machine:
   `echo ADP1 | sudo tee /proc/acpi/wakeup` (not persistent, and the ACPI name
   differs per model).

## Troubleshooting

```sh
t2-netfix --check                     # what is broken right now
sudo t2-netfix --force --notify        # watch the repair happen
journalctl -t t2-netfix -n 50          # what the last automatic run did
journalctl -b -u t2-netfix.service     # boot-time run
journalctl -b -u t2-netfix-resume.service
```

- **The hook never runs.** Check that the file exists under
  `/usr/lib/systemd/system-sleep/` (not `/etc`) and that it is executable. If
  you upgraded systemd to 258+, a hook left in `/etc` is silently ignored.
- **Bluetooth keeps dropping to `probe failed -110`.** Stop reloading it with
  `get_from_macos`; use `sudo t2-netfix --force`, which resets the PCI function
  instead of thrashing the driver. If it happens on every resume, keep
  `T2_PRE_POWEROFF_BT=1`.
- **Wi-Fi says `half` but you know there are APs.** Your regulatory domain or
  the interface may be down: `nmcli radio wifi on`, `iw reg get`, and
  `rfkill list` are the things to check first.
- **No notifications.** Notifications come from the desktop session; a boot-time
  run has no session to talk to. Log in and run
  `sudo t2-netfix --notify --force` to test the path.

## Uninstall

```sh
sudo ./install.sh --uninstall
```

This removes the tool, both services, the hook, the sudoers file, the autostart
entry and `/etc/t2-netfix.conf`.

## Tested on

| Machine | Distro | Kernel | Result |
| --- | --- | --- | --- |
| MacBookAir9,1 (2020, i3) | Ubuntu 26.04, GNOME/Wayland | 7.2.x-t2 | works: suspend/resume, login, `probe -110` recovery |

Reports from other models are welcome — open an issue with `uname -a`, your
model (`cat /sys/class/dmi/id/product_name`) and
`journalctl -t t2-netfix -n 50`.

## Notes

- Not affiliated with Apple. No firmware is modified or redistributed; the
  script only reloads drivers and resets PCI functions that are already there.
- The suspend hook powers the Bluetooth radio off before sleeping. If you rely
  on waking from a Bluetooth peripheral, set `T2_PRE_POWEROFF_BT=0`.
- `t2-netfix --force` will briefly interrupt your network connection. That is
  expected — it is reloading the driver.
- The script needs root for `modprobe` and PCI sysfs writes; everything it does
  is logged to the journal under the `t2-netfix` tag.

## License

MIT — see [LICENSE](LICENSE).

---

## 中文速览

T2 芯片的 Intel Mac 上，Wi-Fi 和蓝牙是同一颗 Broadcom 芯片（BCM4377），
睡眠唤醒或重新登录后驱动常常没能正确重新绑定，表现是：没有 Wi-Fi 网卡、
有网卡但一个热点都搜不到、蓝牙节点在但点不亮或扫描超时、键鼠连不回来。

这个工具做三件事：

1. **功能性判断**，不看节点在不在——Wi-Fi 以"能不能扫到热点"为准，蓝牙以
   "能不能启停扫描"为准。节点还在但已经卡死的状态不会被误判成正常。
2. **由轻到重修复**：软复位（接口 down/up、重启 bluetoothd）→ 重载驱动 →
   PCI 功能级复位。每轮结束实测，好了就停。
3. **四个触发点全自动**：挂起唤醒、唤醒兜底服务、开机、桌面登录，并串行化避免
   互相打架。

安装：`sudo ./install.sh`，验证：`sudo t2-netfix --check`，卸载：
`sudo ./install.sh --uninstall`。

注意：**蓝牙键鼠无法唤醒挂起的机器**（S3 下射频断电）。外接显示器场景建议
直接关掉合盖休眠、只让屏幕熄灭，按键即亮。
