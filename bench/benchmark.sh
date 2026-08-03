#!/usr/bin/env bash
# Times every upstream in the config individually, so you can see which ones
# actually carry the race on the network you are on right now.
#
# Two things make the numbers mean something:
#
#   1. Every query prepends a random label, so no resolver has ever seen that
#      name and none of them can answer from cache. A cached lookup collapses to
#      network round-trip time and tells you nothing about the resolver.
#   2. Queries round-robin over several domains, so a resolver that happens to
#      hold one popular zone hot cannot look good on that alone.
#
# The resolver list is read straight out of dnsproxy.yaml. There is no separate
# list to keep in sync: the config is the only place upstreams are written down.
#
# Usage: ./benchmark.sh "<domains,csv>" [queries] [timeout_s] [parallel]
#   ./benchmark.sh                                     # defaults
#   ./benchmark.sh "github.com,wikipedia.org" 20 3 12
#
# Losing the race is not a defect. An upstream that is slow or unreachable here
# costs nothing at runtime, so treat this as a pruning tool for upstreams that
# are dead everywhere, not as a way to pick one winner.

set -u

DOMAINS_STR="${1:-cloudflare.com,google.com,wikipedia.org,github.com,apple.com,microsoft.com,amazon.com}"
N="${2:-14}"
TIMEOUT="${3:-4}"
PARALLEL="${4:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the live installed config, fall back to the one in this checkout.
CONF="${DNSRACE_CONFIG:-}"
if [[ -z "$CONF" ]]; then
  for c in /usr/local/etc/dnsproxy/dnsproxy.yaml "$SCRIPT_DIR/../config/dnsproxy.yaml"; do
    [[ -r "$c" ]] && { CONF="$c"; break; }
  done
fi

command -v dig >/dev/null || { echo "dig not found. brew install bind" >&2; exit 1; }
[[ -n "$CONF" && -r "$CONF" ]] || { echo "No readable dnsproxy.yaml found." >&2; exit 1; }

# Pull bare IPs out of the upstream list: drop any [/suffix/] scope prefix, drop
# the :53 port, drop duplicates, keep config order.
servers="$(sed -nE 's/^[[:space:]]*-[[:space:]]*"?(\[\/[^]]*\/\])?(([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]+"?[[:space:]]*$/\2/p' \
           "$CONF" | awk '!seen[$0]++')"
count="$(printf '%s\n' "$servers" | grep -c .)"
[[ "$count" -gt 0 ]] || { echo "No upstreams found in $CONF" >&2; exit 1; }

OUT="$(mktemp -t dnsbench)"
trap 'rm -f "$OUT"' EXIT

test_one() {
  local dns="$1" domains_str="$2" n="$3" timeout="$4"
  local -a domains
  IFS=',' read -ra domains <<< "$domains_str"
  local times=() fails=0 i t rnd domain ndom=${#domains[@]}
  for ((i = 0; i < n; i++)); do
    domain="${domains[i % ndom]}"
    rnd=$(printf '%x%x%x' "$RANDOM" "$RANDOM" "$RANDOM")
    t=$(dig +tries=1 "+time=$timeout" +stats @"$dns" "z${rnd}.${domain}" 2>/dev/null \
        | awk '/Query time:/ {print $4; exit}')
    if [[ -z "$t" ]]; then
      fails=$((fails + 1))
    else
      times+=("$t")
    fi
  done
  if (( ${#times[@]} == 0 )); then
    printf "999999\t%s\t-\t-\t-\t-\t100\n" "$dns"
  else
    printf '%s\n' "${times[@]}" \
      | awk -v dns="$dns" -v n="$n" -v fails="$fails" '
        {sum+=$1; sumsq+=$1*$1; if(NR==1||$1<min)min=$1; if($1>max)max=$1}
        END {
          m=NR
          mean=sum/m
          var=(sumsq/m)-(mean*mean); if(var<0)var=0
          loss=(fails/n)*100
          # Sort key is avg plus loss*1000, so a lossy resolver sinks to the
          # bottom no matter how fast its surviving answers were.
          printf "%.2f\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.0f\n",
                 mean+loss*1000, dns, mean, min, max, sqrt(var), loss
        }'
  fi
}
export -f test_one

domain_count=$(echo "$DOMAINS_STR" | tr ',' '\n' | grep -c .)

echo "Cold-cache upstream benchmark"
echo "Config=$CONF"
echo "Upstreams=$count  Domains=$domain_count  Queries=$N (round-robin)  Timeout=${TIMEOUT}s  Parallel=$PARALLEL"
echo "Domains: $DOMAINS_STR"
echo

printf '%s\n' "$servers" \
  | xargs -P "$PARALLEL" -I{} bash -c 'test_one "$@"' _ {} "$DOMAINS_STR" "$N" "$TIMEOUT" \
  > "$OUT"

printf "%-20s  %8s  %8s  %8s  %8s  %6s\n" "UPSTREAM" "avg(ms)" "min" "max" "stddev" "loss%"
printf -- '--------------------------------------------------------------------------\n'
sort -n "$OUT" | awk -F'\t' '{printf "%-20s  %8s  %8s  %8s  %8s  %5s%%\n", $2, $3, $4, $5, $6, $7}'
