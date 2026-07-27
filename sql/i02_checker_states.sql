-- ============================================================
-- I02 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ (สูตรข้อ 6)
--
-- รัน:  psql ... -f /sql/i02_checker_states.sql
--
-- ตัวตรวจของ I02 ไม่ได้อ่าน catalog — มัน**วัด recall สดๆ** เทียบ index
-- กับ exact search ที่ได้จาก `enable_indexscan = off`
-- เพราะร่องรอยว่า "build ตอนข้อมูลไม่เป็นตัวแทน" ไม่มีอยู่ใน catalog ที่ไหนเลย
-- (`pg_class.reltuples` ของ index ถูก ANALYZE เขียนทับทันที — probe ยืนยันแล้ว)
--
-- ⚠️ ไม่แตะ qf_corpus — อ่านอย่างเดียว
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';
SET ivfflat.probes = 1;

DROP INDEX IF EXISTS qf_i02_idx;
DROP TABLE IF EXISTS qf_i02;
CREATE TABLE qf_i02 (id int PRIMARY KEY, cluster_id int, embedding vector(384));

\qecho '=== สถานะ 1: มีตารางแต่ยังไม่มี ivfflat index -> CANNOT_CHECK ==='
\qecho '    (กฎเหล็กข้อ 10 — ไม่มีอะไรให้เทียบ ไม่ใช่ "ผ่าน")'
INSERT INTO qf_i02 SELECT id, cluster_id, embedding FROM qf_corpus;
\i /sql/score.sql

\qecho ''
\qecho '=== สร้าง index บนข้อมูลครบ (วิธีที่ถูก) ==='
CREATE INDEX qf_i02_idx ON qf_i02 USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

\qecho ''
\qecho '=== สถานะ 2: index build บนข้อมูลครบ -> NOT_DETECTED ==='
\qecho '    recall ควรอยู่ราว 0.72-0.81 ซึ่งคือฐานปกติของ probes=1 (Q04 · I04)'
\i /sql/score.sql

\qecho ''
\qecho '=== สร้างใหม่แบบผิด: build ตอนมีแค่ 5 กลุ่มจาก 50 แล้วค่อยเติมให้ครบ ==='
DROP INDEX qf_i02_idx;
DELETE FROM qf_i02 WHERE cluster_id >= 5;
SELECT count(*) AS rows_at_build, count(DISTINCT cluster_id) AS clusters_at_build FROM qf_i02;

CREATE INDEX qf_i02_idx ON qf_i02 USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

INSERT INTO qf_i02 SELECT c.id, c.cluster_id, c.embedding FROM qf_corpus c
WHERE NOT EXISTS (SELECT 1 FROM qf_i02 x WHERE x.id = c.id);
ANALYZE qf_i02;

SELECT count(*) AS rows_now, count(DISTINCT cluster_id) AS clusters_now FROM qf_i02;

\qecho ''
\qecho '=== สถานะ 3: index build บนตัวอย่างเอียง -> DETECTED ==='
\qecho '    ข้อมูลในตารางเหมือนสถานะ 2 ทุกแถว ต่างแค่ตอนที่ build index'
\i /sql/score.sql

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_i02_idx;
DROP TABLE IF EXISTS qf_i02;
RESET ivfflat.probes;
RESET temp_file_limit;

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');

SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
