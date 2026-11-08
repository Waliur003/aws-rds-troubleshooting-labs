#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?Set DB_ENDPOINT first}"

for batch in $(seq 1 10); do
    echo "Starting batch $batch"

    psql \
      "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
      -v ON_ERROR_STOP=1 \
      -c "
      INSERT INTO lab05_storage_test (payload)
      SELECT gen_random_bytes(1024)
      FROM generate_series(1, 100000);
      "

    echo "Completed batch $batch"
done
