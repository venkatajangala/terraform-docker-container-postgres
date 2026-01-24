-- Initialize pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Optional: Create a sample vector table for testing
CREATE TABLE IF NOT EXISTS items (
    id BIGSERIAL PRIMARY KEY,
    name TEXT,
    embedding vector(1536)
);

-- Create an index for faster similarity searches
CREATE INDEX IF NOT EXISTS idx_items_embedding ON items USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Verify pgvector is installed
SELECT 'pgvector extension initialized successfully' as status;
