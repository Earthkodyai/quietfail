SELECT
    d.id,
    d.category,
    d.title,
    d.embedding <=> q.embedding AS cosine_distance
FROM documents AS d
CROSS JOIN (
    SELECT embedding
    FROM search_queries
    WHERE id = 1
) AS q
WHERE d.embedding <=> q.embedding < 0.5
ORDER BY cosine_distance ASC
LIMIT 10;
