SELECT d.id,
       d.category,
       d.title,
       d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents d
WHERE d.category IN ('support', 'product')
ORDER BY distance
LIMIT 10;

CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON documents (category);

SET hnsw.iterative_scan = relaxed_order;
