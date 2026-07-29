CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops)
WHERE category = 'archive';

SELECT d.id,
       d.title,
       d.embedding <=> q.embedding AS distance
FROM   documents d
CROSS  JOIN (SELECT embedding FROM search_queries WHERE id = 1) AS q
WHERE  d.category = 'archive'
ORDER  BY d.embedding <=> q.embedding
LIMIT  10;
