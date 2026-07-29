CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops)
  WHERE category = 'finance';

SELECT id,
       title,
       embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents
WHERE category = 'finance'
ORDER BY distance
LIMIT 50;
