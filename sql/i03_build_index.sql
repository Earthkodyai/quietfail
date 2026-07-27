-- ============================================================
-- I03 — build vector index หนึ่งรอบ (เลือกได้ว่า CONCURRENTLY หรือไม่)
--
-- รัน:  psql ... -v concurrently=no  -f /sql/i03_build_index.sql
--       psql ... -v concurrently=yes -f /sql/i03_build_index.sql
--
-- แยกเป็นไฟล์ .sql เพราะกฎใน CLAUDE.md ข้อ 2:
-- ห้ามฝัง SQL ที่มี quote ซับซ้อนใน bash -c (E19, E26)
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';

\if :{?concurrently}
\else
\set concurrently no
\endif

SET temp_file_limit = '2GB';

-- ให้ build ช้าพอที่จะสังเกตการบล็อกได้
-- 64MB คือค่าของโปรไฟล์ fragile อยู่แล้ว และ I05 วัดไว้ว่า build ~60 วินาที
SET maintenance_work_mem = '64MB';

DROP INDEX IF EXISTS qf_i03_idx;

\if :concurrently
CREATE INDEX CONCURRENTLY qf_i03_idx ON qf_corpus USING hnsw (embedding vector_cosine_ops);
\else
CREATE INDEX qf_i03_idx ON qf_corpus USING hnsw (embedding vector_cosine_ops);
\endif
