# corepost-agent

`corepost-agent` is a Linux post-boot component that runs under `systemd`, periodically polls the server, and applies the returned policy.

The implementation intentionally keeps the stack minimal:
- `systemd` (service manager)
- `curl` (HTTP client)
- `openssl` (HMAC)

## Contract

Endpoints:
- `POST /agent/poll` returns `currentState`, `action`, and `heartbeatIntervalSecond`
- `POST /agent/ack` records an acknowledgement after an action is applied/skipped/failed

Auth:
- Headers: `X-DeviceId`, `X-Timestamp` (unix seconds), `X-Signature` (hex)
- Signature: `HMAC-SHA256(deviceSecret, "METHOD\\nPATH\\nTIMESTAMP")`

## Config

Systemd reads an optional environment file:
- `/etc/corepost-agent.env` (0600)

Required keys:
- `COREPOST_SERVER_URL`
- `COREPOST_DEVICE_ID`
- `COREPOST_DEVICE_SECRET`

Tuning:
- `COREPOST_AGENT_POLL_INTERVAL_SECONDS` forces a fixed polling interval (preferred)
- `COREPOST_AGENT_HEARTBEAT_SECONDS` is a deprecated alias for `COREPOST_AGENT_POLL_INTERVAL_SECONDS`
- `COREPOST_AGENT_ACK_OBSERVE_EVERY_SECONDS` limits ACK spam for `observe` (default: 60)
- `COREPOST_AGENT_BACKOFF_MAX_SECONDS` caps exponential backoff on failures (default: 60)

See `dist/corepost-agent.env.example`.

## Install Layout

The installer downloads these artifacts from `dist/`:
- `dist/corepost-agent.service`
- `dist/corepost-agent.sh`
- `dist/corepost-agent.env.example`

Typical target paths:
- `/etc/systemd/system/corepost-agent.service`
- `/usr/local/lib/corepost-agent/corepost-agent.sh`
- `/etc/corepost-agent.env` (0600)

## Demo / QA

1. Install and start the service:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now corepost-agent.service
sudo systemctl status corepost-agent.service --no-pager
```

2. Observe behavior:

```sh
sudo journalctl -u corepost-agent.service -f
```

3. Validate that the server receives polls and ACKs (via admin event log on the server side).

## Limits

- JSON parsing is intentionally lightweight (no `jq`). It assumes the server response is a flat JSON object with stable field names.
- The server may request `shutdown` when the device is locked. This is gated by `COREPOST_AGENT_ENABLE_SHUTDOWN=1` to avoid accidental poweroff during demos.

