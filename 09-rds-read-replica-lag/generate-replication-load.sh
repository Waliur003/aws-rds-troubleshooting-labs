#!/usr/bin/env bash
set -euo pipefail

: "${PRIMARY_ENDPOINT:?PRIMARY_ENDPOINT is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

for batch in $(seq 1 8); do

    echo "Inserting batch $batch"

    psql \
      "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require application_name=lab09-write-load" \
      -v ON_ERROR_STOP=1 \
      -c "
      INSERT INTO replication_test (batch_no, payload)
      SELECT
          $batch,
          gen_random_bytes(1024)
      FROM generate_series(1, 10000);
      "

    echo "Committed batch $batch"
done

echo "Replication workload finished."
