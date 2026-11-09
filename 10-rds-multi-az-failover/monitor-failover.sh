#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?DB_ENDPOINT is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

LOG_FILE="${1:-$HOME/lab10-failover.log}"
MAX_SECONDS=600

echo "timestamp,status,resolved_ip,details" > "$LOG_FILE"

echo "Starting RDS failover monitoring"
echo "Endpoint: $DB_ENDPOINT"
echo "Log file: $LOG_FILE"

end=$((SECONDS + MAX_SECONDS))

while ((SECONDS < end)); do

    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    resolved_ip=$(getent ahostsv4 "$DB_ENDPOINT" \
      | awk 'NR==1 {print $1}')

    resolved_ip="${resolved_ip:-unresolved}"

    if output=$(psql \
       "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=3 application_name=lab10-failover-monitor" \
       -X -A -t -v ON_ERROR_STOP=1 \
       -c "SELECT 1;" 2>&1); then

        status="SUCCESS"
        details="query_ok"

    else

        status="FAILURE"
        details=$(printf '%s' "$output" \
          | tr '\n,' '  ' \
          | cut -c 1-100)

    fi

    printf '%s,%s,%s,%s\n' \
      "$timestamp" \
      "$status" \
      "$resolved_ip" \
      "$details" >> "$LOG_FILE"

    echo "$timestamp | $status | $resolved_ip"

    sleep 3
done

echo "Monitoring finished."
