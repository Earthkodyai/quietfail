CREATE INDEX documents_emb_cos_idx ON documents USING hnsw (embedding vector_cosine_ops)
