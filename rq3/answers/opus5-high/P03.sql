SELECT
    d.id,
    d.category,
    d.title,
    d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents d
ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 100;
