-- ============================================================
-- L02 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ (สูตรข้อ 6)
--
-- รัน:  psql ... -f /sql/l02_checker_states.sql
--
-- ตัวตรวจของ L02 ถาม k แถว **โดยไม่มี WHERE เลย** แล้วเทียบกับจำนวนแถวที่ยังอยู่
-- นี่คือจุดที่แยกจาก Q03 — Q03 ตัวกรองเห็นได้ในโค้ด ส่วน L02 มองไม่เห็น
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP INDEX IF EXISTS qf_l02_idx;
DROP TABLE IF EXISTS qf_l02;

\qecho '=== สถานะ 1: ยังไม่มีตาราง -> CANNOT_CHECK ==='
\i /sql/score.sql

\qecho ''
\qecho '=== สร้างตาราง + hnsw index แล้วลบ 90% โดยไม่ vacuum ==='
CREATE TABLE qf_l02 (id int PRIMARY KEY, embedding vector(384));
INSERT INTO qf_l02 SELECT id, embedding FROM qf_corpus;
ANALYZE qf_l02;
CREATE INDEX qf_l02_idx ON qf_l02 USING hnsw (embedding vector_cosine_ops);
ALTER TABLE qf_l02 SET (autovacuum_enabled = false);

DELETE FROM qf_l02 WHERE id % 10 <> 0;
SELECT count(*) AS แถวที่ยังอยู่ FROM qf_l02;

\qecho ''
\qecho '=== สถานะ 2: ลบแล้วยังไม่ vacuum -> DETECTED ==='
\qecho '    ตารางมี 10,000 แถวที่ยังอยู่ แต่ขอ 10 จะได้ไม่ครบ'
\i /sql/score.sql

\qecho ''
\qecho '=== VACUUM — ทางแก้ที่วัดแล้วว่าได้ผล ==='
VACUUM qf_l02;

\qecho ''
\qecho '=== สถานะ 3: หลัง VACUUM -> NOT_DETECTED ==='
\i /sql/score.sql

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_l02_idx;
DROP TABLE IF EXISTS qf_l02;
RESET temp_file_limit;

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');

SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
