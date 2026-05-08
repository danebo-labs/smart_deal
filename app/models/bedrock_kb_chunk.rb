# frozen_string_literal: true

# == Schema discovery — Bedrock Knowledge Base vector store (Aurora PostgreSQL)
#
# Manual gating: engineers obtain Aurora creds (Secrets Manager
# `storageConfiguration.rdsConfiguration.credentialsSecretArn` or IAM DB auth) and
# connect from a path that reaches the cluster network (VPN, bastion, SSM port-forward,
# same-VPC runner). Repo SSL bundle (RDS): `tmp/global-bundle.pem` via
# `curl -o tmp/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`
#
# Local preflight (2026-05-07): `psql` to the cluster writer hostname resolved to a
# **private** RDS address (172.31.x.x) and hit **connect timeout** from this workstation
# (no VPC path). Run the following where the cluster is reachable:
#
#   export RDSHOST="knowledgebasequickcreateaurora-fbe-auroradbcluster-odb6oljvi0w0.cluster-c7m2cecbyzsy.us-east-1.rds.amazonaws.com"
#   psql "host=$RDSHOST port=5432 dbname=Bedrock_Knowledge_Base_Cluster user=<user> \
#     sslmode=verify-full sslrootcert=./tmp/global-bundle.pem"
#   \\dt bedrock_integration.*
#   \\d+ bedrock_integration.bedrock_knowledge_base
#
# Pending until DB session works: confirm pgvector type / index on `embedding`, NOT NULL
# constraints, and exact **JSONB key names** Bedrock writes into `metadata` / `custommetadata`
# (e.g. whether `source_uri` / `x-amz-bedrock-kb-source-uri` / document id keys live there).
# Suggested:
#   SELECT DISTINCT jsonb_object_keys(metadata)    FROM bedrock_integration.bedrock_knowledge_base LIMIT 500;
#   SELECT DISTINCT jsonb_object_keys(custommetadata) FROM bedrock_integration.bedrock_knowledge_base LIMIT 500;
#
# Write permission smoke test (no durable write):
#   BEGIN;
#   INSERT INTO bedrock_integration.bedrock_knowledge_base (...)
#   VALUES (...);  -- match \\d column list & types; omit or use dummy vector with correct dim
#   ROLLBACK;
#
# -----------------------------------------------------------------------------
# Canonical field mapping from AWS API (run periodically to refresh):
#
#   aws bedrock-agent get-knowledge-base --knowledge-base-id VBB72VKABV --region us-east-1
#
# Snapshot captured 2026-05-07 for KB `VBB72VKABV` (`knowledge-base-multimodal`):
# - knowledgeBaseId: VBB72VKABV
# - storageConfiguration.type: RDS
# - databaseName: Bedrock_Knowledge_Base_Cluster
# - tableName (qualified): bedrock_integration.bedrock_knowledge_base
# - knowledgeBaseConfiguration.vectorKnowledgeBaseConfiguration.embeddingModelArn:
#     arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-2-multimodal-embeddings-v1:0
# - embeddingModelConfiguration.bedrockEmbeddingModelConfiguration.dimensions: **1024**
# - fieldMapping:
#     primaryKeyField:   id           -> column `id`
#     vectorField:       embedding    -> column `embedding` (vector dim 1024 per API)
#     textField:         chunks       -> column `chunks`
#     metadataField:     metadata     -> column `metadata` (JSONB; keys TBD via SQL above)
#     customMetadataField: custommetadata -> column `custommetadata` (JSONB; keys TBD)
#
# `source_uri` is **not** a top-level API fieldMapping key; expect it inside JSONB metadata
# once confirmed with \\d+ / sample rows.
# -----------------------------------------------------------------------------
#
# This class is a typed reference only (no DB connection at boot). Wire
# `ENV["BEDROCK_VECTOR_URL"]` (or a dedicated `database.yml` entry) before using ActiveRecord
# against the vector store.
#
class BedrockKbChunk < ApplicationRecord
  self.abstract_class = true

  KNOWLEDGE_BASE_ID = "VBB72VKABV"

  VECTOR_SCHEMA = "bedrock_integration"
  VECTOR_TABLE = "bedrock_knowledge_base"
  VECTOR_QUALIFIED_NAME = "#{VECTOR_SCHEMA}.#{VECTOR_TABLE}"

  EMBEDDING_DIMENSION = 1024

  COLUMN_PRIMARY_KEY = "id"
  COLUMN_EMBEDDING = "embedding"
  COLUMN_TEXT = "chunks"
  COLUMN_METADATA = "metadata"
  COLUMN_CUSTOM_METADATA = "custommetadata"
end
