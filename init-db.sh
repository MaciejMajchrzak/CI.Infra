#!/bin/bash
# Creates additional databases needed by platform services.
# Runs once on first postgres startup (docker-entrypoint-initdb.d).
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    SELECT 'CREATE DATABASE ci_keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_keycloak')\gexec
    SELECT 'CREATE DATABASE ci_tenants'  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_tenants')\gexec
    SELECT 'CREATE DATABASE ci_users'    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_users')\gexec
EOSQL
