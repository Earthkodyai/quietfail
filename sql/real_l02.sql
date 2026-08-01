-- ============================================================
-- L02 บน embedding จริง — แถวที่ถูกลบยังค้างใน index
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real_l02.sql
--
-- ต้องรัน real_load.sql ก่อน
--
-- ข้ออ้างที่ต้องตรวจ (บน corpus สังเคราะห์):
--   ตาย 40% -> ขอ 10 ได้ 10  ·  ตาย 50% -> ขอ 10 ได้ 0
--   **หน้าผาระหว่าง 40% กับ 50% และไม่มีทางลาดเลย**
--
-- 🔴 ผลที่ได้: **กลไกรอด แต่หน้าผาไม่รอด** — บนข้อมูลจริงได้ครบ 10 จนถึงตาย 80%
--    ที่ 90% ยังได้ 5 ไม่เคยถึง 0 -> ถอนข้ออ้างเรื่องหน้าผา
--    และ E43 พบภายหลังว่า iterative_scan + scan_mem_multiplier=32
--    แก้ได้โดยไม่ต้อง VACUUM (ไม่เคยทดสอบมาก่อน)
--
-- L02 เป็นกลไก MVCC ล้วน จึงคาดว่าน่าจะรอดการทดสอบข้ามชุดข้อมูล
-- แต่กฎเหล็กข้อ 1 ห้ามใช้การคาดเดาตัดสิน — ต้องวัด
--
-- ⚠️ query vector ต้องมาจากนอกตารางเสมอ (E35 · H27)
--    ตัวตรวจรุ่นแรกใช้แถวในตารางเองซึ่งยังไม่ตาย แล้วได้ผลครบทั้งที่ fault เกิดอยู่
-- ⚠️ ปิด autovacuum เฉพาะตารางนี้ ไม่งั้นมันเก็บกวาดเองระหว่างวัด
-- ============================================================
\timing on
\set ON_ERROR_STOP on

DROP INDEX IF EXISTS qf_l02r_idx;
DROP TABLE IF EXISTS qf_l02r_obs;
DROP TABLE IF EXISTS qf_l02r;

CREATE TABLE qf_l02r_obs (
    stage text, dead_pct numeric, live bigint, asked int,
    got_index bigint, got_exact bigint, recall numeric, idx_size text
);

CREATE TABLE qf_l02r (id bigint PRIMARY KEY, embedding vector(384));
INSERT INTO qf_l02r SELECT id, embedding FROM qf_real;
ALTER TABLE qf_l02r SET (autovacuum_enabled = false);

DO $$
BEGIN
    LOAD 'vector';
    PERFORM set_config('temp_file_limit', '2GB', false);
END $$;

CREATE INDEX qf_l02r_idx ON qf_l02r USING hnsw (embedding vector_cosine_ops);
ANALYZE qf_l02r;

SELECT current_setting('hnsw.ef_search') AS ef_search,
       current_setting('autovacuum')     AS autovacuum_global;

-- ------------------------------------------------------------
-- ตัววัด — query vector มาจาก qf_real_q ซึ่งอยู่ **นอกตาราง** ที่ลบ
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_l02r_ask(p_limit int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM (SELECT id FROM qf_l02r '
                   'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) '
                   'LIMIT %s) s', p_limit) INTO n;
    RETURN n;
END $$;

-- เฉลย: ปิด index scan (ห้ามใช้ DROP INDEX ตามที่เอกสาร pgvector แนะนำ)
CREATE OR REPLACE FUNCTION qf_l02r_ask_exact(p_limit int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    PERFORM set_config('enable_indexscan', 'off', true);
    PERFORM set_config('enable_bitmapscan', 'off', true);
    EXECUTE format('SELECT count(*) FROM (SELECT id FROM qf_l02r '
                   'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) '
                   'LIMIT %s) s', p_limit) INTO n;
    PERFORM set_config('enable_indexscan', 'on', true);
    PERFORM set_config('enable_bitmapscan', 'on', true);
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION qf_l02r_recall() RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE r numeric;
BEGIN
    SELECT round(avg(x), 4) INTO r FROM (
        SELECT (SELECT count(*) FROM unnest(t.ids) AS tid
                 WHERE tid = ANY (SELECT l.id FROM qf_l02r l
                                  ORDER BY l.embedding <=> q.embedding LIMIT 10)
               )::numeric / 10 AS x
        FROM qf_real_truth t JOIN qf_real_q q ON q.id = t.query_id
        WHERE t.k = 10) s;
    RETURN r;
END $$;

CREATE OR REPLACE FUNCTION qf_l02r_note(p_stage text, p_dead numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    -- อุ่น cache ก่อนวัด (กฎเหล็กข้อ 8)
    PERFORM (SELECT count(*) FROM (
        SELECT id FROM qf_l02r
        ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 10) w);

    INSERT INTO qf_l02r_obs
    SELECT p_stage, p_dead, count(*), 10,
           qf_l02r_ask(10), qf_l02r_ask_exact(10), qf_l02r_recall(),
           pg_size_pretty(pg_relation_size('qf_l02r_idx'))
    FROM qf_l02r;
END $$;

-- ------------------------------------------------------------
-- ไล่ระดับการตาย ทีละ 10% — ไม่ VACUUM ระหว่างทาง
-- ------------------------------------------------------------
SELECT qf_l02r_note('ตั้งต้น', 0);

DELETE FROM qf_l02r WHERE id % 10 = 0;  SELECT qf_l02r_note('ตาย 10%', 10);
DELETE FROM qf_l02r WHERE id % 10 = 1;  SELECT qf_l02r_note('ตาย 20%', 20);
DELETE FROM qf_l02r WHERE id % 10 = 2;  SELECT qf_l02r_note('ตาย 30%', 30);
DELETE FROM qf_l02r WHERE id % 10 = 3;  SELECT qf_l02r_note('ตาย 40%', 40);
DELETE FROM qf_l02r WHERE id % 10 = 4;  SELECT qf_l02r_note('ตาย 50%', 50);
DELETE FROM qf_l02r WHERE id % 10 = 5;  SELECT qf_l02r_note('ตาย 60%', 60);
DELETE FROM qf_l02r WHERE id % 10 = 6;  SELECT qf_l02r_note('ตาย 70%', 70);
DELETE FROM qf_l02r WHERE id % 10 = 7;  SELECT qf_l02r_note('ตาย 80%', 80);
DELETE FROM qf_l02r WHERE id % 10 = 8;  SELECT qf_l02r_note('ตาย 90%', 90);

-- ------------------------------------------------------------
-- ขอเยอะขึ้นช่วยไหม (ของเดิม: ที่ตาย 90% ขอ 10·40·100·1000 ได้ 0 ทั้งหมด)
-- ------------------------------------------------------------
\qecho ''
\qecho '=== ที่ตาย 90% · ขอเยอะขึ้นช่วยไหม ==='
SELECT 10   AS "ขอ", qf_l02r_ask(10)   AS "ได้", qf_l02r_ask_exact(10)   AS "เฉลย"
UNION ALL SELECT 40,   qf_l02r_ask(40),   qf_l02r_ask_exact(40)
UNION ALL SELECT 100,  qf_l02r_ask(100),  qf_l02r_ask_exact(100)
UNION ALL SELECT 1000, qf_l02r_ask(1000), qf_l02r_ask_exact(1000);

-- ------------------------------------------------------------
-- VACUUM แก้ได้ไหม · index เล็กลงไหม
-- ------------------------------------------------------------
\qecho ''
\qecho '=== หลัง VACUUM ==='
VACUUM (VERBOSE false) qf_l02r;
SELECT qf_l02r_note('หลัง VACUUM', 90);

-- ------------------------------------------------------------
-- ผล
-- ------------------------------------------------------------
\qecho ''
SELECT stage AS "ขั้น", dead_pct AS "ตายไป %", live AS "แถวที่ยังอยู่",
       asked AS "ขอ", got_index AS "ได้", got_exact AS "เฉลย",
       recall AS "recall@10", idx_size AS "ขนาด index"
FROM qf_l02r_obs ORDER BY ctid;

-- ------------------------------------------------------------
-- assertion
-- ------------------------------------------------------------
DO $$
DECLARE n_bad int; n_idx int; base numeric;
BEGIN
    SELECT got_exact INTO base FROM qf_l02r_obs WHERE stage = 'ตั้งต้น';
    IF base <> 10 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: เฉลยตอนตั้งต้นได้ % (ต้อง 10)', base;
    END IF;
    RAISE NOTICE '[1/2] OK เฉลยตอนตั้งต้นได้ครบ 10';

    SELECT count(*) INTO n_bad FROM qf_l02r_obs WHERE got_index < got_exact;
    RAISE NOTICE '[2/2] ขั้นที่ index ให้ไม่ครบ: % จาก % ขั้น',
        n_bad, (SELECT count(*) FROM qf_l02r_obs);
END $$;

DROP INDEX IF EXISTS qf_l02r_idx;

DO $$
DECLARE n_idx int;
BEGIN
    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว (กับดักข้อ 4)', n_idx;
    END IF;
    RAISE NOTICE 'ไม่มี index ค้าง';
END $$;
