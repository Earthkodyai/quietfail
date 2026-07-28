SELECT d.id FROM documents d
ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 100
