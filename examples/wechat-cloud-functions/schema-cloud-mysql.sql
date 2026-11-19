-- MySQL 8.0.16+; JSON checks and transactions require InnoDB.
CREATE TABLE IF NOT EXISTS wcf_documents (
  app_id VARCHAR(128) NOT NULL,
  env_id VARCHAR(128) NOT NULL,
  collection_name VARCHAR(128) NOT NULL,
  doc_id VARCHAR(128) NOT NULL,
  body JSON NOT NULL,
  PRIMARY KEY (app_id, env_id, collection_name, doc_id),
  CHECK (JSON_TYPE(body) = 'OBJECT'),
  CHECK (JSON_CONTAINS_PATH(body, 'one', '$._id') = 1),
  CHECK (JSON_TYPE(JSON_EXTRACT(body, '$._id')) = 'STRING'),
  CHECK (JSON_UNQUOTE(JSON_EXTRACT(body, '$._id')) = doc_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
