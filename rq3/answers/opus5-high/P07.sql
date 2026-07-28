SELECT d.id, d.title, d.category,
       d.embedding <=> (SELECT q.embedding FROM search_queries q WHERE q.id = 1) AS distance
FROM documents d
WHERE d.category = 'finance'
ORDER BY d.embedding <=> (SELECT q.embedding FROM search_queries q WHERE q.id = 1)
LIMIT 50;

CREATE INDEX documents_embedding_finance_hnsw
ON documents USING hnsw (embedding vector_cosine_ops)
WHERE category = 'finance';
