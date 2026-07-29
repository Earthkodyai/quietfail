SELECT
    d.id,
    d.category,
    d.title,
    d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS cosine_distance,
    1 - (d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)) AS cosine_similarity
FROM documents d
WHERE d.embedding IS NOT NULL
ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 100;
