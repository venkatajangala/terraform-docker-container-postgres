-- Initialize pg_stat_statements and pgvector extension

-- 1. Enable the extension
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Create a table with a vector column (e.g., 3 dimensions)
CREATE TABLE items (id serial PRIMARY KEY, embedding vector(3));

-- 3. Insert data
INSERT INTO items (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');

-- 4. Query using vector operations (e.g., cosine distance)
SELECT id, embedding <=> '[1,2,3]' AS distance FROM items ORDER BY distance LIMIT 2;

-- 5. Verify pgvector is installed
SELECT * FROM pg_available_extensions WHERE name = 'vector';
SELECT 'pgvector extension initialized successfully' as status;

-- 6. Verify pg_stat_statements is installed
SELECT * FROM pg_available_extensions WHERE name = 'pg_stat_statements';
SELECT 'pg_stat_statements extension initialized successfully' as status;

-- 7. Ensure shared_preload_libraries is set correctly
ALTER SYSTEM SET shared_preload_libraries = vector, pg_stat_statements;

-- 8. Reload configuration to apply changes
SELECT pg_reload_conf();

-- 9. Confirm the setting
SHOW shared_preload_libraries;
SELECT 'shared_preload_libraries set successfully' as status;

-- End of initialization script
