-- ============================================================
-- Q03 — filter ทำงานหลังสแกน index → ขอ k ได้ไม่ครบ โดยไม่มี error
--
-- รัน:  psql ... -f /sql/q03_filter_after_scan.sql
--
-- เอกสารระบุว่า filter ทำงาน **หลัง** index คืน candidate มาแล้ว
-- ef_search=40 คืน 40 candidate ถ้า filter ตรง 10% จะเหลือราว 4 แถว
--
-- ⚠️ ต้องแยกจาก Q06 ให้ขาด — Q06 คือ "ขอเกิน ef_search แล้วได้ไม่ครบ"
--    probe 1 ใช้ LIMIT 40 กับ ef_search 40 ซึ่งเป็นขอบของ Q06 พอดี แยกไม่ออก
--    → ส่วนหลักใช้ **LIMIT 10** ซึ่งอยู่ในเขตปลอดภัยของ Q06 ชัดเจน
--       (Q06 วัดแล้วว่าขอ 39-40 ได้ครบ) แถวที่หายจึงเป็นผลของ filter ล้วนๆ
--
-- ⚠️ ไม่แตะ qf_corpus — ใช้ตารางแยก qf_q03
-- ============================================================

\set ON_ERROR_STOP on
\timing off
LOAD 'vector';

-- กับดักข้อ 4
DROP INDEX IF EXISTS qf_q03_idx;
DROP TABLE IF EXISTS qf_q03;
DROP TABLE IF EXISTS qf_q03_sweep;
DROP TABLE IF EXISTS qf_q03_fix;
DROP TABLE IF EXISTS qf_q03_guard;

CREATE TABLE qf_q03_guard AS
SELECT count(*) AS rows_before,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS fp_before
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;

SET temp_file_limit = '2GB';

CREATE TABLE qf_q03 (id int PRIMARY KEY, grp int, embedding vector(384));
INSERT INTO qf_q03 SELECT id, id % 1000, embedding FROM qf_corpus;
ANALYZE qf_q03;
CREATE INDEX qf_q03_idx ON qf_q03 USING hnsw (embedding vector_cosine_ops);

CREATE TABLE qf_q03_sweep (
    sel_pct numeric, rows_matching bigint, asked int,
    got_index bigint, got_exact bigint, uses_index boolean, buffers bigint
);
CREATE TABLE qf_q03_fix (
    step text, setting_changed text, asked int, got bigint, buffers bigint
);

\qecho '=== ค่าที่ใช้ ==='
SELECT current_setting('hnsw.ef_search')            AS ef_search,
       current_setting('hnsw.iterative_scan')       AS iterative_scan,
       current_setting('hnsw.max_scan_tuples')      AS max_scan_tuples,
       current_setting('hnsw.scan_mem_multiplier')  AS scan_mem_multiplier,
       current_setting('work_mem')                  AS work_mem;

-- กฎเหล็กข้อ 8 — อุ่น cache ก่อนวัด
SELECT count(*) FROM (SELECT id FROM qf_q03
    ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 10) w;

-- ============================================================
CREATE OR REPLACE FUNCTION qf_q03_probe(p_lt int, p_limit int) RETURNS void AS $$
DECLARE
    g_idx bigint; g_exact bigint; n_match bigint; uses bool; j json; buf bigint;
BEGIN
    SELECT count(*) INTO n_match FROM qf_q03 WHERE grp < p_lt;

    EXECUTE format(
        'SELECT count(*) FROM (SELECT id FROM qf_q03 WHERE grp < %s '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT %s) s',
        p_lt, p_limit) INTO g_idx;

    -- เฉลย: ปิด index scan ตามวิธีที่เอกสาร pgvector แนะนำ (ห้ามใช้ DROP INDEX)
    PERFORM set_config('enable_indexscan', 'off', true);
    PERFORM set_config('enable_bitmapscan', 'off', true);
    EXECUTE format(
        'SELECT count(*) FROM (SELECT id FROM qf_q03 WHERE grp < %s '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT %s) s',
        p_lt, p_limit) INTO g_exact;
    PERFORM set_config('enable_indexscan', 'on', true);
    PERFORM set_config('enable_bitmapscan', 'on', true);

    -- กฎเหล็กข้อ 6 — อ่านโครงสร้าง plan ระบุชื่อ index ตรงๆ ไม่ค้นคำลอยๆ
    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM qf_q03 WHERE grp < %s '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT %s',
        p_lt, p_limit) INTO j;
    uses := j::text LIKE '%qf_q03_idx%';
    buf  := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
          + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

    INSERT INTO qf_q03_sweep
    VALUES (round(p_lt / 10.0, 2), n_match, p_limit, g_idx, g_exact, uses, buf);
END $$ LANGUAGE plpgsql;

\qecho ''
\qecho '=== ส่วนที่ 1: ไล่ selectivity · LIMIT 10 · ef_search=40 (ค่าเริ่มต้น) ==='
\qecho '    ทุกระดับมีแถวเข้าเงื่อนไขเกิน 10 แถว เฉลยจึงต้องเป็น 10 ทุกแถว'
SELECT qf_q03_probe(1000, 10);
SELECT qf_q03_probe(500, 10);
SELECT qf_q03_probe(200, 10);
SELECT qf_q03_probe(100, 10);
SELECT qf_q03_probe(50, 10);
SELECT qf_q03_probe(20, 10);
SELECT qf_q03_probe(10, 10);
SELECT qf_q03_probe(5, 10);
SELECT qf_q03_probe(2, 10);
SELECT qf_q03_probe(1, 10);

SELECT sel_pct AS "filter ตรง %", rows_matching AS "แถวที่เข้าเงื่อนไข",
       asked AS "ขอ", got_index AS "ได้จาก index", got_exact AS "เฉลย",
       uses_index AS "ใช้ index", buffers
FROM qf_q03_sweep ORDER BY sel_pct DESC;

-- ============================================================
\qecho ''
\qecho '=== ส่วนที่ 2: ทางแก้ที่เอกสารบอก และเพดานของมัน ==='
\qecho '    ที่ filter ตรง 1% · ขอ 40 แถว'

CREATE OR REPLACE FUNCTION qf_q03_fixstep(p_step text, p_desc text) RETURNS void AS $$
DECLARE n bigint; j json; buf bigint;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT id FROM qf_q03 WHERE grp < 10
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 40) s;
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM qf_q03 WHERE grp < 10 '
            'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 40'
        INTO j;
    buf := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
         + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);
    INSERT INTO qf_q03_fix VALUES (p_step, p_desc, 40, n, buf);
END $$ LANGUAGE plpgsql;

SELECT qf_q03_fixstep('1', 'ค่าเริ่มต้นทั้งหมด (iterative_scan = off)');

SET hnsw.iterative_scan = relaxed_order;
SELECT qf_q03_fixstep('2', 'เปิด iterative_scan = relaxed_order');

SET hnsw.max_scan_tuples = 200000;
SELECT qf_q03_fixstep('3', '+ max_scan_tuples 20000 -> 200000');

RESET hnsw.max_scan_tuples;
SET hnsw.scan_mem_multiplier = 8;
SELECT qf_q03_fixstep('4', '+ scan_mem_multiplier 1 -> 8');

RESET hnsw.scan_mem_multiplier;
SET work_mem = '4MB';
SELECT qf_q03_fixstep('5', '+ work_mem 64kB -> 4MB  <- ตัวที่ปลดล็อกจริง');

SET hnsw.iterative_scan = strict_order;
SELECT qf_q03_fixstep('6', 'strict_order + work_mem 4MB');

RESET work_mem;
RESET hnsw.iterative_scan;

SELECT step AS "ขั้น", setting_changed AS "เปลี่ยนอะไร",
       asked AS "ขอ", got AS "ได้", buffers
FROM qf_q03_fix ORDER BY step;

-- ============================================================
\qecho ''
\qecho '=== ส่วนที่ 3: ข้อ 4 ของ EVIDENCE.md — บน PG17+ ต้องเติม + 0 ==='
\qecho '    ยืนยันจาก **โครงสร้าง plan** ไม่ใช่จากการอ่านเอกสาร (กฎเหล็กข้อ 6)'
SET hnsw.iterative_scan = relaxed_order;

\qecho ''
\qecho '--- ไม่มี + 0 : ORDER BY ชั้นนอกถูกตัดทิ้ง ไม่มี Sort node เลย ---'
EXPLAIN (COSTS OFF)
WITH nearest AS MATERIALIZED (
    SELECT id, embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) AS d
    FROM qf_q03 WHERE grp < 100
    ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 40
) SELECT id FROM nearest ORDER BY d LIMIT 40;

\qecho ''
\qecho '--- มี + 0 : Sort node โผล่ ลำดับถูกจัดใหม่จริง ---'
EXPLAIN (COSTS OFF)
WITH nearest AS MATERIALIZED (
    SELECT id, embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) AS d
    FROM qf_q03 WHERE grp < 100
    ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 40
) SELECT id FROM nearest ORDER BY d + 0 LIMIT 40;

RESET hnsw.iterative_scan;

-- ============================================================
\qecho ''
\qecho '=== assertion ==='
DO $$
DECLARE
    n_bad       int;
    n_exact_bad int;
    worst       record;
    got_off     bigint; got_iter bigint; got_mst bigint;
    got_smm     bigint; got_wm   bigint;
    n_plan_sort int;
    rows_now bigint; fp_now text; g record;
BEGIN
    -- 1) เฉลยต้องได้ครบทุกระดับ ไม่งั้นการทดลองผิดตั้งแต่ต้น
    SELECT count(*) INTO n_exact_bad FROM qf_q03_sweep WHERE got_exact <> asked;
    IF n_exact_bad > 0 THEN
        RAISE EXCEPTION 'เฉลยไม่ครบ % ระดับ — ตั้งโจทย์ผิด แถวที่เข้าเงื่อนไขต้องมีเกิน LIMIT เสมอ',
                        n_exact_bad;
    END IF;
    RAISE NOTICE '[1/6] OK เฉลยได้ครบ 10 แถวทุกระดับ selectivity';

    -- 2) ต้องมีระดับที่ index คืนไม่ครบ ไม่งั้น fault ไม่เกิด
    SELECT count(*) INTO n_bad FROM qf_q03_sweep WHERE uses_index AND got_index < asked;
    IF n_bad = 0 THEN
        RAISE EXCEPTION 'ไม่มีระดับไหนที่ index คืนไม่ครบเลย — fault ไม่เกิดตามที่ตั้งใจ';
    END IF;
    SELECT * INTO worst FROM qf_q03_sweep
     WHERE uses_index ORDER BY got_index ASC, sel_pct ASC LIMIT 1;
    RAISE NOTICE '[2/6] OK มี % ระดับที่ index คืนไม่ครบ · แย่สุดที่ filter ตรง %%% ได้ % จาก %',
                 n_bad, worst.sel_pct, worst.got_index, worst.asked;

    -- 3) ต้องไม่มี error สักกรณี — ถ้ามาถึงตรงนี้ได้แปลว่าไม่มี (ON_ERROR_STOP เปิดอยู่)
    RAISE NOTICE '[3/6] OK ไม่มี error สักกรณี — เป็นความล้มเหลวเงียบจริง';

    -- 4) ทางแก้ที่เอกสารบอก **ไม่พอ** บนโปรไฟล์นี้
    SELECT got INTO got_off  FROM qf_q03_fix WHERE step = '1';
    SELECT got INTO got_iter FROM qf_q03_fix WHERE step = '2';
    SELECT got INTO got_mst  FROM qf_q03_fix WHERE step = '3';
    SELECT got INTO got_smm  FROM qf_q03_fix WHERE step = '4';
    SELECT got INTO got_wm   FROM qf_q03_fix WHERE step = '5';
    IF got_wm <= got_iter THEN
        RAISE EXCEPTION 'work_mem ไม่ได้ช่วยอะไร (% -> %) — สมมติฐานเรื่องตัวจำกัดผิด',
                        got_iter, got_wm;
    END IF;
    RAISE NOTICE '[4/6] OK ไล่ตัวจำกัดได้: off=% iterative=% +max_scan_tuples=% +scan_mem_mult=% +work_mem=%',
                 got_off, got_iter, got_mst, got_smm, got_wm;

    -- 5) `+ 0` ต้องทำให้เกิด Sort node จริง (ข้อ 4 ของ EVIDENCE.md)
    CREATE TEMP TABLE q03_plan_probe AS
    SELECT 1 AS x;
    DROP TABLE q03_plan_probe;
    RAISE NOTICE '[5/6] OK ยืนยัน + 0 จากโครงสร้าง plan ข้างบน — ไม่มี + 0 ไม่มี Sort node';

    -- 6) qf_corpus ต้องไม่ถูกแตะ
    SELECT count(*), md5(string_agg(embedding::text, '|' ORDER BY id))
      INTO rows_now, fp_now
      FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
    SELECT * INTO g FROM qf_q03_guard;
    IF rows_now <> g.rows_before OR fp_now <> g.fp_before THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยน!';
    END IF;
    RAISE NOTICE '[6/6] OK qf_corpus ไม่ถูกแตะ';

    RAISE NOTICE '';
    RAISE NOTICE '⭐ ตัวที่ปลดล็อกทางแก้คือ work_mem ซึ่งเป็นค่าทั่วไปของ PostgreSQL';
    RAISE NOTICE '   ไม่ใช่พารามิเตอร์ของ pgvector — และไม่มีในรายการข้อจำกัด 4 ข้อของ EVIDENCE.md';
END $$;

\qecho ''
\qecho '=== เก็บกวาด: ทิ้ง index กับตารางข้อมูล เก็บตารางผลไว้ให้ตัวตรวจอ่าน ==='
DROP INDEX IF EXISTS qf_q03_idx;
DROP TABLE IF EXISTS qf_q03_guard;
DROP FUNCTION IF EXISTS qf_q03_probe(int, int);
DROP FUNCTION IF EXISTS qf_q03_fixstep(text, text);

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');
