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
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# CodeCat: разрешает переключать только disablesleep без пароля
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
EOF
visudo -cf "$TMP"
install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"

# Демон СНАЧАЛА проверяет флаг и только потом пишет. Без этой проверки он
# выполнял `pmset -a disablesleep 0` безусловно каждые StartInterval секунд всё
# время, пока CodeCat не запущен, — то есть навсегда после того, как человек вышел
# из приложения. Каждый такой вызов заставляет powerd перечитать и переписать
# настройки энергосбережения («Energy Saver Prefs have changed» в системном
# журнале), от root, раз в минуту, вечно. На машине разработчика набежало 1957
# запусков за двое суток. Ничего не ломалось, но так вести себя утилита не имеет
# права, и в раздаваемой сборке этого быть не должно.
#
# Скобки вокруг второй половины обязательны. `A || B && C` в bash разбирается как
# `(A || B) && C` — то есть при ЖИВОМ CodeCat (A истинно) выполнился бы C и снял
# флаг прямо во время работы агентов, ровно наоборот задуманному. Группировка
# `A || { B && C; }` — единственная запись, которая делает то, что написано.
#
# Раньше демон срабатывал только один раз при загрузке (RunAtLoad), поэтому
# если приложение падало (crash, kill -9, Force Quit) с уже включённым
# disablesleep, флаг оставался выставленным до следующей перезагрузки — ровно
# то, для защиты от чего этот демон и существует. Теперь демон реально
# наблюдает: помимо RunAtLoad он перезапускается каждые StartInterval секунд
# и снимает disablesleep, если процесс CodeCat не запущен. Пока CodeCat жив,
# демон ничего не трогает — переключение disablesleep в 1 остаётся за самим
# приложением (через отдельное узкое sudoers-правило, см. выше), это не
# расширяет то, что демон делает от имени root.
cat > "$DAEMON_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.codecat.sleepreset</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>/usr/bin/pgrep -x CodeCat >/dev/null 2>&amp;1 || { /usr/bin/pmset -g | /usr/bin/grep -qE 'SleepDisabled[[:space:]]+1' &amp;&amp; /usr/bin/pmset -a disablesleep 0; }</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>60</integer>
</dict></plist>
EOF
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"
# bootout+bootstrap (not just bootstrap) so re-running the installer after an
# upgrade actually picks up a changed plist, not just the first-install case.
launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null || true
echo "Режим закрытой крышки CodeCat установлен для пользователя $TARGET_USER"
