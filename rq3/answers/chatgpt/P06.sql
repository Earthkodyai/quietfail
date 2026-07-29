CREATE INDEX documents_embedding_cosine_idx
ON documents
USING hnsw (embedding vector_cosine_ops);

ANALYZE documents;

SELECT
    d.id,
    d.category,
    d.title,
    1 - (d.embedding <=> q.embedding) AS cosine_similarity
FROM search_queries AS q
CROSS JOIN LATERAL (
    SELECT
        id,
        category,
        title,
        embedding
    FROM documents
    ORDER BY embedding <=> q.embedding
    LIMIT 20
) AS d
WHERE q.id = $1
ORDER BY cosine_similarity DESC;
