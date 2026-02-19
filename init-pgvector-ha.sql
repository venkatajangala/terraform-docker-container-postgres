-- Initialize pgvector extension on all PostgreSQL nodes
-- This script is idempotent and safe to run on all nodes (primary and replicas)

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Create a sample vector table for testing (on primary only - replicates to replicas)
-- Check if we're on primary before creating
DO $$
BEGIN
    IF pg_is_in_recovery() = false THEN
        -- Create the items table with 1536-dimensional vectors (OpenAI embeddings)
        CREATE TABLE IF NOT EXISTS items (
            id BIGSERIAL PRIMARY KEY,
            name TEXT,
            content TEXT,
            embedding vector(1536),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        -- Create an index for faster similarity searches
        CREATE INDEX IF NOT EXISTS idx_items_embedding ON items 
            USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

        -- Add a comment to document the table
        COMMENT ON TABLE items IS 'Sample table for vector similarity search with pgvector';
        COMMENT ON COLUMN items.embedding IS 'OpenAI embedding (1536 dimensions)';
    END IF;
END $$;

-- Verify pgvector is installed
SELECT 'pgvector extension initialized successfully on PostgreSQL node' as status;
