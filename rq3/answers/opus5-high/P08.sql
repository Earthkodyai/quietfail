CREATE INDEX IF NOT EXISTS documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX IF NOT EXISTS documents_category_idx ON documents (category);
ANALYZE documents;

SET hnsw.iterative_scan = strict_order;
SET hnsw.ef_search       = 100;
SET hnsw.max_scan_tuples = 100000;
SET hnsw.scan_mem_multiplier = 4;

SELECT d.id,
       d.category,
       d.title,
       d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS cosine_distance
FROM   documents d
WHERE  d.category = 'archive'
ORDER  BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT  10;
