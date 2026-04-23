#!/bin/bash
set -e

DATA_DIR="/var/lib/postgresql/data"
MASTER_HOST="postgres-0.postgres.$NAMESPACE.svc.cluster.local"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-}"

if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
  if [ "$HOSTNAME" = "postgres-0" ]; then
    echo "[$(date)] Initializing MASTER..."

    # Шаг 1: Инициализация кластера
    initdb -D "$DATA_DIR"

    # Шаг 2: Подготовка SQL-скрипта
    cat > "$DATA_DIR/create_user.sql" <<EOF
-- Установка пароля для суперпользователя
ALTER USER postgres PASSWORD '$POSTGRES_PASSWORD';
EOF

    if [ -n "$POSTGRES_USER" ] && [ "$POSTGRES_USER" != "postgres" ]; then
      # Создаём пользователя с правом репликации
      cat >> "$DATA_DIR/create_user.sql" <<EOF
CREATE USER "$POSTGRES_USER" WITH PASSWORD '$POSTGRES_PASSWORD' REPLICATION;
EOF
      if [ -n "$POSTGRES_DB" ]; then
        cat >> "$DATA_DIR/create_user.sql" <<EOF
CREATE DATABASE "$POSTGRES_DB" OWNER "$POSTGRES_USER";
GRANT ALL PRIVILEGES ON DATABASE "$POSTGRES_DB" TO "$POSTGRES_USER";
EOF
      fi
    elif [ -n "$POSTGRES_DB" ]; then
      cat >> "$DATA_DIR/create_user.sql" <<EOF
CREATE DATABASE "$POSTGRES_DB";
EOF
    fi

    # Шаг 3: Настройка pg_hba.conf
    cat > "$DATA_DIR/pg_hba.conf" <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    replication     all             0.0.0.0/0               md5
host    all             all             0.0.0.0/0               md5
EOF

    # Шаг 4: Настройка postgresql.conf
    cat > "$DATA_DIR/postgresql.conf" <<EOF
listen_addresses = '*'
port = 5432
wal_level = replica
max_wal_senders = 10
max_replication_slots = 5
hot_standby = on
logging_collector = off
log_statement = none
EOF

    # Шаг 5: Временный запуск для применения SQL
    echo "[$(date)] Starting temporary PostgreSQL instance..."
    pg_ctl -D "$DATA_DIR" -l "$DATA_DIR/init.log" start

    echo "[$(date)] Waiting for PostgreSQL via Unix socket..."
    until pg_isready -U postgres; do
      sleep 1
    done

    echo "[$(date)] Applying user/database setup..."
    psql -U postgres -f "$DATA_DIR/create_user.sql"

    echo "[$(date)] Stopping temporary instance..."
    pg_ctl -D "$DATA_DIR" -m fast stop

    echo "[$(date)] MASTER initialized with user '$POSTGRES_USER' (REPLICATION enabled) and DB '$POSTGRES_DB'."

  else
    # === ИНИЦИАЛИЗАЦИЯ РЕПЛИКИ ===
    echo "[$(date)] Initializing REPLICA from master ($MASTER_HOST)..."

    until PGPASSWORD="$POSTGRES_PASSWORD" pg_isready -h "$MASTER_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do
      echo "[$(date)] Waiting for master to accept connections..."
      sleep 5
    done

    echo "[$(date)] Running pg_basebackup..."
    PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup \
      -h "$MASTER_HOST" \
      -U "$POSTGRES_USER" \
      -D "$DATA_DIR" \
      -P -R -X stream --wal-method=stream

    # Убедиться, что hot_standby включён
    if ! grep -q "^[[:space:]]*hot_standby[[:space:]]*=" "$DATA_DIR/postgresql.conf"; then
      echo "hot_standby = on" >> "$DATA_DIR/postgresql.conf"
    fi

    echo "[$(date)] Replica initialized successfully."
  fi
else
  echo "[$(date)] Data directory already exists. Skipping initialization."
fi

echo "[$(date)] Init script completed. PostgreSQL will be started by the main container."
