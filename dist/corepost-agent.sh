#!/bin/sh
set -eu

log() { printf '[corepost-agent] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

now_unix() { date +%s; }

trim_trailing_slash() { printf '%s' "$1" | sed 's:/*$::'; }

json_get_str() {
  # Minimal JSON field extractor for flat response objects.
  # Works for `"key":"value"` fields.
  key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

json_get_int() {
  # Works for `"key":123` fields.
  key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | head -n 1
}

compute_signature_hex() {
  secret="$1"
  method="$2"
  path="$3"
  ts="$4"
  msg="$(printf '%s\n%s\n%s' "$method" "$path" "$ts")"
  # openssl output format: "SHA2-256(stdin)= <hex>"
  printf '%s' "$msg" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}'
}

http_post_signed() {
  base_url="$1"
  path="$2"
  device_id="$3"
  secret="$4"
  body="${5:-}"

  ts="$(now_unix)"
  sig="$(compute_signature_hex "$secret" "POST" "$path" "$ts")"

  url="$(trim_trailing_slash "$base_url")$path"
  if [ -n "$body" ]; then
    curl -fsS \
      --connect-timeout "${COREPOST_AGENT_CONNECT_TIMEOUT_SECONDS:-5}" \
      --max-time "${COREPOST_AGENT_MAX_TIME_SECONDS:-20}" \
      -X POST "$url" \
      -H "Content-Type: application/json" \
      -H "X-DeviceId: $device_id" \
      -H "X-Timestamp: $ts" \
      -H "X-Signature: $sig" \
      --data-binary "$body"
  else
    curl -fsS \
      --connect-timeout "${COREPOST_AGENT_CONNECT_TIMEOUT_SECONDS:-5}" \
      --max-time "${COREPOST_AGENT_MAX_TIME_SECONDS:-20}" \
      -X POST "$url" \
      -H "X-DeviceId: $device_id" \
      -H "X-Timestamp: $ts" \
      -H "X-Signature: $sig"
  fi
}

http_post_signed_status() {
  # Like http_post_signed, but returns the HTTP status code and never fails fast.
  base_url="$1"
  path="$2"
  device_id="$3"
  secret="$4"
  body="$5"

  ts="$(now_unix)"
  sig="$(compute_signature_hex "$secret" "POST" "$path" "$ts")"
  url="$(trim_trailing_slash "$base_url")$path"

  tmp="$(mktemp)"
  code="$(
    curl -sS \
      --connect-timeout "${COREPOST_AGENT_CONNECT_TIMEOUT_SECONDS:-5}" \
      --max-time "${COREPOST_AGENT_MAX_TIME_SECONDS:-20}" \
      -o "$tmp" \
      -w '%{http_code}' \
      -X POST "$url" \
      -H "Content-Type: application/json" \
      -H "X-DeviceId: $device_id" \
      -H "X-Timestamp: $ts" \
      -H "X-Signature: $sig" \
      --data-binary "$body" || echo "000"
  )"
  rm -f "$tmp" >/dev/null 2>&1 || true
  printf '%s' "$code"
}

ack() {
  base_url="$1"
  device_id="$2"
  secret="$3"
  action="$4"
  status="$5"
  note="${6:-}"

  if [ -n "$note" ]; then
    note_json="$(printf '%s' "$note" | sed 's/\\/\\\\/g; s/\"/\\\\\"/g')"
    body="$(printf '{"action":"%s","status":"%s","note":"%s"}' "$action" "$status" "$note_json")"
  else
    body="$(printf '{"action":"%s","status":"%s"}' "$action" "$status")"
  fi

  code="$(http_post_signed_status "$base_url" "/agent/ack" "$device_id" "$secret" "$body")"
  if [ "$code" != "200" ]; then
    log "ack failed (http=$code) action=$action status=$status"
    return 1
  fi
  printf '%s\n' "$(now_unix)" >"$last_ack_file" 2>/dev/null || true
  return 0
}

apply_action() {
  action="$1"
  case "$action" in
    observe)
      return 0
      ;;
    lock_session)
      if command -v loginctl >/dev/null 2>&1; then
        loginctl lock-sessions >/dev/null 2>&1 || return 1
        return 0
      fi
      return 1
      ;;
    logout)
      if command -v loginctl >/dev/null 2>&1; then
        # Terminate all non-empty sessions.
        loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | while read -r sid; do
          [ -n "$sid" ] || continue
          loginctl terminate-session "$sid" >/dev/null 2>&1 || true
        done
        return 0
      fi
      return 1
      ;;
    shutdown)
      enabled="${COREPOST_AGENT_ENABLE_SHUTDOWN:-0}"
      if [ "$enabled" != "1" ]; then
        return 2
      fi
      delay="${COREPOST_AGENT_SHUTDOWN_DELAY_SECONDS:-10}"
      # Give a small delay so we can ACK before poweroff.
      ( sleep "$delay" >/dev/null 2>&1 || true; systemctl poweroff >/dev/null 2>&1 || true ) &
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_dirs() {
  state_dir="${COREPOST_AGENT_STATE_DIR:-/var/lib/corepost-agent}"
  mkdir -p "$state_dir"
  chmod 0700 "$state_dir" || true
  state_file="$state_dir/state.json"
  last_ack_file="$state_dir/last_ack_ts"
}

write_state() {
  current_state="$1"
  action="$2"
  status="$3"
  ts="$(now_unix)"
  printf '{"timestamp":%s,"currentState":"%s","action":"%s","status":"%s"}\n' "$ts" "$current_state" "$action" "$status" >"$state_file" || true
  chmod 0600 "$state_file" >/dev/null 2>&1 || true
}

poll_once() {
  base_url="$1"
  device_id="$2"
  secret="$3"

  resp="$(http_post_signed "$base_url" "/agent/poll" "$device_id" "$secret" "")"
  # Normalize to single line for our trivial parsers.
  resp_one="$(printf '%s' "$resp" | tr -d '\n')"

  current_state="$(printf '%s' "$resp_one" | json_get_str currentState)"
  action="$(printf '%s' "$resp_one" | json_get_str action)"
  heartbeat="$(printf '%s' "$resp_one" | json_get_int heartbeatIntervalSecond)"

  [ -n "$current_state" ] || die "bad poll response: missing currentState"
  [ -n "$action" ] || die "bad poll response: missing action"
  [ -n "$heartbeat" ] || heartbeat=""

  status="skipped"
  note=""

  if apply_action "$action"; then
    case "$action" in
      observe) status="skipped"; note="observe" ;;
      shutdown) status="applied"; note="shutdown scheduled" ;;
      *) status="applied" ;;
    esac
  else
    rc="$?"
    if [ "$rc" -eq 2 ]; then
      status="failed"
      note="shutdown disabled; set COREPOST_AGENT_ENABLE_SHUTDOWN=1 to allow"
    else
      status="failed"
    fi
  fi

  if [ "$action" = "observe" ]; then
    every="${COREPOST_AGENT_ACK_OBSERVE_EVERY_SECONDS:-60}"
    if [ "$every" -gt 0 ]; then
      last="0"
      if [ -f "$last_ack_file" ]; then
        last="$(cat "$last_ack_file" 2>/dev/null || echo 0)"
      fi
      now="$(now_unix)"
      if [ $((now - last)) -ge "$every" ]; then
        ack "$base_url" "$device_id" "$secret" "$action" "$status" "$note" || true
      fi
    fi
  else
    ack "$base_url" "$device_id" "$secret" "$action" "$status" "$note" || true
  fi
  write_state "$current_state" "$action" "$status"

  if [ -n "$heartbeat" ]; then
    printf '%s' "$heartbeat"
  else
    printf ''
  fi
}

main() {
  require_cmd curl
  require_cmd openssl
  require_cmd awk
  require_cmd sed
  require_cmd tr
  require_cmd date

  base_url="${COREPOST_SERVER_URL:-}"
  device_id="${COREPOST_DEVICE_ID:-}"
  secret="${COREPOST_DEVICE_SECRET:-}"
  [ -n "$base_url" ] || die "COREPOST_SERVER_URL is required"
  [ -n "$device_id" ] || die "COREPOST_DEVICE_ID is required"
  [ -n "$secret" ] || die "COREPOST_DEVICE_SECRET is required"

  ensure_dirs

  mode="${1:-run}"
  if [ "$mode" = "--once" ] || [ "$mode" = "once" ]; then
    poll_once "$base_url" "$device_id" "$secret" >/dev/null
    return 0
  fi

  backoff=1
  backoff_max="${COREPOST_AGENT_BACKOFF_MAX_SECONDS:-60}"
  min_poll="${COREPOST_AGENT_MIN_POLL_SECONDS:-2}"
  max_poll="${COREPOST_AGENT_MAX_POLL_SECONDS:-300}"

  while true; do
    interval_override="${COREPOST_AGENT_POLL_INTERVAL_SECONDS:-}"
    if interval="$(poll_once "$base_url" "$device_id" "$secret")"; then
      backoff=1
      if [ -n "$interval_override" ]; then
        sleep_for="$interval_override"
      elif [ -n "$interval" ]; then
        sleep_for="$interval"
      else
        sleep_for="${COREPOST_AGENT_DEFAULT_POLL_SECONDS:-10}"
      fi
      # Clamp.
      if [ "$sleep_for" -lt "$min_poll" ]; then sleep_for="$min_poll"; fi
      if [ "$sleep_for" -gt "$max_poll" ]; then sleep_for="$max_poll"; fi
      sleep "$sleep_for"
      continue
    fi

    log "poll failed; backing off (${backoff}s)"
    sleep "$backoff"
    backoff=$((backoff * 2))
    if [ "$backoff" -gt "$backoff_max" ]; then
      backoff="$backoff_max"
    fi
  done
}

main "$@"
