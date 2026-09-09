# systemd units for the deploy poller

Many hardened hosts have **no cron** - a timer is the only scheduler available.

## `/etc/systemd/system/<project>-deploy.service`

```ini
[Unit]
Description=Poll GitHub for new <project> tags and deploy
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
User=<project>-deploy
# The script needs the deploy user's own HOME: the staging clone, the
# .seen-tags state file and the git credential store all live there.
Environment=HOME=/home/<project>-deploy
ExecStart=/usr/local/bin/<project>-deploy
# NOT RemainAfterExit: a oneshot that stays "active" makes OnUnitActiveSec on
# the timer measure from the START of the last run, not its end.
```

## `/etc/systemd/system/<project>-deploy.timer`

```ini
[Unit]
Description=Check for new <project> tags every minute

[Timer]
OnBootSec=2min
# From the END of the last run, so a long build does not queue runs behind
# itself (the script's flock would drop them anyway, but this keeps the
# journal readable).
OnUnitActiveSec=1min
Unit=<project>-deploy.service

[Install]
WantedBy=timers.target
```

## Enabling

```bash
systemctl daemon-reload

# Seed the tag state WITHOUT deploying first. Skipping this deploys every
# existing tag at once and lets the last one win.
sudo -u <project>-deploy /usr/local/bin/<project>-deploy

systemctl enable --now <project>-deploy.timer
systemctl list-timers '<project>-deploy.timer' --no-pager
```

## Watching it

```bash
journalctl -u <project>-deploy -f      # needs sudo unless you are in adm / systemd-journal
systemctl status <project>-deploy.timer
```

## Making it generic across projects

If more than one project will use this, write **one** generic script taking the
project as an argument plus a systemd *template* unit, rather than a copy per
project:

- `/usr/local/bin/<org>-deploy <project>`
- `/etc/systemd/system/<org>-deploy@.service` - runs as `%i-deploy`, calls
  `/usr/local/bin/<org>-deploy %i`
- enable per project: `systemctl enable --now <org>-deploy@<project>.timer`

Per-project state then lives in that user's home (`.seen-tags-<project>`,
`<project>-src`) and per-project policy in `/etc/<org>-deploy/<project>.branch`.

**Before writing any of this, check whether it already exists.** Looking for a
per-project script name, not finding it, and concluding nothing was installed
led to a whole parallel poller being written for a project the shared one
already handled - two mechanisms racing for the same deploy directory.

```bash
ls /usr/local/bin/ | grep -i deploy
systemctl list-timers '*deploy*' --all --no-pager
ls /etc/sudoers.d/
```
