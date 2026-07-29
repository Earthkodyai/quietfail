WITH q AS (
    SELECT embedding
    FROM search_queries
    WHERE id = 1
),
ranked AS (
    SELECT
        d.id,
        d.category,
        d.title,
        d.embedding,
        d.embedding <=> q.embedding AS distance,
        (d.category = 'archive') AS preferred
    FROM documents d
    CROSS JOIN q
)
SELECT
    id,
    category,
    title,
    1 - distance AS cosine_similarity
FROM ranked
ORDER BY
    preferred DESC,   -- archive ก่อน
    distance ASC       -- ใกล้ที่สุด
LIMIT 10;
