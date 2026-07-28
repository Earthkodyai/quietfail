SELECT
    CASE
        WHEN embedding IS NULL                          THEN 'null'
        WHEN vector_norm(embedding) = 0                 THEN 'zero_vector'
        WHEN vector_norm(embedding) < 1e-6              THEN 'near_zero_vector'
        WHEN (embedding <=> embedding) = 'NaN'::float8  THEN 'nan_cosine'
    END AS problem,
    count(*)
FROM documents
WHERE embedding IS NULL
   OR vector_norm(embedding) < 1e-6
   OR (embedding <=> embedding) = 'NaN'::float8
GROUP BY 1
ORDER BY 2 DESC;
