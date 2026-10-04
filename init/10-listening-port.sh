#!/usr/bin/with-contenv bash
# Keep Sync's listening_port equal to the published port (SYNC_PORT in .env).
# Runs as root via /custom-cont-init.d before Sync starts.
# Never fails the container start: on any problem it warns and leaves sync.conf alone.
conf=/config/sync.conf
if [[ ! "${SYNC_PORT:-}" =~ ^[0-9]+$ ]]; then
    echo "SYNC_PORT is unset or not a number; leaving listening_port unchanged"
    exit 0
fi
if [[ ! -f "$conf" ]] || ! grep -qE '"listening_port"[[:space:]]*:' "$conf"; then
    echo "WARNING: no \"listening_port\" key in $conf; Sync may not listen on ${SYNC_PORT}"
    exit 0
fi
if ! sed -i -E "s/(\"listening_port\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${SYNC_PORT}/" "$conf"; then
    echo "WARNING: failed to update listening_port in $conf"
    exit 0
fi
chown abc:abc "$conf" # sed -i recreates the file as root
echo "listening_port set to ${SYNC_PORT}"
