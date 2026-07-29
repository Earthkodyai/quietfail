SELECT
    id,
    category,
    title,
    CASE
        WHEN embedding IS NULL THEN 'NULL'
        WHEN vector_dims(embedding) <> 384 THEN 'INVALID_DIMENSIONS'
        WHEN embedding <=> embedding IS NULL THEN 'INVALID_VALUES'
        ELSE 'UNKNOWN'
    END AS issue
FROM documents
WHERE
    embedding IS NULL
    OR vector_dims(embedding) <> 384
    OR embedding <=> embedding IS NULL;
