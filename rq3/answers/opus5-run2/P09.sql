SELECT
    count(*)                                                          AS total,
    count(*) FILTER (WHERE embedding IS NULL)                         AS null_embedding,
    count(*) FILTER (WHERE embedding IS NOT NULL
                       AND l2_norm(embedding) = 0)                    AS zero_vector,
    count(*) FILTER (WHERE embedding IS NOT NULL
                       AND l2_norm(embedding) > 0
                       AND l2_norm(embedding) < 1e-6)                 AS suspicious_tiny_norm,
    count(*) FILTER (WHERE embedding IS NOT NULL
                       AND vector_dims(embedding) <> 384)             AS wrong_dims
FROM documents;
