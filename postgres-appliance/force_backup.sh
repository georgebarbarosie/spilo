#!/bin/sh
su postgres -c '
  /scripts/patroni_wait.sh -t 3600 -- envdir $WALE_ENV_DIR /scripts/postgres_backup.sh $PGDATA
'
