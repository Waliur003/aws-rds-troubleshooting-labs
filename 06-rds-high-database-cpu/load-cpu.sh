#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?Set DB_ENDPOINT first}"

echo "Starting Lab 06 CPU workload"

rm -f "$HOME/lab06-cpu.pids"

for worker in 1 2; do
  (
    end=$((SECONDS + 120))

    while ((SECONDS < end)); do
      psql \
        "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require application_name=lab06-cpu-load" \
        -v ON_ERROR_STOP=1 \
        -c "
          SELECT SUM(sqrt(g::double precision))
          FROM generate_series(1, 100000000) AS g;
        " > /dev/null 2>&1 || true
    done
  ) &

  echo "$!" >> "$HOME/lab06-cpu.pids"
done

echo "CPU workload started with 2 workers."
echo "Workers are limited to approximately 120 seconds."
echo "Use lab06-cpu.pids to stop the workers."
