CREATE INDEX documents_legal_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WHERE category = 'legal';

SELECT id,
       title,
       embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents
WHERE category = 'legal'
ORDER BY embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 20;
