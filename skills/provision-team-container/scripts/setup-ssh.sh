#!/bin/bash
# TEMPLATE — team container SSH setup.
# Passwordless team users, but ROOT requires a password (root password passed via
# the ROOT_PASSWORD env var on `docker run -e ROOT_PASSWORD=...`).
#
# For KEY-BASED auth instead of empty passwords: set `PasswordAuthentication no` and
# `PubkeyAuthentication yes`, drop the PermitEmptyPasswords line, and drop each user's
# key into ~/.ssh/authorized_keys in setup-users.sh.

chmod 000 /usr/bin/scp   # disable scp, matching the reference setup

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'               /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords yes/'     /etc/ssh/sshd_config

# Root MUST require a password — do NOT run `passwd -d root`.
[ -n "$ROOT_PASSWORD" ] && echo "root:$ROOT_PASSWORD" | chpasswd

service ssh restart
