-- PostgreSQL-only document store. Apply explicitly after schema.sql.
CREATE TABLE IF NOT EXISTS wcf_documents (
  app_id VARCHAR(128) NOT NULL,
  env_id VARCHAR(128) NOT NULL,
  collection_name VARCHAR(128) NOT NULL,
  doc_id VARCHAR(128) NOT NULL,
  body JSONB NOT NULL CHECK (jsonb_typeof(body) = 'object'),
  PRIMARY KEY (app_id, env_id, collection_name, doc_id),
  CHECK (body ? '_id' AND jsonb_typeof(body->'_id') = 'string' AND body->>'_id' = doc_id)
);
CREATE INDEX IF NOT EXISTS wcf_documents_body_idx ON wcf_documents USING GIN (body);

-- Opaque local/S3 object versions; file content is never stored in SQL.
CREATE TABLE IF NOT EXISTS wcf_files (
  app_id VARCHAR(128) NOT NULL,
  env_id VARCHAR(128) NOT NULL,
  file_id VARCHAR(64) NOT NULL,
  owner_id VARCHAR(128) NOT NULL,
  cloud_path TEXT NOT NULL,
  object_key VARCHAR(32) NOT NULL,
  size_bytes BIGINT NOT NULL,
  sha256 VARCHAR(64) NOT NULL,
  PRIMARY KEY (app_id, env_id, file_id)
);
