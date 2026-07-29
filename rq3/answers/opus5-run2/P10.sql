CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON documents (category);

SET hnsw.iterative_scan = relaxed_order;
SET hnsw.ef_search = 100;

WITH q AS (
    SELECT embedding
    FROM   search_queries
    WHERE  id = 1
)
SELECT d.id,
       d.category,
       d.title,
       d.embedding <=> q.embedding AS distance
FROM   documents d
CROSS  JOIN q
WHERE  d.category IN ('support', 'product')
ORDER  BY d.embedding <=> q.embedding
LIMIT  10;
