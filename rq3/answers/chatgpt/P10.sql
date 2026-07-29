SELECT
    d.id,
    d.category,
    d.title,
    1 - (d.embedding <=> q.embedding) AS cosine_similarity
FROM search_queries AS q
JOIN documents AS d
  ON d.category IN ('support', 'product')
WHERE q.id = 1
ORDER BY d.embedding <=> q.embedding
LIMIT 10;
