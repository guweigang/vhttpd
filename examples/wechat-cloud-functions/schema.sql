-- Apply explicitly to the application's database; no automatic schema writes.
-- Compatible with MySQL and PostgreSQL.
CREATE TABLE IF NOT EXISTS wcf_users (
  user_id VARCHAR(64) PRIMARY KEY,
  app_id VARCHAR(128) NOT NULL,
  open_id VARCHAR(128) NOT NULL,
  union_id VARCHAR(128) NOT NULL,
  display_name VARCHAR(128) NOT NULL
);
CREATE TABLE IF NOT EXISTS wcf_sessions (
  token_hash VARCHAR(64) PRIMARY KEY,
  app_id VARCHAR(128) NOT NULL,
  user_id VARCHAR(64) NOT NULL,
  open_id VARCHAR(128) NOT NULL,
  union_id VARCHAR(128) NOT NULL,
  expires_ms BIGINT NOT NULL
);
