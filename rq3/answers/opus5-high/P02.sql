CREATE INDEX ON documents (category);

SELECT d.id,
       d.title,
       d.embedding <=> (SELECT embedding FROM search_queries WHERE id = 1) AS cosine_distance
FROM   documents d
WHERE  d.category = 'archive'
ORDER  BY cosine_distance
LIMIT  10;
