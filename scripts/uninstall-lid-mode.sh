#!/bin/bash
set -euo pipefail
/usr/bin/pmset -a disablesleep 0 || true
launchctl bootout system /Library/LaunchDaemons/com.codecat.sleepreset.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.codecat.sleepreset.plist
rm -f /etc/sudoers.d/codecat
echo "Режим закрытой крышки CodeCat удалён"
