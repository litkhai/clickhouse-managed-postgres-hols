#!/bin/bash
# Helpers sourced by steps 07-09: run SQL in the lab containers and wait for pg_cron runs.

PSQL=(docker exec -i pgch-postgres psql -U postgres -X)
CH=(docker exec -i pgch-clickhouse clickhouse-client)

# One value from PostgreSQL, unaligned.
pg_val() { "${PSQL[@]}" -tAc "$1"; }

# Highest runid of a job so far (0 if none).
last_runid() {
    pg_val "SELECT coalesce(max(d.runid), 0) FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = '$1'"
}

# wait_run <jobname> <after_runid> <status: succeeded|failed|any> <timeout_s> [<not_before: timestamptz>]
# Waits for the first finished run after <after_runid> with that status and prints "runid|status".
wait_run() {
    local job=$1 after=$2 want=$3 timeout=$4 not_before=${5:-'-infinity'} cond r i
    if [ "$want" = any ]; then cond="d.status IN ('succeeded', 'failed')"; else cond="d.status = '$want'"; fi
    for i in $(seq 1 "$timeout"); do
        r=$(pg_val "SELECT d.runid || '|' || d.status FROM cron.job_run_details d JOIN cron.job j USING (jobid)
                    WHERE j.jobname = '$job' AND d.runid > $after AND $cond AND d.start_time >= '$not_before'::timestamptz
                    ORDER BY d.runid LIMIT 1")
        if [ -n "$r" ]; then echo "$r"; return 0; fi
        sleep 1
    done
    echo "timeout|none"
    return 1
}

# Runs of a job after <after_runid>, as a table.
show_runs() {
    "${PSQL[@]}" -c "SELECT d.runid, d.status, split_part(d.return_message, E'\n', 1) AS return_message,
                            to_char(d.start_time, 'HH24:MI:SS.MS') AS started,
                            round(extract(epoch FROM d.end_time - d.start_time) * 1000) AS ms
                     FROM   cron.job_run_details d JOIN cron.job j USING (jobid)
                     WHERE  j.jobname = '$1' AND d.runid > $2 ORDER BY d.runid"
}
