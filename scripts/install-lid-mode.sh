#!/bin/bash
# Installs support for CodeCat's closed-lid mode.
# Runs as root (through osascript with administrator privileges).
set -euo pipefail

# Do not rely on $SUDO_USER/$USER alone: when the script is run through
# `osascript ... with administrator privileges` the process executes as root with a
# clean environment, and both of those can turn out to be "root". The actual
# logged-in console user is the most reliable source in both cases (ordinary sudo
# and osascript escalation).
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
SUDOERS_FILE=/etc/sudoers.d/codecat
DAEMON_PLIST=/Library/LaunchDaemons/com.codecat.sleepreset.plist

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# CodeCat: allows toggling disablesleep and nothing else, without a password
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
EOF
visudo -cf "$TMP"
install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"

# The daemon checks the flag FIRST and only then writes. Without that check it ran
# `pmset -a disablesleep 0` unconditionally every StartInterval seconds for as long
# as CodeCat was not running — that is, forever, once someone quit the app. Every
# such call makes powerd re-read and rewrite the energy settings ("Energy Saver
# Prefs have changed" in the system log), as root, once a minute, indefinitely. On
# the developer's machine that added up to 1957 runs over two days. Nothing broke,
# but a utility has no right to behave that way, and a build that ships to people
# must not.
#
# Written as three commands with early `exit 0` rather than a chain of
# `A || { B && C; }`, for two things at once.
#
# First, correctness. A naive `A || B && C` parses in bash as `(A || B) && C`: with
# CodeCat ALIVE (A true) C would run and clear the flag while agents were working —
# exactly the opposite of the intent. Verified with stub pgrep/pmset: without the
# grouping the flag really does get cleared.
#
# Second, an honest exit code. In the parenthesised version "nothing to do" produced
# exit 1, and launchd reported `last exit code = 1` for a perfectly healthy daemon —
# lying to whoever came to investigate. Now a non-zero code means exactly one thing:
# pmset genuinely failed.
#
# The daemon used to fire only once at boot (RunAtLoad), so if the app died (crash,
# kill -9, Force Quit) with disablesleep already on, the flag stayed set until the
# next reboot — precisely what this daemon exists to prevent. Now it actually
# watches: besides RunAtLoad it restarts every StartInterval seconds and clears
# disablesleep if no CodeCat process is running. While CodeCat is alive the daemon
# touches nothing — setting disablesleep to 1 remains the app's own job, through the
# separate narrow sudoers rule above, so this does not widen what the daemon does as
# root.
cat > "$DAEMON_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.codecat.sleepreset</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>/usr/bin/pgrep -x CodeCat >/dev/null 2>&amp;1 &amp;&amp; exit 0; /usr/bin/pmset -g | /usr/bin/grep -qE 'SleepDisabled[[:space:]]+1' || exit 0; /usr/bin/pmset -a disablesleep 0</string>
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
echo "CodeCat closed-lid mode installed for user $TARGET_USER"
