CREATE INDEX documents_embedding_hnsw_idx
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX documents_category_idx ON documents (category);

ANALYZE documents;

SET hnsw.iterative_scan = relaxed_order;
SET hnsw.ef_search = 100;
SET hnsw.max_scan_tuples = 100000;

WITH knn AS MATERIALIZED (
    SELECT
        d.id,
        d.category,
        d.title,
        d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
    FROM documents d
    WHERE d.category = 'archive'
    ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
    LIMIT 10
)
SELECT
    id,
    category,
    title,
    distance,
    1 - distance AS cosine_similarity
FROM knn
ORDER BY distance;
