---
name: agents
description: >-
  How a Claude agent on any of Mohammad's machines identifies itself, discovers
  the other agents/sessions that exist, and talks to them through the shipyard
  bus (with the Windows hub as the central relay). Use whenever you need to
  coordinate with another session, find who is working on what, hand off to or
  ask another machine, wake a peer, or get something a different agent owns.
---

# Identifying yourself and talking to the other agents

You are one of several Claude sessions running across Mohammad's machines (his
Windows box plus RAG, MOH, cor2dev2, 209, runpod, and others over SSH). They all
share a message bus — "shipyard bus" — so agents talk to each other and run work
on each other's hosts directly, instead of Mohammad relaying messages by hand.
The bus tools are prefixed `bus_`.

## 1. Who am I?

At session start a hook injects your bus identity into the conversation: your
**bus name** (`bus-XXXX`, derived from your session id) and your **session_id**.
Register once, early, declaring the SSH host you are working on and a short role:

```
bus_register({name:"bus-XXXX", session_id:"<sid>", host:"<ssh host, or omit>", role:"<short role>"})
```

Registering makes you addressable three ways — by bus **name**, by **host**, and
by **role** — and lets peers wake you. If you don't know your name/sid, read the
SessionStart bus notice; it prints both and the exact call to run.

## 2. Who else exists?

```
bus_roster()
```

Lists every recent session: bus name, the host each one owns, its role, how stale
it is, unread counts — plus the SSH hosts reachable **from this machine**. Call it
before assuming you must do another machine's work yourself: someone may already
own it.

## 3. How do I talk to them?

- **A live session owns it** (it shows in the roster) → `bus_ask({to, question, timeout_s})`
  to ask and block for a reply, or `bus_send({to, text})` to drop a note.
  `to` may be a bus **name**, a **role**, an **SSH host**, or `*` to broadcast.
- **They're idle** → the message is durable; their next turn surfaces it (a hook
  shows unread mail). `bus_send`/`bus_ask` also hand you a ready `send_message()`
  "doorbell" call to wake that session right now.
- **Answer a question you received** → `bus_reply({corr, text})` (the `corr` id is
  shown next to the question in your inbox).
- **Read your own mail** → `bus_inbox()`.

Never ask the human to carry a message between sessions — that is what these are for.

## 4. Running work on another machine (not just messaging)

- **The machine is reachable from here** (it's in `bus_roster`'s SSH-hosts line)
  → `bus_run_on({host, prompt})` spawns a fresh, throwaway agent on that host over
  SSH and returns its answer. It has **no memory** of your conversation — make the
  prompt self-contained.
- **The machine is NOT reachable from here** (e.g. cor2dev2 or a tunnel-only host
  seen from MOH) → `bus_relay({host, prompt, wait_s})`. The job queues; the Windows
  hub runs it on that host and you read the result with `bus_relay_result({id})`.

## The Windows hub is the center ("this device")

Mohammad's Windows box is the only node that can reach **every** machine (via its
SSH tunnels and netbird). It hosts the durable bus, and its scheduled relay is
what lets an agent on one machine reach a machine it cannot touch directly. So:

- `bus_roster()` tells you what **this** machine can reach right now.
- Anything this machine can't reach, route through the hub with `bus_relay`.
- The hub is also where cross-machine coordination converges — if you're unsure
  who should do something, ask on the bus rather than guessing.

## Etiquette

- Register with a clear, specific role so peers know who's who and who owns what.
- Keep prompts to remote/throwaway agents self-contained (they start blank).
- Prefer asking the session that already owns a host/topic (`bus_ask`) over
  re-deriving its work yourself.
- One job per remote call; don't chain unrelated tasks.

## Related

- The `fleet` skill covers the host reachability map and the standing safety rules
  (e.g. 209 runs as a different person's account; cor2dev2 is inbound-only). Read
  it when the task is "do something on <host>"; read this one when the task is
  "coordinate with / reach another agent."
