# Systemd Timer

A systemd timer is the recommended durable scheduler when you control the VM. Cron is still fine for quick setup, but systemd gives better status, logs, restart behavior, and auditable unit files.

This guide assumes:

- checkout: `/opt/goobreview/example`
- state directory: `/var/lib/goobreview/example`
- Unix user: `goobreview`
- config file: `/opt/goobreview/example/config/reviewer.env`

Adjust names and paths for each reviewer identity.

## Create The User And Directories

```bash
sudo useradd --system --create-home --shell /bin/bash goobreview
sudo mkdir -p /opt/goobreview/example /var/lib/goobreview/example
sudo chown -R goobreview:goobreview /opt/goobreview /var/lib/goobreview
```

Clone and configure the repo as that user, then authenticate `gh` and Gemini CLI as that same user.

## Install Unit Files

Copy the examples:

```bash
sudo cp deploy/systemd/goobreview.service.example /etc/systemd/system/goobreview.service
sudo cp deploy/systemd/goobreview.timer.example /etc/systemd/system/goobreview.timer
```

Edit paths and user names if needed:

```bash
sudo systemctl edit --full goobreview.service
sudo systemctl edit --full goobreview.timer
```

## Validate One Run

```bash
sudo systemctl daemon-reload
sudo systemctl start goobreview.service
sudo systemctl status goobreview.service
sudo journalctl -u goobreview.service -n 100 --no-pager
```

If this fails, fix the service before enabling the timer. Common causes:

- `gh` is not authenticated for the `goobreview` Unix user.
- Gemini CLI has not trusted `/opt/goobreview/example`.
- `config/reviewer.env` is missing or points to the wrong target repo.
- The checkout is dirty, so `sync-worktree.sh` refuses to run.

## Enable The Timer

```bash
sudo systemctl enable --now goobreview.timer
systemctl list-timers goobreview.timer
```

Watch logs:

```bash
sudo journalctl -u goobreview.service -f
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/sync.log
```

## Operations

Pause:

```bash
sudo systemctl disable --now goobreview.timer
```

Resume:

```bash
sudo systemctl enable --now goobreview.timer
```

Run immediately:

```bash
sudo systemctl start goobreview.service
```

Inspect timer state:

```bash
systemctl list-timers goobreview.timer
sudo systemctl status goobreview.timer
```

## Multiple Reviewers

Use one unit pair per reviewer identity:

```text
goobreview-alice.service
goobreview-alice.timer
goobreview-bob.service
goobreview-bob.timer
```

Each identity should have its own:

- Unix user
- checkout path
- `gh` authentication
- Gemini CLI authentication and trusted checkout
- state directory
- `config/reviewer.env`

