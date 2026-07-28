SELECT
    id,
    category,
    title,
    embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents
WHERE embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) < 0.5
ORDER BY embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 10;
