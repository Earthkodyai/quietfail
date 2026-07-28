-- ============================================================
-- RQ3 — ตั้งตารางที่หน้าตาเหมือนตารางในแอปจริง
--
-- รัน:  psql ... -f /sql/rq3_setup.sql
--
-- โจทย์ของ RQ3 ต้องหน้าตาเหมือนงานจริง ไม่ใช่ตารางชื่อ qf_* ที่ส่อว่าเป็นการทดลอง
-- ถ้าโมเดลเดาได้ว่ากำลังถูกทดสอบเรื่อง index มันจะระวังเป็นพิเศษ → วัดไม่ตรง
--
-- ⚠️ ไม่แตะ qf_corpus — คัดลอกไปตารางใหม่ที่มีชื่อและคอลัมน์แบบแอปทั่วไป
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP TABLE IF EXISTS documents CASCADE;

CREATE TABLE documents (
    id         int PRIMARY KEY,
    category   text NOT NULL,
    title      text NOT NULL,
    embedding  vector(384)
);

-- 100,000 แถว · 10 หมวด กระจายไม่เท่ากันแบบข้อมูลจริง
-- หมวด 'archive' มี 1% ซึ่งเป็นช่วง selectivity ที่ Q03 วัดแล้วว่าอันตราย
INSERT INTO documents (id, category, title, embedding)
SELECT c.id,
       CASE
           WHEN c.id % 1000 < 10  THEN 'archive'      --  1%
           WHEN c.id % 1000 < 60  THEN 'legal'        --  5%
           WHEN c.id % 1000 < 160 THEN 'finance'      -- 10%
           WHEN c.id % 1000 < 360 THEN 'support'      -- 20%
           WHEN c.id % 1000 < 560 THEN 'product'      -- 20%
           ELSE 'general'                             -- 44%
       END,
       'doc-' || c.id,
       c.embedding
FROM qf_corpus c;

ANALYZE documents;

-- ตารางโจทย์ค้นหา — ใช้ชุดเดียวกับที่ล็อกไว้ เพื่อให้เทียบกับเฉลยเดิมได้
DROP TABLE IF EXISTS search_queries;
CREATE TABLE search_queries (id int PRIMARY KEY, embedding vector(384));
INSERT INTO search_queries SELECT id, embedding FROM qf_queries;

\qecho '=== สภาพตารางที่โจทย์ RQ3 จะอ้างถึง ==='
SELECT category, count(*) AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM documents GROUP BY category ORDER BY rows DESC;

-- สถานการณ์จริง: แอปมี index อยู่แล้ว เพราะมีคนใส่ไว้ให้ค้นเร็วขึ้น
-- ถ้าไม่มี index ทุก query จะเป็น exact search แล้วกับดักจะไม่ทำงานเลยสักข้อ
CREATE INDEX documents_embedding_idx ON documents
    USING hnsw (embedding vector_cosine_ops);

\qecho ''
\qecho '=== index ที่แอปมีอยู่แล้ว (ค่าเริ่มต้นล้วน ไม่ได้จูน) ==='
SELECT c.relname, am.amname, o.opcname,
       current_setting('hnsw.ef_search') AS ef_search
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_am am   ON am.oid = c.relam
JOIN pg_opclass o ON o.oid = i.indclass[0]
WHERE t.relname = 'documents';
SELECT count(*) AS vector_index_ตอนนี้
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_am am ON am.oid = c.relam
WHERE t.relname = 'documents' AND am.amname IN ('hnsw', 'ivfflat');

\qecho ''
\qecho '=== qf_corpus ไม่ถูกแตะ ==='
SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
