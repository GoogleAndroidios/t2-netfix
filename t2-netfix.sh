#!/usr/bin/env bash
#
# t2-netfix - restore Wi-Fi and Bluetooth on Apple T2 Macs after
#             suspend/resume or a fresh login.
#
# Why this is needed
#   On T2 Macs the Wi-Fi and Bluetooth function is a single Broadcom combo
#   chip (BCM4377 on Intel T2 machines) driven by brcmfmac + hci_bcm4377.
#   After a suspend cycle or a re-login the firmware/PCI state is reset but
#   the drivers are often not re-bound correctly, which shows up as one of:
#
#     - no wl* interface at all
#     - wl* exists but cannot see a single access point
#     - hci0 exists but hciconfig says DOWN / bluetoothctl cannot power it on
#     - hci0 powers on but every scan command times out
#     - controller is fine but paired keyboards/mice never reconnect
#
#   Reloading the modules (or, if the chip really hung, resetting the PCI
#   function) brings it back. The firmware is already in /lib/firmware/brcm,
#   so re-extracting it from the macOS partition is unnecessary - and on
#   encrypted APFS volumes the extracted data is not even reliable.
#
# How it works
#   Every check is functional, never "does the node exist":
#     Wi-Fi    ok = can see at least one AP
#              half = interface exists but zero APs -> firmware half-dead
#              missing = no wireless interface
#     BT       ok = can start and stop a scan
#              broken = powers on but scanning fails
#              missing = no controller node
#
#   Repair escalates from cheap to drastic, and re-checks after each round:
#     soft reset (interface down/up, restart bluetoothd)
#       -> module reload
#         -> PCI function level reset (unbind, reset, bind)
#   Rounds stop as soon as both are healthy.
#
# Usage
#   sudo t2-netfix              # diagnose, repair only if something is wrong
#   sudo t2-netfix --login      # same, but wait for the interface to appear
#   sudo t2-netfix --notify     # desktop notifications with live progress
#   sudo t2-netfix --status     # last run + current live state
#   sudo t2-netfix --check      # diagnose only, change nothing
#   sudo t2-netfix --connect    # only reconnect paired keyboards/mice
#   sudo t2-netfix --force      # force the full repair sequence
#   sudo t2-netfix --quiet      # no stdout (for the boot service)
#
# Configuration
#   /etc/t2-netfix.conf is sourced if present (see t2-netfix.conf.example).
#   Every setting can also be given as an environment variable.
#
# Exit codes
#   0 everything healthy (or repaired)   1 still broken   2 bad usage
#
# License: MIT

set -u

VERSION="1.0.0"
TAG="t2-netfix"
STATE_FILE="/run/t2-netfix.status"
LOCK_FILE="/run/t2-netfix.lock"
CONF="${T2_NETFIX_CONF:-/etc/t2-netfix.conf}"

# ---------- configuration ----------
# shellcheck disable=SC1090
if [ -r "$CONF" ]; then
    . "$CONF" 2>/dev/null || true
fi

: "${T2_MAX_ROUNDS:=3}"        # upper bound of reload rounds
: "${T2_RECONNECT_MAX:=60}"    # seconds spent reconnecting input devices
: "${T2_RECONNECT_ICONS:=input-*}"  # bluetoothctl Icon values worth reconnecting
: "${T2_SCAN_CACHE_TTL:=20}"   # seconds to cache the AP count
: "${T2_PCI_VENDOR:=0x14e4}"   # Broadcom
# PCI device IDs known to be the Bluetooth function on T2 Intel Macs.
# Only used when the driver is not bound (so the driver name is unavailable).
: "${T2_BT_PCI_IDS:=0x5fa0|0x5f69|0x5f71|0x5f72}"

case "$T2_MAX_ROUNDS" in ''|*[!0-9]*) T2_MAX_ROUNDS=3 ;; esac
case "$T2_RECONNECT_MAX" in ''|*[!0-9]*) T2_RECONNECT_MAX=60 ;; esac
case "$T2_SCAN_CACHE_TTL" in ''|*[!0-9]*) T2_SCAN_CACHE_TTL=20 ;; esac
[ "$T2_MAX_ROUNDS" -lt 1 ] && T2_MAX_ROUNDS=1

# ---------- flags ----------
OP_FORCE=0
OP_QUIET=0
OP_NOTIFY=0
OP_STATUS=0
OP_CHECK=0
OP_CONNECT=0
OP_LOGIN=0
OP_VERSION=0

for arg in "$@"; do
    case "$arg" in
        --force)   OP_FORCE=1 ;;
        --quiet)   OP_QUIET=1 ;;
        --notify)  OP_NOTIFY=1 ;;
        --status)  OP_STATUS=1 ;;
        --check)   OP_CHECK=1 ;;
        --connect) OP_CONNECT=1 ;;
        --login)   OP_LOGIN=1 ;;
        --version|-V) OP_VERSION=1 ;;
        -h|--help)
            # print the header comment block, whatever its length
            awk 'NR>=3 && /^#/ { sub(/^# ?/, ""); print; next } NR>=3 { exit }' "$0"
            exit 0
            ;;
        *)
            echo "t2-netfix: unknown option '$arg' (try --help)" >&2
            exit 2
            ;;
    esac
done

if [ "$OP_VERSION" -eq 1 ]; then
    echo "t2-netfix $VERSION"
    exit 0
fi

ROUND=0
RECONNECTED=0

# ---------- logging / notifications ----------
log() {
    logger -t "$TAG" "$*" 2>/dev/null || true
    [ "$OP_QUIET" -eq 1 ] || printf '%s\n' "$*"
}

# Desktop notification. Under sudo the user session bus is found through
# SUDO_UID; in a system context (sleep hook, system service) there is no
# SUDO_UID, so the bus is discovered by scanning /run/user.
# The DBus session bus rejects connections from root, so when running as root
# we drop privileges to the bus owner before calling notify-send.
# A fixed replace-id makes successive calls update the same bubble in place.
notify() {
    [ "$OP_NOTIFY" -eq 1 ] || return 0
    command -v notify-send >/dev/null 2>&1 || return 0

    local icon="$1" title="$2" body="$3" expire="${4:-6000}"
    local bus="" uid="" user="" cand

    if [ -n "${SUDO_UID:-}" ] && [ -S "/run/user/$SUDO_UID/bus" ]; then
        bus="/run/user/$SUDO_UID/bus"; uid="$SUDO_UID"
    else
        for cand in /run/user/*/bus; do
            [ -S "$cand" ] || continue
            uid="${cand#/run/user/}"; uid="${uid%/bus}"
            bus="$cand"
            break
        done
    fi
    [ -n "$bus" ] && [ -n "$uid" ] || return 0

    user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
    [ -n "$user" ] || return 0

    if [ "$(id -u)" -eq 0 ] && [ "$uid" != "0" ]; then
        command -v runuser >/dev/null 2>&1 || return 0
        runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            notify-send -a "T2 Netfix" -i "$icon" -r 991237 -t "$expire" \
            "$title" "$body" 2>/dev/null || true
    else
        DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            notify-send -a "T2 Netfix" -i "$icon" -r 991237 -t "$expire" \
            "$title" "$body" 2>/dev/null || true
    fi
}

write_state() {
    # /run is only writable by root; silently skip when run unprivileged
    [ "$(id -u)" -eq 0 ] || return 0
    {
        printf 'time: %s\n' "$(date '+%F %T')"
        printf 'wifi: %s\n' "$1"
        printf 'bluetooth: %s\n' "$2"
        printf 'action: %s\n' "$3"
    } > "$STATE_FILE" 2>/dev/null || true
}

# ---------- Wi-Fi probing ----------
wifi_if() {
    local p i=""
    for p in /sys/class/net/wl*; do
        [ -e "$p" ] || continue
        i=${p##*/}
        break
    done
    if [ -z "$i" ] && command -v iw >/dev/null 2>&1; then
        i=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
    fi
    printf '%s' "$i"
}

wifi_ok() {
    local i; i=$(wifi_if)
    [ -n "$i" ] || return 1
    [ -e "/sys/class/net/$i/device" ] || return 1
    # An interface can exist while the wireless stack is dead, in which case
    # iw fails. Without iw we can only check for the interface itself.
    command -v iw >/dev/null 2>&1 || return 0
    iw dev "$i" info >/dev/null 2>&1
}

WIFI_SCAN_CACHE=""
WIFI_SCAN_TS=0

# Number of visible APs, cached for T2_SCAN_CACHE_TTL seconds because a forced
# rescan can take a while and progress notifications refresh frequently.
# Returns nothing (empty) when no scanning tool is available at all.
wifi_scan_count() {
    local now n i
    now=$(date +%s)
    if [ -n "$WIFI_SCAN_CACHE" ] && [ $((now - WIFI_SCAN_TS)) -lt "$T2_SCAN_CACHE_TTL" ]; then
        printf '%s' "$WIFI_SCAN_CACHE"; return 0
    fi

    if command -v nmcli >/dev/null 2>&1; then
        n=$(timeout 25 nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | grep -c .)
        [ -n "$n" ] || n=0
    else
        n=""
    fi

    if { [ -z "$n" ] || [ "$n" -eq 0 ]; } && command -v iw >/dev/null 2>&1; then
        i=$(wifi_if)
        if [ -n "$i" ]; then
            n=$(timeout 20 iw dev "$i" scan 2>/dev/null | grep -c '^[[:space:]]*SSID:')
            [ -n "$n" ] || n=0
        fi
    fi

    if [ -z "$n" ]; then
        # No way to scan: leave the cache empty so callers fall back to the
        # interface check instead of reporting a bogus zero.
        printf ''; return 0
    fi

    WIFI_SCAN_CACHE="$n"; WIFI_SCAN_TS="$now"
    printf '%s' "$n"
}

# ok | half | missing
wifi_probe() {
    local n
    [ -n "$(wifi_if)" ] || { printf 'missing'; return; }
    wifi_ok || { printf 'half'; return; }
    n=$(wifi_scan_count)
    if [ -z "$n" ]; then printf 'ok'; return; fi   # cannot scan, assume alive
    [ "$n" -gt 0 ] && printf 'ok' || printf 'half'
}

wifi_text() {
    local s="${1:-$(wifi_probe)}"
    case "$s" in
        ok)      printf 'ok (%s)' "$(wifi_if)" ;;
        half)    printf 'half-dead (%s up, but no AP visible)' "$(wifi_if)" ;;
        missing) printf 'missing (no wireless interface)' ;;
        *)       printf 'unknown' ;;
    esac
}

# ---------- Bluetooth probing ----------
bt_dev() {
    local p
    for p in /sys/class/bluetooth/hci*; do
        [ -e "$p" ] || continue
        printf '%s' "${p##*/}"
        break
    done
    return 0
}

bt_powered() {
    timeout 6 bluetoothctl show 2>/dev/null \
        | sed -n 's/^[[:space:]]*Powered:[[:space:]]*//p' | head -n1
}

# HCI layer state. hciconfig is precise but lives in bluez-deprecated-tools on
# newer distros, so fall back to bluetoothctl when it is not installed.
bt_up() {
    local d; d=$(bt_dev)
    [ -n "$d" ] || return 1
    if command -v hciconfig >/dev/null 2>&1; then
        hciconfig "$d" 2>/dev/null | grep -q 'UP RUNNING' && return 0
        return 1
    fi
    [ "$(bt_powered)" = "yes" ]
}

bt_power_on() {
    local _
    [ "$(bt_powered)" = "yes" ] && return 0
    for _ in 1 2 3; do
        timeout 8 bluetoothctl power on >/dev/null 2>&1
        [ "$(bt_powered)" = "yes" ] && return 0
        sleep 1
    done
    return 1
}

# Radio level check: can we actually start and stop a scan?
# A hung controller still reports UP RUNNING, but "scan off" fails and
# "scan on" stays InProgress forever, so a power-state check alone lies.
bt_radio_ok() {
    local out
    timeout 5 bluetoothctl scan off >/dev/null 2>&1 || true
    sleep 0.5
    out=$(timeout 9 bluetoothctl --timeout 4 scan on 2>&1)
    timeout 5 bluetoothctl scan off >/dev/null 2>&1 || true
    printf '%s\n' "$out" | grep -q 'Failed to start discovery' && return 1
    printf '%s\n' "$out" | grep -qi 'InProgress' && return 1
    return 0
}

# ok | broken | missing
# If the controller was deliberately powered off by the user, it is powered
# back off after the test so the user's setting is preserved.
bt_probe() {
    local d before attempt
    d=$(bt_dev)
    [ -n "$d" ] || { printf 'missing'; return; }

    if bt_up; then
        bt_radio_ok && printf 'ok' || printf 'broken'
        return
    fi

    before=$(bt_powered)
    for attempt in 1 2; do
        if timeout 8 bluetoothctl power on >/dev/null 2>&1 \
           && [ "$(bt_powered)" = "yes" ]; then
            if [ "$before" = "no" ]; then
                timeout 6 bluetoothctl power off >/dev/null 2>&1 || true
                printf 'ok'
            else
                bt_radio_ok && printf 'ok' || printf 'broken'
            fi
            return
        fi
        [ "$attempt" -eq 1 ] && sleep 2
    done
    printf 'broken'
}

bt_text() {
    case "$1" in
        ok)      printf 'ok (%s)' "$(bt_dev)" ;;
        broken)  printf 'broken (%s present but unresponsive)' "$(bt_dev)" ;;
        missing) printf 'missing (no controller node)' ;;
        *)       printf 'unknown' ;;
    esac
}

# ---------- paired devices ----------
bt_paired_list() { timeout 8 bluetoothctl devices Paired 2>/dev/null | awk '{print $2}'; }

bt_field() {
    printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" | head -n1
}

bt_connected_names() {
    local m info names=""
    for m in $(bt_paired_list); do
        info=$(timeout 6 bluetoothctl info "$m" 2>/dev/null) || continue
        [ "$(bt_field "$info" Connected)" = "yes" ] || continue
        names="${names:+$names, }$(bt_field "$info" Alias)"
    done
    printf '%s' "$names"
}

bt_conn_text() {
    local names total
    names=$(bt_connected_names)
    total=$(bt_paired_list | grep -c .)
    if [ -n "$names" ]; then
        printf 'connected: %s' "$names"
    elif [ "$total" -gt 0 ]; then
        printf 'no device connected (%s paired)' "$total"
    else
        printf 'no paired device'
    fi
}

# Reconnect paired input devices. Headsets, phones etc. are left alone so the
# script never steals a link the user did not ask for.
# Result goes to the global RECONNECTED.
bt_reconnect_inputs() {
    local m info icon name attempt
    local deadline=$((SECONDS + T2_RECONNECT_MAX))
    RECONNECTED=0

    # After a reload/reset bluetoothd often keeps a stale "Discovering" flag
    # (visible as "Failed to stop discovery"); every connect then returns
    # InProgress. Clear it, and if that fails do one power cycle - safe here
    # because nothing is connected yet.
    if ! timeout 6 bluetoothctl scan off >/dev/null 2>&1; then
        log "discovery flag stuck, power-cycling the controller"
        timeout 8 bluetoothctl power off >/dev/null 2>&1 || true
        sleep 1
        timeout 8 bluetoothctl power on >/dev/null 2>&1 || true
        sleep 2
    fi

    for m in $(bt_paired_list); do
        [ "$SECONDS" -lt "$deadline" ] || { log "reconnect timed out after ${T2_RECONNECT_MAX}s"; break; }
        info=$(timeout 6 bluetoothctl info "$m" 2>/dev/null) || continue
        [ "$(bt_field "$info" Connected)" = "yes" ] && continue
        icon=$(bt_field "$info" Icon)
        # shellcheck disable=SC2254
        case "$icon" in $T2_RECONNECT_ICONS) ;; *) continue ;; esac

        name=$(bt_field "$info" Alias)
        log "reconnecting ${name:-$m}"
        # bluez needs ~10-20s after a reload before it accepts a new connection
        # (every attempt returns InProgress until then), so retry with a delay.
        for attempt in 1 2 3 4; do
            [ "$SECONDS" -lt "$deadline" ] || break
            timeout 12 bluetoothctl connect "$m" >/dev/null 2>&1 || true
            info=$(timeout 6 bluetoothctl info "$m" 2>/dev/null)
            if [ "$(bt_field "$info" Connected)" = "yes" ]; then
                RECONNECTED=$((RECONNECTED + 1))
                log "  ${name:-$m} connected"
                break
            fi
            [ "$attempt" -lt 4 ] && sleep 5
        done
        if [ "$(bt_field "$(timeout 6 bluetoothctl info "$m" 2>/dev/null)" Connected)" != "yes" ]; then
            log "  ${name:-$m} did not connect (powered off or out of range?)"
        fi
    done
    return 0
}

# ---------- progress ----------
# Cheap state for progress lines: only uses cached data, never triggers a
# scan or a power-on, so refreshing a notification does not stall for 20s.
live_state() {
    local w b
    if wifi_ok; then
        if [ -n "$WIFI_SCAN_CACHE" ]; then
            [ "$WIFI_SCAN_CACHE" -gt 0 ] && w="wifi ok" || w="wifi half-dead"
        else
            w="wifi up"
        fi
    else
        w="wifi gone"
    fi
    if [ -z "$(bt_dev)" ]; then
        b="bt no node"
    elif bt_up; then
        b="bt ok"
    elif [ "$(bt_powered)" = "yes" ]; then
        b="bt unresponsive"
    else
        b="bt off"
    fi
    printf '%s | %s' "$w" "$b"
}

progress() {
    local label="round $ROUND/$T2_MAX_ROUNDS"
    [ "$ROUND" -eq 0 ] && label="pre-check"
    log "$label: $1 ($(live_state))"
    notify network-wireless "Restoring Wi-Fi and Bluetooth ($label)" \
        "$1 | $(live_state)" 0
}

# ---------- diagnostics only ----------
if [ "$OP_STATUS" -eq 1 ]; then
    if [ -r "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "no record yet (the fix has not run since boot)"
    fi
    echo "--- current state ---"
    echo "wifi: $(wifi_text "$(wifi_probe)")"
    echo "bluetooth: $(bt_text "$(bt_probe)")"
    [ -n "$(bt_dev)" ] && echo "devices: $(bt_conn_text)"
    exit 0
fi

if [ "$OP_CHECK" -eq 1 ]; then
    echo "wifi: $(wifi_text "$(wifi_probe)")"
    echo "bluetooth: $(bt_text "$(bt_probe)")"
    echo "devices: $(bt_conn_text)"
    exit 0
fi

if [ "$OP_CONNECT" -eq 1 ]; then
    log "reconnecting paired input devices..."
    bt_reconnect_inputs
    log "done: $RECONNECTED newly connected, $(bt_conn_text)"
    exit 0
fi

# ---------- PCI helpers ----------
# Both the Wi-Fi and the Bluetooth function of the combo chip show up as a
# Broadcom network class device, and the function numbers differ between
# models, so devices are matched by the driver they are bound to instead of
# by a hardcoded BDF.
pci_bdf_by_driver() {
    local p drv
    for p in /sys/bus/pci/devices/*; do
        [ "$(cat "$p/vendor" 2>/dev/null)" = "$T2_PCI_VENDOR" ] || continue
        drv=$(basename "$(readlink -f "$p/driver" 2>/dev/null)" 2>/dev/null)
        [ -n "$drv" ] || continue
        # shellcheck disable=SC2254
        case "$drv" in $1) basename "$p"; return 0 ;; esac
    done
    return 1
}

wifi_pci_bdf() {
    pci_bdf_by_driver 'brcmfmac*' && return 0
    # Driver unbound: fall back to the network class, skipping Bluetooth IDs
    local p
    for p in /sys/bus/pci/devices/*; do
        [ "$(cat "$p/vendor" 2>/dev/null)" = "$T2_PCI_VENDOR" ] || continue
        [ "$(cat "$p/class" 2>/dev/null)" = "0x028000" ] || continue
        # shellcheck disable=SC2254
        case "$(cat "$p/device" 2>/dev/null)" in $T2_BT_PCI_IDS) continue ;; esac
        basename "$p"; return 0
    done
    return 1
}

bt_pci_bdf() {
    pci_bdf_by_driver 'hci_bcm*' && return 0
    local p
    for p in /sys/bus/pci/devices/*; do
        [ "$(cat "$p/vendor" 2>/dev/null)" = "$T2_PCI_VENDOR" ] || continue
        # shellcheck disable=SC2254
        case "$(cat "$p/device" 2>/dev/null)" in $T2_BT_PCI_IDS) basename "$p"; return 0 ;; esac
    done
    return 1
}

# ---------- Wi-Fi repair ----------
reload_wifi() {
    local i
    i=$(wifi_if)
    if [ -n "$i" ]; then
        ip link set "$i" down 2>/dev/null || true
    fi

    modprobe -r brcmfmac_wcc 2>/dev/null || true
    modprobe -r brcmfmac 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do
        lsmod | grep -q '^brcmfmac ' || break
        sleep 0.5
    done
    modprobe brcmfmac 2>/dev/null || log "warning: brcmfmac failed to load"

    for _ in $(seq 1 16); do
        [ -n "$(wifi_if)" ] && return 0
        sleep 0.5
    done
    return 1
}

wifi_soft_reset() {
    local i
    i=$(wifi_if)
    [ -n "$i" ] || return 1
    log "wifi interface is up but sees no AP, trying a soft reset (link down/up + rescan)"
    ip link set "$i" down 2>/dev/null || true
    sleep 1
    ip link set "$i" up 2>/dev/null || true
    sleep 2
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device wifi rescan >/dev/null 2>&1 || true
    fi
    WIFI_SCAN_CACHE=""
    sleep 2
    [ "$(wifi_probe)" = "ok" ]
}

wifi_hard_reset() {
    local bdf drv=/sys/bus/pci/drivers/brcmfmac
    bdf=$(wifi_pci_bdf) || { log "no wireless PCI device found, skipping hard reset"; return 1; }
    log "wifi chip unresponsive, resetting PCI function $bdf"
    progress "wifi fallback: PCI function reset ($bdf)"

    if [ -e "/sys/bus/pci/devices/$bdf/driver" ]; then
        echo "$bdf" > "$drv/unbind" 2>/dev/null || true
    fi
    modprobe -r brcmfmac_wcc 2>/dev/null || true
    modprobe -r brcmfmac 2>/dev/null || true
    sleep 1
    if [ -w "/sys/bus/pci/devices/$bdf/reset" ]; then
        echo 1 > "/sys/bus/pci/devices/$bdf/reset" 2>/dev/null \
            || log "PCI reset write failed"
    else
        log "PCI reset write failed"
    fi
    sleep 2
    modprobe brcmfmac >/dev/null 2>&1 || log "warning: brcmfmac failed to load"
    sleep 2
    [ -e "/sys/bus/pci/devices/$bdf/driver" ] \
        || { { echo "$bdf" > "$drv/bind"; } 2>/dev/null || log "manual bind failed"; }
    for _ in $(seq 1 20); do
        [ -n "$(wifi_if)" ] && break
        sleep 0.5
    done
    WIFI_SCAN_CACHE=""
    [ "$(wifi_probe)" = "ok" ]
}

# ---------- Bluetooth repair ----------
reload_bt() {
    systemctl stop bluetooth 2>/dev/null || true
    modprobe -r hci_bcm4377 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do
        lsmod | grep -q '^hci_bcm4377 ' || break
        sleep 0.5
    done

    if lsmod | grep -q '^hci_bcm4377 '; then
        # Could not unload: let bluetoothd clear the state instead
        # (hciconfig reset is not supported by this driver)
        log "warning: hci_bcm4377 is still loaded, restarting bluetoothd only"
    else
        modprobe hci_bcm4377 2>/dev/null || log "warning: hci_bcm4377 failed to load"
    fi

    systemctl start bluetooth 2>/dev/null || true
    for _ in $(seq 1 12); do
        [ -n "$(bt_dev)" ] && break
        sleep 0.5
    done
    # Wait until bluetoothd has registered the controller. Sending HCI commands
    # inside that initialisation window can make the firmware tx-timeout and
    # hang for good, so waiting 2 extra seconds is cheaper than a bricked chip.
    for _ in $(seq 1 16); do
        timeout 4 bluetoothctl list 2>/dev/null | grep -qi 'Controller' && break
        sleep 0.5
    done
    sleep 1
    bt_power_on || true
}

bt_soft_reset() {
    [ "$(id -u)" -eq 0 ] || { log "skipping bluetooth soft reset (needs root)"; return 1; }
    log "bluetooth controller cannot scan, restarting bluetoothd"
    progress "bluetooth soft reset: restarting bluetoothd"
    systemctl restart bluetooth 2>/dev/null || true
    sleep 2
    bt_power_on || true
}

# The only thing that helps once the HCI layer really hung
# (tx timeout / failed to destroy transfer ring / probe -110).
bt_hard_reset() {
    local bdf drv=/sys/bus/pci/drivers/hci_bcm4377
    [ "$(id -u)" -eq 0 ] || { log "skipping PCI hard reset (needs root)"; return 1; }
    bdf=$(bt_pci_bdf) || { log "no bluetooth PCI device found, skipping hard reset"; return 1; }
    log "bluetooth chip unresponsive, resetting PCI function $bdf"
    progress "bluetooth fallback: PCI function reset ($bdf)"

    systemctl stop bluetooth 2>/dev/null || true
    if [ -e "/sys/bus/pci/devices/$bdf/driver" ]; then
        echo "$bdf" > "$drv/unbind" 2>/dev/null || true
    fi
    modprobe -r hci_bcm4377 2>/dev/null || true
    sleep 1

    { echo 1 > "/sys/bus/pci/devices/$bdf/reset"; } 2>/dev/null \
        || log "PCI reset write failed"
    sleep 2

    modprobe hci_bcm4377 2>/dev/null || log "warning: hci_bcm4377 failed to load"
    sleep 2
    [ -e "/sys/bus/pci/devices/$bdf/driver" ] \
        || { { echo "$bdf" > "$drv/bind"; } 2>/dev/null || log "manual bind failed"; sleep 2; }

    systemctl start bluetooth 2>/dev/null || true
    for _ in $(seq 1 16); do
        [ -n "$(bt_dev)" ] && break
        sleep 0.5
    done
    bt_power_on || true

    # A function reset can disturb the Wi-Fi function in the same slot
    wifi_ok || reload_wifi || true
}

# ---------- serialise concurrent triggers ----------
# sleep hook, resume service, boot service and login autostart can overlap
if [ -w /run ] && command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -w 180 9 || log "another instance is taking too long, continuing anyway"
fi

# ---------- wait for the interface on login ----------
# Right after login the interface may not have been enumerated yet; treating
# that as "missing" would trigger a pointless reload round.
if [ "$OP_LOGIN" -eq 1 ]; then
    for _ in $(seq 1 40); do
        [ -n "$(wifi_if)" ] && break
        sleep 0.5
    done
    sleep 2
fi

# ---------- diagnose ----------
B_STATE=$(bt_probe)
W_STATE=$(wifi_probe)

if [ "$OP_FORCE" -eq 0 ]; then
    if [ "$W_STATE" = "ok" ] && [ "$B_STATE" = "ok" ]; then
        log "wifi ($(wifi_if)) and bluetooth ($(bt_dev)) are healthy"
        if [ -z "$(bt_connected_names)" ]; then
            log "no paired device connected, trying to reconnect keyboards/mice"
            bt_reconnect_inputs
            log "reconnect: $RECONNECTED newly connected, $(bt_conn_text)"
        fi
        write_state "ok ($(wifi_if))" "ok ($(bt_dev))" "healthy, $(bt_conn_text)"
        notify network-wireless "Check complete: everything is healthy" \
            "wifi $(wifi_if) ($(wifi_scan_count) APs) | bt $(bt_dev) | $(bt_conn_text)" 8000
        exit 0
    fi

    log "problem found: wifi=$(wifi_text "$W_STATE") bluetooth=$(bt_text "$B_STATE")"
    notify network-wireless "Problem found, starting repair" \
        "wifi: $(wifi_text "$W_STATE") | bluetooth: $(bt_text "$B_STATE")" 0
fi

# ---------- repair rounds ----------
recovered=0

# Cheapest applicable fix first: never start by unloading modules.
if [ "$B_STATE" = "missing" ]; then
    log "bluetooth controller node is gone, module reload cannot help - going straight to PCI reset"
    bt_hard_reset || true
elif [ "$B_STATE" = "broken" ]; then
    bt_soft_reset || true
fi

if [ "$W_STATE" = "half" ]; then
    wifi_soft_reset || true
fi

W_STATE=$(wifi_probe)
B_STATE=$(bt_probe)
[ "$W_STATE" = "ok" ] && [ "$B_STATE" = "ok" ] && recovered=1

while [ "$recovered" -eq 0 ] && [ "$ROUND" -lt "$T2_MAX_ROUNDS" ]; do
    ROUND=$((ROUND + 1))

    progress "reloading wifi driver (brcmfmac)"
    reload_wifi || true
    WIFI_SCAN_CACHE=""
    progress "wifi reloaded ($(wifi_ok && echo interface back || echo no interface)), handling bluetooth"

    if [ -z "$(bt_dev)" ]; then
        progress "bluetooth node missing, resetting PCI function"
        bt_hard_reset || true
    else
        progress "reloading bluetooth driver (hci_bcm4377)"
        reload_bt || true
        progress "bluetooth reloaded, checking whether the controller responds"
    fi

    sleep 1

    B_STATE=$(bt_probe)
    W_STATE=$(wifi_probe)
    W_TXT=$(wifi_text "$W_STATE")
    B_TXT=$(bt_text "$B_STATE")

    if [ "$W_STATE" = "ok" ] && [ "$B_STATE" = "ok" ]; then
        progress "recovered: wifi $W_TXT, bluetooth $B_TXT"
        recovered=1
        break
    fi

    if [ "$ROUND" -lt "$T2_MAX_ROUNDS" ]; then
        progress "still broken: wifi $W_TXT, bluetooth $B_TXT - starting round $((ROUND + 1))"
        sleep 2
    else
        log "round $ROUND finished, still broken: wifi $W_TXT, bluetooth $B_TXT"
    fi
done

# ---------- last resort ----------
if [ "$recovered" -eq 0 ]; then
    if [ "$(bt_probe)" != "ok" ]; then
        bt_hard_reset || true
        sleep 1
    fi
    W_STATE=$(wifi_probe)
    if [ "$W_STATE" != "ok" ]; then
        log "wifi still broken ($(wifi_text "$W_STATE")), resetting PCI function"
        wifi_hard_reset || true
        sleep 1
    fi
fi

# ---------- report ----------
W_STATE=$(wifi_probe)
W_TXT=$(wifi_text "$W_STATE")
B_STATE=$(bt_probe)
B_TXT=$(bt_text "$B_STATE")

if [ "$W_STATE" = "ok" ] && [ "$B_STATE" = "ok" ]; then
    if [ -z "$(bt_connected_names)" ]; then
        progress "controller is back, reconnecting bluetooth input devices"
        bt_reconnect_inputs
        [ "$RECONNECTED" -gt 0 ] && log "reconnected $RECONNECTED device(s)"
    fi
    log "wifi back on $(wifi_if), bluetooth back on $(bt_dev), $(bt_conn_text) (after $ROUND round(s))"
    notify network-wireless "Repair complete: Wi-Fi and Bluetooth are back" \
        "after $ROUND round(s) | wifi $(wifi_if) ($(wifi_scan_count) APs) | $(bt_conn_text)" 8000
    write_state "$W_TXT" "$B_TXT" "recovered after $ROUND round(s), $(bt_conn_text)"
    exit 0
fi

log "incomplete after $ROUND round(s): wifi $W_TXT, bluetooth $B_TXT"
notify dialog-warning "Repair did not fully succeed" \
    "after $ROUND round(s) | wifi: $W_TXT | bluetooth: $B_TXT (see: journalctl -t t2-netfix)" 15000
write_state "$W_TXT" "$B_TXT" "not fully recovered after $ROUND round(s)"
exit 1
