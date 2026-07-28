SET LOCAL hnsw.iterative_scan = relaxed_order;
SET LOCAL hnsw.ef_search = 400;
SET LOCAL work_mem = '16MB';
SELECT d.id FROM documents d
WHERE d.category = 'archive'
ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1)
LIMIT 10
