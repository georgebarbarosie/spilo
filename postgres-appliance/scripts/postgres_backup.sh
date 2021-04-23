#!/bin/bash

function log
{
    echo "$(date "+%Y-%m-%d %H:%M:%S.%3N") - $0 - $*"
}

[[ -z $1 ]] && echo "Usage: $0 PGDATA" && exit 1

log "I was called as: $0 $*"


readonly PGDATA=$1
DAYS_TO_RETAIN=$BACKUP_NUM_TO_RETAIN

readonly IN_RECOVERY=$(psql -tXqAc "select pg_is_in_recovery()")
if [[ $IN_RECOVERY == "f" ]]; then
    [[ "$WALG_BACKUP_FROM_REPLICA" == "true" ]] && log "Cluster is not in recovery, not running backup" && exit 0
elif [[ $IN_RECOVERY == "t" ]]; then
    [[ "$WALG_BACKUP_FROM_REPLICA" != "true" ]] && log "Cluster is in recovery, not running backup" && exit 0
else
    log "ERROR: Recovery state unknown: $IN_RECOVERY" && exit 1
fi

# leave at least 2 days base backups before creating a new one
[[ "$DAYS_TO_RETAIN" -lt 2 ]] && DAYS_TO_RETAIN=2

if [[ "$USE_WALG_BACKUP" == "true" ]]; then
    readonly WAL_E="wal-g"
    [[ -z $WALG_BACKUP_COMPRESSION_METHOD ]] || export WALG_COMPRESSION_METHOD=$WALG_BACKUP_COMPRESSION_METHOD
    export PGHOST=/var/run/postgresql
else
    readonly WAL_E="wal-e"

    # Ensure we don't have more workes than CPU's
    POOL_SIZE=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || 1)
    [ "$POOL_SIZE" -gt 4 ] && POOL_SIZE=4
    POOL_SIZE=(--pool-size "$POOL_SIZE")
fi

BEFORE_BY_TIME=""
BEFORE_BY_COUNT=""
INDEX=0
# count how many backups 
BACKUPS_IN_TIME=""

readonly NOW=$(date +%s -u)
while read -r last_modified name; do
    last_modified=$(date +%s -ud "$last_modified")
    ((INDEX=INDEX+1))
    if [ $(((NOW-last_modified)/86400)) -ge $DAYS_TO_RETAIN ]; then
        [ -z "$BACKUPS_IN_TIME" ] && ((BACKUPS_IN_TIME=INDEX))
        if [ -z "$BEFORE_BY_TIME" ] || [ "$last_modified" -gt "$BEFORE_TIME" ]; then
            BEFORE_TIME=$last_modified
            BEFORE_BY_TIME=$name

        fi
        if [ $INDEX -ge $DAYS_TO_RETAIN ] || [ -z "$BEFORE_BY_COUNT" ]; then
            # this is the last backup to keep
            BEFORE_BY_COUNT=$name
        fi
    fi
done < <($WAL_E backup-list 2> /dev/null | tail -n +2 | awk '{ print $2 " " $1 }' | sort -r)

BEFORE=""
if [ -z "$BEFORE_BY_COUNT" ]; then
  log "Less than $DAYS_TO_RETAIN backups are present, not deleting any"
else
  if [ -z "$BACKUPS_IN_TIME" ] || [ $BACKUPS_IN_TIME -lt $DAYS_TO_RETAIN ]; then
      BEFORE=$BEFORE_BY_COUNT
  else
      BEFORE=$BEFORE_BY_TIME
  fi
fi

if [ ! -z "$BEFORE" ]; then
    if [[ "$USE_WALG_BACKUP" == "true" ]]; then
        $WAL_E delete before FIND_FULL "$BEFORE" --confirm
    else
        $WAL_E delete --confirm before "$BEFORE"
    fi
fi

# push a new base backup
log "producing a new backup"
# We reduce the priority of the backup for CPU consumption
exec nice -n 5 $WAL_E backup-push "$PGDATA" "${POOL_SIZE[@]}"
