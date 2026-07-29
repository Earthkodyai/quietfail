SELECT
    d.id,
    d.category,
    d.title,
    1 - (d.embedding <=> q.embedding) AS similarity
FROM documents AS d
CROSS JOIN (
    SELECT embedding
    FROM search_queries
    WHERE id = 1
) AS q
ORDER BY d.embedding <=> q.embedding
LIMIT 10;
