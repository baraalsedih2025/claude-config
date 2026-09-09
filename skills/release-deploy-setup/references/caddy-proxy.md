# The Caddy basic-auth reverse proxy

When the deployed app runs with its own authentication disabled, this proxy is
the **only** thing between it and the open internet. It is also the only
component that should publish a port on the real host.

## Caddyfile

```caddyfile
# Authenticating reverse proxy for <project>.
#
# The app runs with OIDC/auth disabled, so this proxy is the only gate. Do not
# publish the app's own port.
:<public-port> {
	basic_auth {
		{$BASIC_AUTH_USER} {$BASIC_AUTH_HASH}
	}

	# flush_interval -1 disables response buffering. Required for Server-Sent
	# Events / streaming endpoints: with buffering, short replies pass but
	# longer ones sit in the buffer and the UI appears to hang forever.
	reverse_proxy <upstream-name>:<port> {
		flush_interval -1
	}
}
```

Generate the hash with `caddy hash-password`; pass user and hash as environment
variables, never inline in the file.

## Address the upstream by NAME, never by IP

This is the single most repeated failure in this deployment.

A container's bridge IP is reassigned on reboot. A Caddyfile that hardcodes it
keeps starting fine and returns **502 "connection refused"** for every
request - which reads like the app being down, not like the proxy pointing at
nothing. Worse, the old address gets reassigned to an *unrelated* container, so
the proxy may reach something that answers.

The default `bridge` network has **no DNS**. So:

```bash
docker network create <shared-net>            # once, if it does not exist
docker network connect <shared-net> <proxy-container>
docker network connect <shared-net> <upstream-container>
docker exec <proxy-container> caddy reload --config /etc/caddy/Caddyfile
```

Then `reverse_proxy <upstream-name>:<port>` follows the upstream across
restarts forever. Joining a network works on a *running* container - no
recreate needed.

Verify the upstream by name, not just that the proxy answers:

```bash
docker exec <proxy-container> wget -S -O /dev/null http://<upstream-name>:<port>/ 2>&1 | grep HTTP/
```

A 401 from `localhost:<public-port>` only proves the auth gate works; it never
touches the upstream.

## socat relays have the same bug, and it is worse

Where a `socat` relay is used to reach a service across networks
(`alpine/socat tcp-listen:X,fork,reuseaddr tcp-connect:<ip>:Y`), the target IP
is baked into the **container command** - so a stale one cannot be fixed by
editing a file and reloading. It needs the container recreated. Prefer joining
a shared user-defined network and using a name here too.

Audit for stale targets after any reboot:

```bash
docker ps -q | xargs -r docker inspect \
  -f '{{.Name}} {{.Config.Cmd}}' | grep -E '172\.[0-9]+\.[0-9]+\.[0-9]+'
```

## Mounting the Caddyfile

Bind-mounted single files are attached **by inode**. `sed -i` writes a new file
and silently detaches the mount - the container keeps serving the old content
while the file on disk looks correct. Rewrite in place (`cat > file`) or
recreate the container. Always confirm what the container actually sees:

```bash
docker exec <proxy-container> cat /etc/caddy/Caddyfile
```

## Restart policy

Give the proxy - and any DinD container beneath it - `restart: unless-stopped`.
A container with `restart=no` stays down after a host reboot and takes every
stack behind it with it.
