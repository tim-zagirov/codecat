#!/bin/bash
# Устанавливает поддержку режима закрытой крышки CodeCat.
# Запускается от root (через osascript with administrator privileges).
set -euo pipefail

# Не полагаемся только на $SUDO_USER/$USER: когда скрипт запущен через
# `osascript ... with administrator privileges`, процесс выполняется как root
# с чистым окружением, и оба этих значения могут оказаться "root". Реальный
# залогиненный пользователь консоли — самый надёжный источник в обоих случаях
# (обычный sudo и osascript-эскалация).
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
SUDOERS_FILE=/etc/sudoers.d/codecat
DAEMON_PLIST=/Library/LaunchDaemons/com.codecat.sleepreset.plist

TMP=$(mktemp)
cat > "$TMP" <<EOF
# CodeCat: разрешает переключать только disablesleep без пароля
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
EOF
visudo -cf "$TMP"
install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"
rm -f "$TMP"

cat > "$DAEMON_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.codecat.sleepreset</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/pmset</string><string>-a</string>
        <string>disablesleep</string><string>0</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict></plist>
EOF
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"
launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null || true
echo "CodeCat lid mode installed for $TARGET_USER"
