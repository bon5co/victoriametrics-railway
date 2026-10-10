#!/bin/sh
# Railway wrapper for VictoriaMetrics single-node: login from the first request,
# ingestion that stops before the volume fills, scrape targets from the environment.
set -eu

DATA=/victoria-metrics-data
CONF=/etc/victoria-metrics
USER_NAME="${VM_USERNAME:-admin}"
LISTEN_PORT="${PORT:-8428}"

if [ -z "${VM_PASSWORD:-}" ]; then
  echo "FATAL: VM_PASSWORD is not set. VictoriaMetrics would serve its query and write APIs open to the internet; refusing to start." >&2
  exit 1
fi

# The volume is mounted root-owned; the server runs as nobody.
mkdir -p "$DATA" "$CONF"
chown 65534:65534 "$DATA"

# Stop accepting writes (stay readable) when free space drops below 10% of the volume,
# instead of running the disk to zero. Override with MIN_FREE_BYTES.
if [ -z "${MIN_FREE_BYTES:-}" ]; then
  total_kb="$(df -Pk "$DATA" | awk 'NR==2 {print $2}')"
  MIN_FREE_BYTES="$(( total_kb * 1024 / 10 ))"
fi

# Retention: a bare number is months, or use a suffix (30d, 12w, 1y).
RETENTION="${VM_RETENTION_PERIOD:-12}"

# Cap Go's scheduler to the container's CPU quota; hosts report their own core count.
if [ -z "${GOMAXPROCS:-}" ] && [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [ "${quota:-max}" != "max" ] && [ -n "${period:-}" ]; then
    n=$(( (quota + period - 1) / period ))
    [ "$n" -ge 1 ] && export GOMAXPROCS="$n"
  fi
fi

# Scrape config. VM_SCRAPE_CONFIG replaces it entirely; otherwise build one from
# SCRAPE_TARGETS (comma-separated host:port, e.g. api.railway.internal:3000).
SCRAPE_ARGS=""
SCRAPE_DESC="none"
METRICS_PATH="${METRICS_PATH:-/metrics}"
if [ -n "${VM_SCRAPE_CONFIG:-}" ]; then
  printf '%s\n' "$VM_SCRAPE_CONFIG" > "$CONF/scrape.yml"
  SCRAPE_DESC="VM_SCRAPE_CONFIG (custom)"
elif [ -n "${SCRAPE_TARGETS:-}" ]; then
  {
    echo "scrape_configs:"
    echo "  - job_name: railway"
    echo "    metrics_path: '${METRICS_PATH}'"
    echo "    static_configs:"
    echo "      - targets:"
    echo "$SCRAPE_TARGETS" | tr ',' '\n' | while read -r t; do
      t="$(echo "$t" | tr -d ' ')"
      [ -n "$t" ] && echo "          - '$t'"
    done
  } > "$CONF/scrape.yml"
  SCRAPE_DESC="$SCRAPE_TARGETS"
fi
if [ -f "$CONF/scrape.yml" ]; then
  chmod 600 "$CONF/scrape.yml"
  chown 65534:65534 "$CONF/scrape.yml"
  SCRAPE_ARGS="-promscrape.config=$CONF/scrape.yml"
fi

echo "railway-victoriametrics: user=${USER_NAME} port=${LISTEN_PORT} retention=${RETENTION} minFree=${MIN_FREE_BYTES}B targets=${SCRAPE_DESC} gomaxprocs=${GOMAXPROCS:-auto}" >&2
echo "railway-victoriametrics: data dir owner=$(stat -c %u:%g "$DATA") free=$(df -Pk "$DATA" | awk 'NR==2 {print $4}')KB" >&2

# shellcheck disable=SC2086
exec su-exec 65534:65534 /usr/local/bin/victoria-metrics-prod \
  -storageDataPath="$DATA" \
  -retentionPeriod="$RETENTION" \
  -storage.minFreeDiskSpaceBytes="$MIN_FREE_BYTES" \
  -httpListenAddr=":${LISTEN_PORT}" \
  -httpAuth.username="$USER_NAME" \
  -httpAuth.password="$VM_PASSWORD" \
  -selfScrapeInterval=30s \
  $SCRAPE_ARGS \
  "$@"
