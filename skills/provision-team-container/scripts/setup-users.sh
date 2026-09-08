#!/bin/bash
# TEMPLATE — team users + workspace permissions. Idempotent; runs on every boot so it
# survives a container recreate. Edit the placeholders before use:
#   USER_A / UID_A, USER_B / UID_B   — the team's users
#   WS                                — the workspace mount path (e.g. /workspace-team2)
#   LEAD                              — user who gets cross-access to everyone's folder
#   INHERITED                         — accounts baked into the base image to lock out

USER_A=nada;    UID_A=1006
USER_B=jararah; UID_B=1007
WS=/workspace-team2
LEAD=$USER_A
INHERITED="ezzmousa ateeq omar majed bara kareem"

command -v setfacl >/dev/null 2>&1 || { apt-get update && apt-get install -y acl; }

# Team users: passwordless (empty password). For key auth, add authorized_keys instead.
id "$USER_A" >/dev/null 2>&1 || useradd -m -s /bin/bash -u "$UID_A" "$USER_A"
id "$USER_B" >/dev/null 2>&1 || useradd -m -s /bin/bash -u "$UID_B" "$USER_B"
passwd -d "$USER_A"; passwd -d "$USER_B"

# Lock any OTHER account inherited from the base image so it can't log in here.
for u in $INHERITED; do
  id "$u" >/dev/null 2>&1 && { passwd -l "$u"; usermod -s /usr/sbin/nologin "$u"; }
done

# Base ownership: each user writes OWN folder, reads the WHOLE workspace.
chown root:root      "$WS"            && chmod 755 "$WS"
chown -R "$USER_A":"$USER_A" "$WS/${USER_A^}" && chmod 755 "$WS/${USER_A^}"
chown -R "$USER_B":"$USER_B" "$WS/${USER_B^}" && chmod 755 "$WS/${USER_B^}"

# Asymmetric cross-access: LEAD gets rwx on the OTHER user's folder via ACL.
# Default ACL (-d) keeps files created later writable by LEAD.
setfacl -R  -m u:"$LEAD":rwx "$WS/${USER_B^}"
setfacl -R -d -m u:"$LEAD":rwx "$WS/${USER_B^}"
