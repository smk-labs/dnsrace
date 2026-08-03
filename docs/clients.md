# Pointing things at the resolver

The resolver answers on `127.0.0.1:53` and nothing uses it until you point
something at it. There are two ways, and the smaller one is usually better.

## One app at a time

If an app has a DNS server field, put `127.0.0.1` in it.

- This is the better default. It changes one app, leaves the rest of the machine
  on its normal DNS, and is trivial to undo.
- It also works for apps that accept only a single DNS server address, which is
  most of them. From their point of view there is one server. Behind it are 61.

## The whole machine

To route macOS itself through the resolver, on every active network service:

```bash
sudo dnsrace system on     # every active service gets 127.0.0.1
sudo dnsrace system off    # hand DNS back to DHCP
sudo dnsrace system show   # what each service is set to right now
```

Under the hood this is `networksetup -setdnsservers`, applied per network
service, followed by a cache flush and an `mDNSResponder` restart. The setting
survives reboots and network changes, and it is per service, so joining a new
Wi-Fi network keeps it.

## Check that it took effect

```bash
dnsrace status                      # daemon, answer test, and what macOS is set to
scutil --dns | head -20             # the resolver macOS will actually use
dig +short example.com @127.0.0.1   # ask the local resolver directly
```

`dig` ignores the system setting and talks to `127.0.0.1` directly, so it proves
the daemon works. `scutil --dns` proves macOS is configured to use it. When
debugging, check both: they fail for different reasons.

## Three things that catch people out

**A tool that intercepts DNS traffic will trap it in a loop.** Some network
tools and container runtimes transparently capture outbound port 53 and answer it
themselves. If yours does, the resolver's own upstream queries get captured and
handed back to the resolver, which is a loop: nothing resolves and the log fills.
The fix is to exempt the `dnsproxy` process in that tool's own rules, above
whatever rule does the capturing. Any tool that does this kind of interception
has a way to exclude a process.

**Browsers may ignore the system resolver entirely.** Chrome, Firefox, and Edge
ship encrypted DNS on by default in many regions, which sends lookups straight to
their own provider over HTTPS. Turn off "Secure DNS" or "DNS over HTTPS" in the
browser's privacy settings, or the browser will never see this resolver. Safari
follows the system setting.

**`127.0.0.1` means something different inside a container.** To a container,
localhost is the container. To reach a resolver on the host, use
`host.docker.internal` on Docker Desktop, or the bridge gateway address, and note
that many container runtimes inject their own resolver into `/etc/resolv.conf`
regardless.

## Other devices on the network

They cannot use it, by design. `listen-addrs: ["127.0.0.1"]` binds to loopback
only, so nothing outside this machine can reach the resolver.

To serve a LAN, add the machine's address to `listen-addrs` and reload. Do that
only on a network you control: an open resolver reachable from the internet gets
found and used for reflection attacks within hours.
