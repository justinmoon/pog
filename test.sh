#!/usr/bin/env bash
set -e

PGDATA="$PWD/.pgdata"
export PGHOST="localhost"

cleanup() {
  echo "Stopping PostgreSQL..."
  pg_ctl -D "$PGDATA" stop -m fast 2>/dev/null || true
}
trap cleanup EXIT

# Initialize if needed
if [ ! -d "$PGDATA" ]; then
  echo "Initializing PostgreSQL..."
  initdb -D "$PGDATA" --no-locale --encoding=UTF8
  echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
  echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
  # Allow password auth for postgres user
  echo "host all postgres 127.0.0.1/32 md5" >> "$PGDATA/pg_hba.conf"
  echo "host all postgres ::1/128 md5" >> "$PGDATA/pg_hba.conf"
fi

# Start PostgreSQL
echo "Starting PostgreSQL..."
pg_ctl -D "$PGDATA" start -l "$PGDATA/postgres.log"
sleep 1

# Create postgres role if needed
if ! psql -h localhost -d template1 -tAc "SELECT 1 FROM pg_roles WHERE rolname='postgres'" | grep -q 1; then
  echo "Creating postgres role..."
  psql -h localhost -d template1 -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"
fi

# Create test database if needed
if ! psql -h localhost -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw gleam_pog_test; then
  echo "Creating test database..."
  createdb -h localhost -O postgres gleam_pog_test
  psql -h localhost gleam_pog_test -c "CREATE TABLE IF NOT EXISTS cats (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    is_cute BOOLEAN NOT NULL,
    colors TEXT[] NOT NULL,
    last_petted_at TIMESTAMP NOT NULL,
    birthday DATE NOT NULL
  );"
fi

# Run tests
echo "Running tests..."
gleam test
