#!/usr/bin/env bash
# One-command installer. Downloads this project, then runs its install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/smk-labs/dnsrace/main/get.sh | sudo bash
#
# Keeps a root-owned copy at /usr/local/share/dnsrace so `dnsrace update` can
# fetch a newer version later. Re-run any time; it overwrites cleanly.
#
# No git required: this pulls the branch tarball over https, so it works on a
# machine that has never had the Xcode command line tools installed.
set -euo pipefail

REPO="${DNSRACE_REPO:-smk-labs/dnsrace}"
REF="${1:-${DNSRACE_REF:-main}}"
SHARE=/usr/local/share/dnsrace

[[ "$(uname -s)" == Darwin ]] || { echo "macOS only." >&2; exit 1; }
[[ $EUID -eq 0 ]] || {
  echo "Run with sudo, for example:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/get.sh | sudo bash" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching $REPO ($REF)"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar xz -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -type d -name 'dnsrace-*' | head -1)"
[[ -n "$SRC" && -f "$SRC/install.sh" ]] || { echo "Unexpected archive layout." >&2; exit 1; }

rm -rf "$SHARE"
mkdir -p "$(dirname "$SHARE")"
mv "$SRC" "$SHARE"
chown -R root:wheel "$SHARE"
chmod 755 "$SHARE/install.sh" "$SHARE/uninstall.sh" "$SHARE/dnsrace" "$SHARE/bench/benchmark.sh"

exec "$SHARE/install.sh"
