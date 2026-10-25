# Single-machine deployment

goobreview's engine on one Linux machine, swept by cron. This is how
goobreview-1 runs. Replace `USER` with the account that runs it; one account
owns everything below.

## Layout

| Path | What |
|---|---|
| `/opt/node` | Node 22 (root-owned) |
| `/opt/goobreview-v2/` | `dist/`, `node_modules/`, `package.json` and this directory's `goobreview` launcher |
| `~/bin/goobreview` | symlink to the launcher |
| `~/.config/goobreview/env` | App id, key path, work dir ([`env.example`](env.example)) |
| `~/.config/goobreview/config.json` | engine config: models, repos, policy, research |
| `~/.config/goobreview/auth.json` | model credentials, written by `goobreview auth login` |
| `/var/lib/goobreview/v2-work/` | snapshots, `sweep.lock`, `sweep.log` |
| `/var/lib/goobreview/research/` | research records, when `research.consent` is on |

Files under `~/.config/goobreview` and the App key are 0600.

## Install

1. Copy `engine/dist`, `engine/node_modules`, `engine/package.json` and the
   `goobreview` launcher into `/opt/goobreview-v2/`; `chmod +x` the launcher
   and symlink it to `~/bin/goobreview`.
2. Write `~/.config/goobreview/env` from [`env.example`](env.example) and the
   config file (see `engine/DESIGN.md`).
3. Sign in to each model in the chain from your own terminal:
   `goobreview auth login <provider>`, then `goobreview auth status`.
4. Check one PR without posting:
   `goobreview reconcile --repo owner/repo --pr N --dry-run`.
5. Install [`crontab.example`](crontab.example) with `crontab -e` and
   [`logrotate.example`](logrotate.example) as `/etc/logrotate.d/goobreview`.

## Repos

The engine reviews every repo the App can see, filtered by `repos` in the
config. To add one, add it to the App installation (GitHub: Settings →
Applications → the App → Configure) and to `repos`. Repos owned by another
account need that account to install the App; nothing comes back to you,
since the engine discovers installations itself. Per-repo required checks go
in `overrides`.

## Update

Build `engine/` (`npm ci && npm run build`), copy `dist/` over, and take the
sweep lock while swapping so no tick runs half-old, half-new code:

```sh
flock /var/lib/goobreview/v2-work/sweep.lock \
  sh -c 'rm -rf /opt/goobreview-v2/dist && tar -xzf dist.tgz -C /opt/goobreview-v2'
```

Copy `node_modules/` too when `package-lock.json` changed.
