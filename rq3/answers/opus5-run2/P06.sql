SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 7;

CREATE INDEX CONCURRENTLY idx_documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX CONCURRENTLY idx_documents_emb_general
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200)
    WHERE category = 'general';

CREATE INDEX CONCURRENTLY idx_documents_emb_product
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200)
    WHERE category = 'product';

CREATE INDEX CONCURRENTLY idx_documents_emb_support
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200)
    WHERE category = 'support';

CREATE INDEX CONCURRENTLY idx_documents_emb_finance
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200)
    WHERE category = 'finance';

CREATE INDEX CONCURRENTLY idx_documents_emb_legal
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200)
    WHERE category = 'legal';

CREATE INDEX CONCURRENTLY idx_documents_emb_archive
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200)
    WHERE category = 'archive';

ANALYZE documents;

SET hnsw.ef_search = 100;
SET hnsw.iterative_scan = 'relaxed_order';
SET hnsw.max_scan_tuples = 20000;

SELECT d.id,
       d.title,
       d.embedding <=> $1::vector AS distance
FROM documents d
WHERE d.category = 'legal'
ORDER BY d.embedding <=> $1::vector
LIMIT 10;
