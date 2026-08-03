#!/usr/bin/env bash
# Remove dnsrace: daemons, binary, CLI, config, log, and the installed copy.
#
# Usage: sudo ./uninstall.sh
#
# Resets macOS DNS back to DHCP first, so the machine still resolves names once
# the resolver is gone.
set -uo pipefail

LABEL=org.adguard.dnsproxy
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

echo "==> Resetting macOS DNS to DHCP"
while read -r svc; do
  networksetup -setdnsservers "$svc" empty 2>/dev/null && echo "    $svc"
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*')
dscacheutil -flushcache 2>/dev/null
killall -HUP mDNSResponder 2>/dev/null

echo "==> Unloading daemons"
for l in "$LABEL" "$LABEL.logrotate"; do
  launchctl bootout "system/$l" 2>/dev/null && echo "    $l"
done

echo "==> Removing files"
for f in \
  "/Library/LaunchDaemons/$LABEL.plist" \
  "/Library/LaunchDaemons/$LABEL.logrotate.plist" \
  /usr/local/bin/dnsproxy \
  /usr/local/bin/dnsrace \
  /usr/local/etc/dnsproxy \
  /usr/local/share/dnsrace \
  /Library/Logs/dnsproxy
do
  [[ -e "$f" ]] && rm -rf "$f" && echo "    $f"
done

echo "Done."
