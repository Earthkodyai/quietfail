-- ============================================================
-- Q03 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ (สูตรข้อ 6)
--
-- รัน:  psql ... -f /sql/q03_checker_states.sql
--
-- ตัวตรวจของ Q03 **ไม่ต้องรู้เฉลย** — แค่เทียบ
--   "จำนวนแถวที่เข้าเงื่อนไข filter" กับ "จำนวนแถวที่ query คืนมาจริง"
-- ถ้ามีแถวเข้าเงื่อนไขเกิน k แต่ได้คืนไม่ถึง k = ผลหายไปแน่นอน
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP INDEX IF EXISTS qf_q03_idx;
DROP TABLE IF EXISTS qf_q03;

\qecho '=== สถานะ 1: ยังไม่มีตาราง -> CANNOT_CHECK ==='
\i /sql/score.sql

\qecho ''
\qecho '=== สร้างตารางและ hnsw index ==='
CREATE TABLE qf_q03 (id int PRIMARY KEY, grp int, embedding vector(384));
INSERT INTO qf_q03 SELECT id, id % 1000, embedding FROM qf_corpus;
ANALYZE qf_q03;
CREATE INDEX qf_q03_idx ON qf_q03 USING hnsw (embedding vector_cosine_ops);

SELECT count(*) AS แถวที่เข้าเงื่อนไข_grp_lt_10 FROM qf_q03 WHERE grp < 10;

\qecho ''
\qecho '=== สถานะ 2: ค่าเริ่มต้น (iterative_scan = off) -> DETECTED ==='
\qecho '    มีแถวเข้าเงื่อนไข 1,000 แถว แต่ขอ 10 จะได้ไม่ครบ'
\i /sql/score.sql

\qecho ''
\qecho '=== เปิดทางแก้ให้ครบ: iterative_scan + work_mem ==='
\qecho '    (เปิด iterative_scan อย่างเดียวไม่พอ — วัดแล้วใน q03_filter_after_scan.sql)'
SET hnsw.iterative_scan = relaxed_order;
SET work_mem = '4MB';

\qecho ''
\qecho '=== สถานะ 3: ทางแก้ครบ -> NOT_DETECTED ==='
\i /sql/score.sql

\qecho ''
\qecho '=== เก็บกวาด ==='
RESET hnsw.iterative_scan;
RESET work_mem;
DROP INDEX IF EXISTS qf_q03_idx;
DROP TABLE IF EXISTS qf_q03;
RESET temp_file_limit;

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');

SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
