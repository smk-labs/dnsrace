# dnsrace

A local DNS resolver for macOS that asks 61 public resolvers at once and keeps
the first good answer. It listens on `127.0.0.1:53`, starts at boot, and stays
up on its own.

## The problem

Every device is normally configured with one DNS server, or two. That single
choice is wrong most of the time.

- The fastest resolver is different on every network. The one that wins on your
  home connection is not the one that wins on hotel Wi-Fi or on a phone hotspot.
- If it stops answering, name resolution stops with it. Most operating systems
  and apps fail over slowly or not at all, and many app settings accept only one
  server address.
- Picking a resolver by hand means measuring it, and re-measuring it every time
  the network changes. Nobody does that.

## The idea

Stop picking. Send each query to every resolver at the same time and use
whichever answer arrives first.

That turns a configuration problem into a race. The winner is, by definition,
the resolver that is fastest and reachable at this moment on this network, and
it is re-decided on every query. A resolver that is down or blackholed costs
nothing: it just loses. Redundancy comes free, because the pool is large.

Read [docs/how-it-works.md](docs/how-it-works.md) for the mechanics, including
why the resolvers are split into groups and why the fastest answer is not always
the one you want.

## Install

One command. It downloads the project, verifies the resolver binary against the
checksum its author published, installs it as a boot daemon, and tests it.

```bash
curl -fsSL https://raw.githubusercontent.com/smk-labs/dnsrace/main/get.sh | sudo bash
```

Prefer to read a script before running it as root, which is a good habit:

```bash
curl -fsSL https://raw.githubusercontent.com/smk-labs/dnsrace/main/get.sh -o /tmp/get.sh && less /tmp/get.sh && sudo bash /tmp/get.sh
```

Re-running is safe and is also how you upgrade.

## Point things at it

The resolver answers on `127.0.0.1`. Nothing uses it until you say so.

Any app with a DNS server field takes `127.0.0.1` directly. That is usually the
better choice, because it changes one app instead of the whole machine.

To make macOS itself resolve through it, on every active network service:

```bash
sudo dnsrace system on
```

`sudo dnsrace system off` puts DHCP back. See
[docs/clients.md](docs/clients.md) for per-app notes and the one interaction
that can bite you.

## Everyday commands

```bash
dnsrace status          # is it up, does it answer, what is macOS using
dnsrace test github.com # time real cold-cache lookups through the resolver
dnsrace bench           # time all 61 upstreams individually, on this network
dnsrace logs -f         # watch the log
sudo dnsrace config     # edit the upstream list, then reload automatically
sudo dnsrace update     # reinstall the latest version
sudo dnsrace uninstall  # remove everything and restore DHCP DNS
```

## Adding your own resolvers

61 upstreams ship in the config already, which is plenty for the race to always
have a healthy winner. Add more if you want to, or delete any you do not like.

They live in exactly one place, `config/dnsproxy.yaml`, installed to
`/usr/local/etc/dnsproxy/dnsproxy.yaml`. There is no second list anywhere: even
the benchmark reads its targets out of that same file, so it can never drift.

```bash
sudo dnsrace config    # opens the file in $EDITOR, reloads the daemon on save
```

## What is installed

| Path | What |
|---|---|
| `/usr/local/bin/dnsproxy` | the resolver binary |
| `/usr/local/bin/dnsrace` | this CLI |
| `/usr/local/etc/dnsproxy/dnsproxy.yaml` | the config, the only upstream list |
| `/Library/LaunchDaemons/org.adguard.dnsproxy.plist` | keeps it running and starts it at boot |
| `/Library/LaunchDaemons/org.adguard.dnsproxy.logrotate.plist` | caps the log at 20 MB |
| `/Library/Logs/dnsproxy/dnsproxy.log` | the log |
| `/usr/local/share/dnsrace` | the installed copy, used by `update` and `uninstall` |

All of it is root owned, deliberately. A daemon running as root must not be able
to execute a binary or read a config that an unprivileged user can rewrite,
which is why nothing here lives in a Homebrew prefix.

## Credit and license

The resolver doing the actual work is
[AdGuard dnsproxy](https://github.com/AdguardTeam/dnsproxy), an excellent piece
of software, released under Apache 2.0. This project is the configuration, the
packaging, and the operational glue around it. It installs the official release
binary and never rebuilds or patches it.

This project was vibe coded. It is a personal tool that solved a real problem
well enough to publish. Read the config before you trust it, and open an issue
if something is wrong.

MIT, see [LICENSE](LICENSE).
