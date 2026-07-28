SET LOCAL hnsw.ef_search = 400;
SELECT d.id FROM documents d
WHERE (d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)) < 0.5
ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 10
