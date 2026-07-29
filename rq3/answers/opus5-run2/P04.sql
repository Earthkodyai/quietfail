CREATE INDEX documents_legal_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WHERE category = 'legal';

SELECT
    d.id,
    d.title,
    d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents d
WHERE d.category = 'legal'
ORDER BY distance
LIMIT 20;
