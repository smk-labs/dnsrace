# How it works

Every setting in `config/dnsproxy.yaml` exists for a reason. This is the reason.

## Racing instead of choosing

The resolver sends each query to all upstreams in its group at the same time and
returns the first valid answer.

- This is AdGuard dnsproxy's `upstream-mode: parallel`. The alternatives are
  `load_balance` (pick one by past latency) and `fastest_addr` (race, then also
  probe the returned addresses).
- The winner is re-decided per query, so the resolver adapts to the network it
  is on with no configuration and no measurement step.
- Failure handling is implicit. An upstream that is down, rate limited, or
  blackholed does not need to be detected or removed: it simply never wins.
- Latency lands near the floor of the pool rather than the average. With 28
  upstreams racing, one of them having a bad minute stops mattering.

## The cost of racing

Racing trades queries for latency, and it is worth being explicit about the bill.

- One cache miss becomes one UDP query per upstream in the group. A query packet
  is around 60 to 80 bytes, so the bandwidth is irrelevant, but the query count
  is not: it is multiplied by the pool size.
- Every upstream in the group sees every name you look up. Racing is not a
  privacy technique. It is the opposite of one: it broadcasts to the pool
  instead of confiding in one resolver. Choose the pool with that in mind.
- The cache is what keeps this sane. A hit costs zero upstream queries, so with
  a large optimistic cache the amplification applies only to genuinely new
  names.

## Suffix-scoped groups, and why fast is not the same as right

Upstreams are split into a default group and a group scoped to one suffix.
Latency alone would pick the wrong resolver for that suffix.

- A zone whose authoritative nameservers all sit in one region resolves better
  through resolvers that are network-close to those servers. The zone is already
  hot in their cache, and their path to it is short. A distant anycast resolver
  must walk the delegation chain from outside the region on every cold name,
  which is slower and times out more often.
- The trap: those same near resolvers are also the lowest-latency members of the
  pool for everything else. Put them in the default group and they win almost
  every race, including races for names they answer worse.
- Answering fast and answering correctly are independent. Resolvers commonly
  rewrite answers: ad-blocking and parental-control resolvers return a sinkhole
  address, some return a wildcard or placeholder instead of NXDOMAIN, some strip
  records they do not like. In a race, the fastest rewriter beats the slowest
  honest resolver every time.
- So scoping is not an optimization, it is a correctness fix. Syntax:
  `"[/suffix/]1.2.3.4:53"` restricts that upstream to names under that suffix.
  Add a group per suffix that needs one.

## Placeholder answers become NXDOMAIN

Some resolvers answer with a private-range address rather than admitting the
name does not resolve.

- `bogus-nxdomain: 10.10.34.0/24` tells the resolver to treat answers in that
  range as NXDOMAIN.
- Without it, the client gets an address, opens a connection, and waits for a
  TCP timeout. With it, the client is told immediately that the name does not
  resolve, which is the truth and is far faster to act on.
- Add any range your own upstreams use as a placeholder.

## Cache

The cache exists to make racing cheap, so it is tuned to be generous.

- `cache-size: 4194304` is 4 MB, which holds a very large number of entries.
- `cache-optimistic: true` serves an expired entry immediately and refreshes it
  in the background. Without it, every TTL expiry hands a user the full cold
  lookup latency. With it, expiry is invisible.
- `cache-min-ttl: 60` floors short TTLs at one minute. Some large properties
  publish 30 second or shorter TTLs, which would otherwise mean re-racing the
  pool for the same hostname several times a minute.

## DNSSEC is off

`dnssec: false` means the DO bit is not set on upstream queries.

- Validation happens at the recursive resolver, not here. Setting DO would
  request the records to validate locally, which this does not do.
- In a diverse pool it also costs answers: some resolvers return malformed,
  truncated, or empty responses to EDNS queries carrying DO, and a broken answer
  can win a race.

## Fallback

`fallback` is a separate list used only when every upstream in the matching
group failed for one query.

- It is not part of any race, so it adds no query volume in normal operation.
- It answers any suffix, not only the scoped one, which is what makes it a
  genuine last resort rather than a second group.

## Log volume

Parallel racing is loud, because a lost race is logged.

- Every timeout and every refusal from an upstream is one ERROR line, and with a
  large pool most queries produce several. Expect a couple of megabytes a day on
  a machine in normal use. These lines are noise by design, not a fault.
- dnsproxy has no log level below its default, so the volume cannot be turned
  down, only capped.
- `launchd` owns the log file and holds it open in append mode, which rules out
  renaming it. Rotating the usual way leaves `launchd` writing to the renamed
  file while the new one stays empty forever.
- Truncating in place is the operation that does work, because an append-mode
  write always lands at the current end of the file, which after a truncate is
  zero. A small daily job truncates only when the file is over 20 MB, so the
  recent log is always there to read.

## Measuring it

`bench/benchmark.sh` times each upstream on its own, which is the only way to
see who is actually carrying the race here.

- Every query prepends a random label, so no resolver has seen that name and
  none can answer from cache. A cached lookup measures network round-trip time
  and nothing else.
- Queries round-robin across several domains, so a resolver that happens to hold
  one popular zone hot cannot look good on that alone.
- Results are sorted by average latency plus a heavy loss penalty, because a
  resolver that answers in 40 ms one time in three is worse than a steady one at
  120 ms.
- Use it to drop upstreams that are dead on every network you use, not to pick a
  single winner. Picking a single winner is the problem this project exists to
  avoid.
