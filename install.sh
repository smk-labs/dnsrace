#!/usr/bin/env bash
# Install or upgrade dnsrace from this checkout.
#
# Usage: sudo ./install.sh [dnsproxy-version]      e.g. sudo ./install.sh 0.83.1
#
# Idempotent. Re-run any time to upgrade the binary or push config changes.
#
# Everything lands in root-owned paths on purpose: a root daemon must never
# exec a binary or read a config that an unprivileged user can rewrite, which
# is why this does not use a Homebrew prefix.
set -euo pipefail

LABEL="org.adguard.dnsproxy"
ROTATE_LABEL="$LABEL.logrotate"
BIN=/usr/local/bin/dnsproxy
CLI=/usr/local/bin/dnsrace
ETC=/usr/local/etc/dnsproxy
LOGDIR=/Library/Logs/dnsproxy
DAEMONS=/Library/LaunchDaemons
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$(uname -s)" == Darwin ]] || { echo "macOS only." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

case "$(uname -m)" in
  arm64)  GOARCH=arm64 ;;
  x86_64) GOARCH=amd64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Default to whatever upstream currently tags as latest, so a fresh install is
# never pinned to a stale release. Falls back to a known-good tag offline.
if [[ -n "${1:-}" ]]; then
  VERSION="${1#v}"
else
  VERSION="$(curl -fsSL --max-time 10 \
    https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest 2>/dev/null \
    | sed -n 's/.*"tag_name"[^"]*"v\([^"]*\)".*/\1/p' | head -1)"
  VERSION="${VERSION:-0.83.1}"
fi

TARBALL="dnsproxy-darwin-$GOARCH-v$VERSION.tar.gz"
URL="https://github.com/AdguardTeam/dnsproxy/releases/download/v$VERSION/$TARBALL"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading dnsproxy v$VERSION ($GOARCH)"
curl -fsSL -o "$TMP/$TARBALL" "$URL"

# Verify against the sha256 digest GitHub publishes for the release asset, so a
# tampered or truncated download never reaches /usr/local/bin.
echo "==> Verifying checksum"
EXPECTED="$(curl -fsSL "https://api.github.com/repos/AdguardTeam/dnsproxy/releases/tags/v$VERSION" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(a['digest'] for a in d['assets'] if a['name']=='$TARBALL').split(':')[1])")"
ACTUAL="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi
echo "    ok $ACTUAL"

tar xzf "$TMP/$TARBALL" -C "$TMP"

echo "==> Installing"
mkdir -p "$ETC" "$LOGDIR"
install -o root -g wheel -m 755 "$TMP/darwin-$GOARCH/dnsproxy" "$BIN"
install -o root -g wheel -m 755 "$SRC/dnsrace"                 "$CLI"
install -o root -g wheel -m 644 "$SRC/config/dnsproxy.yaml"    "$ETC/dnsproxy.yaml"
install -o root -g wheel -m 644 "$SRC/config/$LABEL.plist"        "$DAEMONS/$LABEL.plist"
install -o root -g wheel -m 644 "$SRC/config/$ROTATE_LABEL.plist" "$DAEMONS/$ROTATE_LABEL.plist"
"$BIN" --version

echo "==> Loading daemons"
for l in "$LABEL" "$ROTATE_LABEL"; do
  launchctl bootout "system/$l" 2>/dev/null || true
  launchctl bootstrap system "$DAEMONS/$l.plist"
done
sleep 1
launchctl print "system/$LABEL" | grep -E '^\s+(state|pid) ' || true

echo "==> Test query"
if command -v dig >/dev/null; then
  if dig +short +time=5 example.com @127.0.0.1 | head -1; then
    :
  else
    echo "WARNING: test query failed. Check $LOGDIR/dnsproxy.log" >&2
  fi
else
  echo "    dig not installed, skipped (brew install bind)"
fi

cat <<'EOF'

Done. The resolver is listening on 127.0.0.1:53 and starts at boot.

  dnsrace status         is it up, and does it answer
  dnsrace system on      point macOS itself at it (sudo)
  dnsrace help           everything else

Any app that takes a DNS server address can be pointed at 127.0.0.1.
EOF
