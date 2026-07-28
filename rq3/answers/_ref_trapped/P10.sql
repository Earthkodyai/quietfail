SELECT d.id FROM documents d
WHERE d.category IN ('support','product')
ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 10
