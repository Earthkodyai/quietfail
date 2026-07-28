SELECT d.id FROM documents d
WHERE (d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)) < 0.5
LIMIT 10
