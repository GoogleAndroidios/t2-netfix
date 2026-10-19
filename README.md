# t2-netfix

[![shellcheck](https://github.com/GoogleAndroidios/t2-netfix/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/GoogleAndroidios/t2-netfix/actions/workflows/shellcheck.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** | [简体中文](README.zh-CN.md)

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

## Tested on

Only one physical machine has been used so far. The table below is the complete
environment it was developed and verified against — not a guess at what "should"
work.

| Item | Value |
| --- | --- |
| Model | `MacBookAir9,1` (MacBook Air 2020, Intel) |
| SoC / CPU | Intel Core i3-1000NG4 (4 threads) |
| Board | `Mac-0CFF9C7C2B63DF8D` |
| iBridge firmware | `24.16.6005.0.0` |
| Distro | Ubuntu 26.04.1 LTS |
| Kernel | `7.2.11-3-t2-resolute` ([t2linux]) |
| Session | GNOME Shell 50.1 on Wayland |
| systemd | 259 (`259.5-0ubuntu3.4`) |
| BlueZ | 5.85 (`5.85-4ubuntu0.4`) |
| NetworkManager | 1.54.3 |
| wpa_supplicant | 2.11 |
| Wi-Fi function | `73:00.0` — BCM4377b, `14e4:4488` (rev 04) |
| Bluetooth function | `73:00.1` — BRCM4377, `14e4:5fa0` (rev 04) |
| Drivers | `brcmfmac`, `brcmfmac_wcc`, `hci_bcm4377` |
| Firmware | `brcmfmac4377b3-pcie.apple,formosa.bin`, `brcmbt4377b3-apple,formosa.bin` |
| Sleep mode | `deep` (S3); `s2idle` is available but not the default |

### What was actually exercised

- Wi-Fi and Bluetooth surviving a full **suspend → resume** cycle (`deep`), with
  the hook repairing both before the desktop is usable.
- **Desktop login** and **boot** triggers, including the `flock` serialisation
  when more than one fires at once.
- **Wi-Fi half-dead**: interface present, `iw` responsive, zero APs visible —
  detected as `half` and repaired. This was the case that originally slipped
  through a node-existence check.
- **Bluetooth half-dead**: `hci0` present and `Powered: yes`, but `scan off`
  failing and every scan timing out — detected as `broken` and repaired.
- **`probe -110` hang**: the worst state, where `hci_bcm4377` fails to probe and
  the controller node disappears entirely. Recovered several times with the PCI
  function reset; this is why the escalation ladder exists.
- Automatic **reconnection of a Bluetooth keyboard and mouse** after a driver
  reload, including clearing bluez's stale `Discovering` flag.
- **Notifications** from a root-owned service reaching the logged-in user's
  session bus (`runuser` + `DBUS_SESSION_BUS_ADDRESS`), with live progress.
- `--check`, `--status`, `--connect`, `--force`, `--quiet`, `--login` exit codes.

### Other models

Reports are welcome and genuinely useful. If you run this on another T2 model,
open an issue with:

```sh
uname -a
cat /sys/class/dmi/id/product_name
lspci -nn | grep -i 14e4
journalctl -t t2-netfix -n 50
```

## Limitations

Read this before installing. These are real, measured constraints, not
disclaimers.

**Platform**

- **Intel T2 only.** Apple Silicon Macs (M1 and later) have no T2 and no
  `brcmfmac`/`hci_bcm4377` combo of this kind; this tool is irrelevant there.
- **Broadcom combo chip only.** It targets BCM4377/4378 (`14e4:4488`,
  `14e4:5fa0`). Machines with Intel, Qualcomm or MediaTek wireless are not
  supported.
- **The drivers must already work.** If `brcmfmac` or `hci_bcm4377` is missing,
  or `/lib/firmware/brcm` lacks the matching `.bin`, no amount of reloading
  helps — install the [t2linux] kernel and firmware packages first (this repo
  never downloads or redistributes firmware).
- **Verified on one machine.** MacBookPro 2018–2020, Mac mini 2018, iMac
  2019–2020 and Mac Pro 2019 are *expected* to work because the chip and driver
  stack are the same, but none of them has been tested. Treat a first install on
  another model as experimental, and keep a terminal open.
- **systemd only.** The triggers are a `systemd-sleep` hook plus two units.
  OpenRC, runit and other init systems are not supported.

**Suspend and wake**

- **A Bluetooth keyboard or mouse cannot wake a suspended T2 Mac.** In `deep`
  (S3) the radio is unpowered. This is a hardware property, not something this
  tool can fix; see [Wake-up](#wake-up-what-can-actually-wake-the-machine).
- **The default configuration powers Bluetooth off before sleeping**
  (`T2_PRE_POWEROFF_BT=1`). That is deliberate: it avoids the firmware hang on
  resume, but it also removes any chance of a BT wake. Setting it to `0` keeps
  the radio alive and makes the `-110` hang more likely.
- **`s2idle` is not tested.** The reference machine sleeps in `deep`. If you
  force `s2idle` (`/sys/power/mem_sleep`), the chip is not reset the same way
  and the repair ladder may behave differently.
- **Hibernation (`disk`) is not supported or tested.** The hook only acts on
  `pre`/`post` suspend.
- **A cold boot that never enumerated the chip cannot be repaired.** If the PCI
  device is absent at the firmware level, the script logs it and exits; only a
  reboot helps.

**Runtime behaviour**

- **`--force` interrupts your network for a few seconds.** Driver reload means
  the interface disappears. Existing SSH sessions over Wi-Fi will drop.
- **Root is required**, and `install.sh` grants passwordless sudo for exactly
  one file (`/etc/sudoers.d/t2-netfix` → `/usr/local/sbin/t2-netfix`). Anyone
  who can edit that script can run arbitrary code as root. Review it before
  installing; remove the sudoers file if you do not want the autostart triggers.
- **Reconnection covers input devices only.** Devices whose `bluetoothctl`
  `Icon` is `input-*` (keyboards, mice, gamepads) are reconnected; headsets,
  speakers, phones and anything else are left untouched, so the script never
  steals a link you did not ask for.
- **Reconnection is best-effort within a 60 s budget.** After a reload, bluez
  needs roughly 10–20 s before it accepts new connections; if a device is
  powered off, out of range, or still holds a stale link, it will not connect
  and the tool moves on rather than blocking login.
- **The first seconds after login are a race.** `--login` waits up to 20 s for
  the interface plus a short settle time; on a slow disk or with a heavy session
  startup, a single run may still start too early. The resume service and the
  boot service are the safety nets.
- **No notifications from the boot-time run.** There is no desktop session at
  boot, so boot repairs are journal-only. Use `--status` or
  `journalctl -b -u t2-netfix.service` to see what happened.
- **Repair is reactive, not preventive.** It fixes the chip after it breaks; it
  does not stop the driver from breaking. `T2_PRE_POWEROFF_BT=1` reduces the
  frequency but does not eliminate it.

**Scope**

- **No firmware extraction and no macOS access.** The tool deliberately never
  mounts your APFS partition. If you previously used `get_from_macos` on an
  encrypted volume, that may have written bad firmware — restoring a known-good
  firmware package is a manual job this repo does not attempt.
- **No telemetry, no network access.** The script never talks to the internet.

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
- **It reports `ok` but something is still wrong.** Run `--check` twice: the AP
  count is cached for 20 s, and a scan issued immediately after resume can
  legitimately return nothing while the radio settles.

## Contributing

Bug reports with logs are more valuable than patches here, because the failure
modes are hardware-specific. Useful material:

- `uname -a`, `cat /sys/class/dmi/id/product_name`, `lspci -nn | grep -i 14e4`
- `journalctl -t t2-netfix -n 100`
- `sudo t2-netfix --status` after the failure, and `t2-netfix --check`
- What you did right before it broke (suspend, logout, `get_from_macos`, …)

Please run `shellcheck t2-netfix.sh install.sh` before sending a patch; CI runs
the same check.

## Uninstall

```sh
sudo ./install.sh --uninstall
```

This removes the tool, both services, the hook, the sudoers file, the autostart
entry and `/etc/t2-netfix.conf`.

## Notes

- Not affiliated with Apple. No firmware is modified or redistributed; the
  script only reloads drivers and resets PCI functions that are already there.
- Everything the script does is logged to the journal under the `t2-netfix` tag.
- `--status` reads the last run from `/run/t2-netfix.status`, so it resets on
  reboot.

## License

MIT — see [LICENSE](LICENSE).
