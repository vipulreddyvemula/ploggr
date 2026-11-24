\set ON_ERROR_STOP on
\getenv app_password PLOGGR_DB_PASSWORD
\getenv scaler_password PLOGGR_SCALER_PASSWORD

-- Connect as the server administrator to postgres. These names are private to Ploggr.
SELECT 'CREATE ROLE ploggr_field LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ploggr_field') \gexec
SELECT 'CREATE ROLE ploggr_field_scaler LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ploggr_field_scaler') \gexec
ALTER ROLE ploggr_field PASSWORD :'app_password' CONNECTION LIMIT 15;
ALTER ROLE ploggr_field_scaler PASSWORD :'scaler_password' CONNECTION LIMIT 4;

SELECT 'CREATE DATABASE ploggr_field'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'ploggr_field') \gexec
REVOKE CONNECT, TEMPORARY ON DATABASE ploggr_field FROM PUBLIC;
GRANT CONNECT ON DATABASE ploggr_field TO ploggr_field, ploggr_field_scaler;
\connect ploggr_field
CREATE EXTENSION IF NOT EXISTS postgis;
GRANT USAGE, CREATE ON SCHEMA public TO ploggr_field;
