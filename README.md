# corepost-agent

`corepost-agent` is a Linux post-boot component that periodically polls the CorePost server and applies the returned policy.

The agent is intentionally implemented on a minimal stack:
- `systemd` to run as a service;
- `curl` to call the server;
- `openssl` to compute HMAC signatures.

## Server Contract

The agent uses:
- `POST /agent/poll` to fetch `currentState` and `action`;
- `POST /agent/ack` to record an acknowledgement event after applying (or skipping) an action.

Both endpoints require HMAC headers:
- `X-DeviceId`
- `X-Timestamp` (unix seconds)
- `X-Signature` (hex HMAC-SHA256 of `METHOD\nPATH\nTIMESTAMP`, keyed by `COREPOST_DEVICE_SECRET`)

## Configuration

The systemd unit reads an optional environment file:
- `/etc/corepost-agent.env`

Minimal required keys:
- `COREPOST_SERVER_URL`
- `COREPOST_DEVICE_ID`
- `COREPOST_DEVICE_SECRET`

See `dist/corepost-agent.env.example`.

## Installation Layout

The installer expects these files to be available in `dist/`:
- `dist/corepost-agent.service`
- `dist/corepost-agent.sh`
- `dist/corepost-agent.env.example`

A typical target layout:
- `/etc/systemd/system/corepost-agent.service`
- `/usr/local/lib/corepost-agent/corepost-agent.sh`
- `/etc/corepost-agent.env` (0600)

## Actions

The server returns one of: `observe`, `logout`, `lock_session`, `shutdown`.

Notes:
- `shutdown` is gated by `COREPOST_AGENT_ENABLE_SHUTDOWN=1` to avoid accidental VM shutdown during demos.
- `lock_session` and `logout` use `loginctl` when available.

## Local Smoke (Once)

You can run a single poll cycle and exit:

```sh
sudo COREPOST_SERVER_URL="..." \
  COREPOST_DEVICE_ID="..." \
  COREPOST_DEVICE_SECRET="..." \
  /usr/local/lib/corepost-agent/corepost-agent.sh --once
```
