SELECT id FROM documents
WHERE embedding IS NULL OR vector_norm(embedding) = 0
