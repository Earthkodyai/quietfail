-- ============================================================
-- quietfail-check — สร้างสภาพ "มีปัญหาครบทุกข้อ" ให้ตัวตรวจจับ
--
-- รัน:  psql ... -f /sql/qfcheck_states.sql          <- สร้างสภาพเสีย
--       python scripts/quietfail_check.py --docker   <- ต้องพบปัญหา
--       psql ... -f /sql/qfcheck_fix.sql             <- แก้ให้ถูก
--       python scripts/quietfail_check.py --docker   <- ต้องไม่พบปัญหา
--       psql ... -f /sql/qfcheck_teardown.sql        <- เก็บกวาด
--
-- ของส่งมอบต้องผ่านกฎเดียวกับตัวตรวจในงานวิจัย (สูตรข้อ 6):
-- **ตัวนับที่ไม่มีวันตอบลบ = ไม่ได้วัดอะไรเลย**
--
-- ใช้ตารางเล็ก 2,000 แถว เพราะ I01 · Q04 · Q06 ตรวจจาก catalog
-- ไม่ขึ้นกับขนาดข้อมูล จึงไม่ต้องรอ build 72 วินาทีแบบ corpus จริง
--
-- ⚠️ ไม่แตะ qf_corpus — อ่านอย่างเดียว
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP TABLE IF EXISTS qfcheck_demo CASCADE;
CREATE TABLE qfcheck_demo (id int PRIMARY KEY, embedding vector(384));
INSERT INTO qfcheck_demo SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 2000;

-- I01: index เป็น L2 แต่เดี๋ยวโค้ดจะค้นด้วย cosine
CREATE INDEX qfcheck_l2  ON qfcheck_demo USING hnsw (embedding vector_l2_ops);
-- Q04: lists = 100 แต่ probes จะเหลือ 1
CREATE INDEX qfcheck_ivf ON qfcheck_demo USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- V07: แถวที่ embedding ใช้งานไม่ได้
INSERT INTO qfcheck_demo VALUES (9000001, NULL),
                                (9000002, array_fill(0, ARRAY[384])::vector);
ANALYZE qfcheck_demo;

SELECT pg_stat_statements_reset();

SET hnsw.ef_search = 40;
SET ivfflat.probes = 1;

-- ยิง query ให้ pg_stat_statements จำรูปแบบไว้
--   ใช้ <=> (cosine) ทั้งที่ index เป็น L2  -> I01
--   LIMIT 100 > ef_search 40                -> Q06
\o /dev/null
SELECT id FROM qfcheck_demo
 ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) LIMIT 100;
-- Q02: query ที่ขาด ORDER BY + LIMIT
SELECT id FROM qfcheck_demo
 WHERE embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) < 0.5;
\o

\qecho '=== สภาพที่เตรียมไว้ — ควรถูกจับได้ทุกข้อ ==='
SELECT (SELECT count(*) FROM qfcheck_demo)                          AS แถวทั้งหมด,
       current_setting('hnsw.ef_search')                            AS ef_search,
       current_setting('ivfflat.probes')                            AS probes,
       (SELECT count(*) FROM qfcheck_demo WHERE embedding IS NULL)  AS null_rows;
