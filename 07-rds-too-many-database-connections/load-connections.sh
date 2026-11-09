#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?DB_ENDPOINT is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

echo "Starting five Lab 07 database sessions"

mkdir -p "$HOME/lab07-connections"

for worker in 1 2 3 4 5; do
    psql \
      "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require connect_timeout=5 application_name=lab07-worker-$worker" \
      -v ON_ERROR_STOP=1 \
      -c "SELECT pg_sleep(120);" \
      > "$HOME/lab07-connections/worker-$worker.log" \
      2>&1 &

    echo "$!" \
      > "$HOME/lab07-connections/worker-$worker.pid"

    echo "Started worker $worker"
done

echo "Five connection workers launched."
