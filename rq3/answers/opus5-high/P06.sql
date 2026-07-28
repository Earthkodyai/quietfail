SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 4;

CREATE INDEX documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX documents_emb_finance
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE category = 'finance';

CREATE INDEX documents_emb_legal
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE category = 'legal';

CREATE INDEX documents_emb_archive
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE category = 'archive';

CREATE INDEX documents_category_idx ON documents (category);

ANALYZE documents;

SET hnsw.ef_search = 100;
SET hnsw.iterative_scan = 'relaxed_order';
SET hnsw.max_scan_tuples = 20000;

SELECT d.id,
       d.title,
       d.category,
       d.embedding <=> q.embedding AS distance
FROM   documents d
CROSS JOIN LATERAL (
         SELECT embedding FROM search_queries WHERE id = 1
       ) AS q
ORDER  BY d.embedding <=> q.embedding
LIMIT  10;
