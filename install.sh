#!/usr/bin/env bash
#
# install.sh - install t2-netfix as an automatic post-resume / post-login repair
#
#   sudo ./install.sh              install
#   sudo ./install.sh --uninstall  remove everything it installed
#
# Installs:
#   /usr/local/sbin/t2-netfix                     the tool itself
#   /usr/lib/systemd/system-sleep/t2-netfix       pre/post suspend hook
#   /etc/systemd/system/t2-netfix-resume.service  runs after resume (backup path)
#   /etc/systemd/system/t2-netfix.service         runs once at boot
#   /etc/sudoers.d/t2-netfix                      passwordless sudo for the tool
#   ~/.config/autostart/t2-netfix.desktop         runs at desktop login
#   /etc/t2-netfix.conf                           optional settings (never overwritten)
#
# License: MIT

set -euo pipefail

trap 'echo "install.sh: failed at line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "run this with sudo: sudo ./install.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/t2-netfix.sh"
CONF_EXAMPLE="$SCRIPT_DIR/t2-netfix.conf.example"

BIN="/usr/local/sbin/t2-netfix"
HOOK="/usr/lib/systemd/system-sleep/t2-netfix"
LEGACY_HOOK="/etc/systemd/system-sleep/t2-netfix"
SERVICE="/etc/systemd/system/t2-netfix.service"
RESUME_SERVICE="/etc/systemd/system/t2-netfix-resume.service"
SUDOERS="/etc/sudoers.d/t2-netfix"
CONF="/etc/t2-netfix.conf"

# The user whose session should get the notifications and the autostart entry.
# When run through sudo this is SUDO_USER; when run from a root shell we fall
# back to logname, and if that fails the user-level parts are skipped.
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
[ "$TARGET_USER" = "root" ] && TARGET_USER="" || true

TARGET_HOME=""
if [ -n "$TARGET_USER" ]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
fi

# ---------- uninstall ----------
if [ "${1:-}" = "--uninstall" ]; then
    echo "==> removing t2-netfix"
    systemctl disable --now t2-netfix.service t2-netfix-resume.service 2>/dev/null || true
    rm -f "$BIN" "$HOOK" "$LEGACY_HOOK" "$SERVICE" "$RESUME_SERVICE" "$SUDOERS" "$CONF"
    if [ -n "$TARGET_HOME" ]; then
        rm -f "$TARGET_HOME/.config/autostart/t2-netfix.desktop"
    fi
    rm -f /run/t2-netfix.status /run/t2-netfix.lock /run/t2-netfix.pre-poweroff
    systemctl daemon-reload
    echo "done."
    exit 0
fi

[ -f "$SRC" ] || { echo "cannot find $SRC (run install.sh from the repo directory)" >&2; exit 1; }

# ---------- 1. the tool ----------
echo "==> installing $BIN"
install -m 755 "$SRC" "$BIN"

# ---------- 2. suspend hook ----------
# /usr/lib/systemd/system-sleep is scanned by every systemd version, while
# /etc/systemd/system-sleep was dropped in systemd 258+, so the hook always
# goes to /usr/lib and any stale copy in /etc is removed.
mkdir -p /usr/lib/systemd/system-sleep
if [ -e "$LEGACY_HOOK" ]; then
    echo "==> removing stale hook at $LEGACY_HOOK (ignored by systemd 258+)"
    rm -f "$LEGACY_HOOK"
fi
echo "==> installing suspend hook $HOOK"
cat > "$HOOK" <<'EOF'
#!/bin/sh
# Called by systemd-sleep as: t2-netfix pre|post <action>
# pre : power the Bluetooth radio down so the BCM4377 firmware does not hang
# post: repair whatever did not come back
CONF=/etc/t2-netfix.conf
T2_PRE_POWEROFF_BT=1
[ -r "$CONF" ] && . "$CONF" 2>/dev/null || true
MARK=/run/t2-netfix.pre-poweroff

case "$1" in
    pre)
        [ "$T2_PRE_POWEROFF_BT" = "1" ] || exit 0
        command -v bluetoothctl >/dev/null 2>&1 || exit 0
        if timeout 8 bluetoothctl power off >/dev/null 2>&1; then
            : > "$MARK"
        fi
        ;;
    post)
        /usr/local/sbin/t2-netfix --notify >/dev/null 2>&1 || true
        rm -f "$MARK"
        ;;
esac
exit 0
EOF
chmod 755 "$HOOK"

# ---------- 3. post-resume service (backup for the hook) ----------
# suspend.target is only reached after systemd-suspend.service finished, which
# happens when the machine wakes up, so this oneshot runs after resume.
echo "==> installing $RESUME_SERVICE"
cat > "$RESUME_SERVICE" <<'EOF'
[Unit]
Description=Restore Wi-Fi/Bluetooth on Apple T2 Mac after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/t2-netfix --notify
# 3 reload rounds plus the reconnect timeout can take several minutes
TimeoutStartSec=300

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF

# ---------- 4. boot service ----------
echo "==> installing $SERVICE"
cat > "$SERVICE" <<'EOF'
[Unit]
Description=Restore Wi-Fi/Bluetooth on Apple T2 Mac at boot
After=NetworkManager.service bluetooth.service
Wants=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/t2-netfix --login --quiet
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# ---------- 5. passwordless sudo for the login autostart ----------
echo "==> allowing $TARGET_USER to run $BIN without a password"
mkdir -p /etc/sudoers.d
if [ -n "$TARGET_USER" ]; then
    printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$BIN" > "$SUDOERS"
    chmod 440 "$SUDOERS"
    if ! visudo -c -f "$SUDOERS" >/dev/null 2>&1; then
        rm -f "$SUDOERS"
        echo "warning: sudoers validation failed, skipped (the login autostart will need a password)"
    fi
else
    echo "warning: could not determine the desktop user, skipping sudoers and autostart"
fi

# ---------- 6. login autostart ----------
if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
    echo "==> installing login autostart for $TARGET_USER"
    mkdir -p "$TARGET_HOME/.config/autostart"
    cat > "$TARGET_HOME/.config/autostart/t2-netfix.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=T2 Netfix
Comment=Restore Wi-Fi and Bluetooth after login on Apple T2 Macs
Exec=sudo $BIN --login --notify
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod 644 "$TARGET_HOME/.config/autostart/t2-netfix.desktop"
    chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/autostart/t2-netfix.desktop" 2>/dev/null || true
fi

# ---------- 7. optional config ----------
if [ ! -e "$CONF" ] && [ -f "$CONF_EXAMPLE" ]; then
    echo "==> installing default config $CONF"
    install -m 644 "$CONF_EXAMPLE" "$CONF"
fi

# ---------- 8. enable ----------
systemctl daemon-reload
systemctl enable t2-netfix.service >/dev/null 2>&1 || true
systemctl enable t2-netfix-resume.service >/dev/null 2>&1 || true

cat <<EOF

Installed.

  check current state     : $BIN --check
  last run + live state   : $BIN --status
  force a full repair     : sudo $BIN --force --notify
  log                     : journalctl -t t2-netfix -n 50
  settings                : $CONF
  uninstall               : sudo ./install.sh --uninstall

Triggers: suspend hook + post-resume service, boot, desktop login.
A notification is shown after each login/resume - also when everything is
healthy, so you can tell it actually ran.
EOF
