SELECT d.id,
       d.category,
       d.title,
       d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS distance
FROM documents d
WHERE d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) < 0.5
ORDER BY distance
LIMIT 10;
