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
SHARE=/usr/local/share/dnsrace
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

# Unload before writing anything, and wait for launchd to really let go.
#
# launchctl bootout returns as soon as the request is queued, not when the job
# is gone. Bootstrapping a label that launchd still has registered fails with
# "Bootstrap failed: 5: Input/output error", and rewriting a plist underneath a
# loaded job invites the same thing. So: stop, confirm it is gone, then install.
unload() {
  local label="$1" i
  launchctl bootout "system/$label" 2>/dev/null || true
  for ((i = 0; i < 100; i++)); do
    launchctl print "system/$label" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  echo "WARNING: $label is still registered after 10s." >&2
}

load() {
  local label="$1" plist="$2" i
  for ((i = 1; i <= 3; i++)); do
    launchctl bootstrap system "$plist" 2>/dev/null && return 0
    sleep 1
  done
  # Surface the real error on the last try instead of swallowing it.
  launchctl bootstrap system "$plist"
}

echo "==> Stopping any running daemon"
unload "$LABEL"
unload "$ROTATE_LABEL"

echo "==> Installing"
mkdir -p "$ETC" "$LOGDIR"
install -o root -g wheel -m 755 "$TMP/darwin-$GOARCH/dnsproxy" "$BIN"
install -o root -g wheel -m 755 "$SRC/dnsrace"                 "$CLI"
install -o root -g wheel -m 644 "$SRC/config/dnsproxy.yaml"    "$ETC/dnsproxy.yaml"
install -o root -g wheel -m 644 "$SRC/config/$LABEL.plist"        "$DAEMONS/$LABEL.plist"
install -o root -g wheel -m 644 "$SRC/config/$ROTATE_LABEL.plist" "$DAEMONS/$ROTATE_LABEL.plist"

# Keep a root-owned copy of the project itself. `dnsrace bench` and
# `dnsrace uninstall` read it, so running this straight from a clone has to
# leave the same layout behind as the one-command installer does.
if [[ "$SRC" != "$SHARE" ]]; then
  rm -rf "$SHARE"
  mkdir -p "$SHARE"
  # No .git, no local notes: only what the installed copy needs to work.
  tar -C "$SRC" --exclude .git --exclude local -cf - . | tar -C "$SHARE" -xf -
  chown -R root:wheel "$SHARE"
  chmod 755 "$SHARE/install.sh" "$SHARE/uninstall.sh" "$SHARE/get.sh" \
            "$SHARE/dnsrace" "$SHARE/bench/benchmark.sh"
fi

"$BIN" --version

echo "==> Loading daemons"
load "$LABEL"        "$DAEMONS/$LABEL.plist"
load "$ROTATE_LABEL" "$DAEMONS/$ROTATE_LABEL.plist" || true
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
