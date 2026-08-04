#!/bin/bash
# Creates all databases needed by platform services.
# Runs once on first postgres startup (docker-entrypoint-initdb.d).
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    SELECT 'CREATE DATABASE ci_keycloak'          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_keycloak')\gexec
    SELECT 'CREATE DATABASE ci_tenants'           WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_tenants')\gexec
    SELECT 'CREATE DATABASE ci_users'             WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_users')\gexec
    SELECT 'CREATE DATABASE ci_country_config'    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_country_config')\gexec
    SELECT 'CREATE DATABASE ci_billing'           WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_billing')\gexec
    SELECT 'CREATE DATABASE ci_workflow'          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_workflow')\gexec
    SELECT 'CREATE DATABASE ci_devtools'          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_devtools')\gexec
    SELECT 'CREATE DATABASE ci_notifications'     WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_notifications')\gexec
    SELECT 'CREATE DATABASE ci_documents'         WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_documents')\gexec
    SELECT 'CREATE DATABASE ci_search'            WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_search')\gexec
    SELECT 'CREATE DATABASE ci_public_discovery'  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_public_discovery')\gexec
    SELECT 'CREATE DATABASE ci_parties'           WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_parties')\gexec
    SELECT 'CREATE DATABASE ci_invoicing'         WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_invoicing')\gexec
    SELECT 'CREATE DATABASE ci_legal'             WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_legal')\gexec
    SELECT 'CREATE DATABASE ci_payments'          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_payments')\gexec
    SELECT 'CREATE DATABASE ci_booking'           WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_booking')\gexec
    SELECT 'CREATE DATABASE ci_catalog'           WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_catalog')\gexec
    SELECT 'CREATE DATABASE ci_warehouse'         WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_warehouse')\gexec
    SELECT 'CREATE DATABASE ci_hr'                WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_hr')\gexec
    SELECT 'CREATE DATABASE ci_tasks'             WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_tasks')\gexec
    SELECT 'CREATE DATABASE ci_accounting'        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_accounting')\gexec
    SELECT 'CREATE DATABASE ci_marketing'         WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_marketing')\gexec
    SELECT 'CREATE DATABASE ci_ksef'              WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_ksef')\gexec
    SELECT 'CREATE DATABASE ci_openbanking'       WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ci_openbanking')\gexec
EOSQL
