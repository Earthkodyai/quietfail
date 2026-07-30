-- ============================================================
-- Q03 บน embedding จริง — filter ทำงานหลังสแกน index
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real_q03.sql
--
-- ต้องรัน real_load.sql ก่อน
--
-- ข้ออ้างที่ต้องตรวจ (REPORT.md 4.3 · เล่ม 4.3.3):
--   ทางแก้ 4 ข้อที่เอกสารระบุ **ไม่ทำงานเลย** จนกว่าจะเพิ่ม work_mem
--   ซึ่งไม่อยู่ในรายการข้อจำกัดของเอกสาร
--
-- Q04 กับ I02 ถูกหักล้าง/ลดระดับไปแล้วเพราะไม่เคยตรวจข้ามชุดข้อมูล
-- ข้อนี้เป็นข้อสุดท้ายใน 3 ข้ออ้างเรื่องเอกสาร
--
-- ⚠️ วิธีเดียวกับ q03_filter_after_scan.sql เป๊ะ — grp = id % 1000
--    grp < N จึงให้ selectivity = N/1000 และไม่สัมพันธ์กับตำแหน่งของเวกเตอร์
-- ⚠️ LIMIT 10 กับ ef_search 40 เพื่อแยกจาก Q06 ให้ขาด
-- ============================================================
\timing on
\set ON_ERROR_STOP on

DROP INDEX IF EXISTS qf_q03r_idx;
DROP TABLE IF EXISTS qf_q03r_fix;
DROP TABLE IF EXISTS qf_q03r_sweep;
DROP TABLE IF EXISTS qf_q03r;

CREATE TABLE qf_q03r (id bigint PRIMARY KEY, grp int, embedding vector(384));
INSERT INTO qf_q03r SELECT id, id % 1000, embedding FROM qf_real;

CREATE TABLE qf_q03r_sweep (
    sel_pct numeric, rows_matching bigint, asked int,
    got_index int, got_exact int, uses_index bool, buffers bigint
);
CREATE TABLE qf_q03r_fix (
    step text, descr text, asked int, got int, buffers bigint
);

DO $$
BEGIN
    LOAD 'vector';                                        -- กฎเหล็กข้อ 9
    PERFORM set_config('temp_file_limit', '2GB', false);  -- กับดักข้อ 8
END $$;

CREATE INDEX qf_q03r_idx ON qf_q03r USING hnsw (embedding vector_cosine_ops);
ANALYZE qf_q03r;

SELECT current_setting('hnsw.ef_search') AS ef_search,
       current_setting('hnsw.iterative_scan') AS iterative_scan,
       current_setting('work_mem') AS work_mem;

-- ------------------------------------------------------------
-- ตัววัด — เทียบ "แถวที่ได้จาก index" กับ "เฉลยจาก exact"
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_q03r_probe(p_lt int, p_limit int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    n_match bigint; n_idx int; n_exact int; j json; buf bigint; uses bool;
BEGIN
    -- อุ่น cache (กฎเหล็กข้อ 8)
    PERFORM (SELECT count(*) FROM (
        SELECT id FROM qf_q03r
        ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 10) w);

    SELECT count(*) INTO n_match FROM qf_q03r WHERE grp < p_lt;

    EXECUTE format(
        'SELECT count(*) FROM (SELECT id FROM qf_q03r WHERE grp < %s '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT %s) s',
        p_lt, p_limit) INTO n_idx;

    -- เฉลย: ปิด index scan เฉพาะใน transaction นี้
    PERFORM set_config('enable_indexscan', 'off', true);
    EXECUTE format(
        'SELECT count(*) FROM (SELECT id FROM qf_q03r WHERE grp < %s '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT %s) s',
        p_lt, p_limit) INTO n_exact;
    PERFORM set_config('enable_indexscan', 'on', true);

    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM qf_q03r WHERE grp < %s '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT %s',
        p_lt, p_limit) INTO j;

    -- กฎเหล็กข้อ 6: อ่านโครงสร้าง ต้องระบุชื่อ index ไม่ใช่ค้นคำว่า "Index Scan"
    uses := j::text LIKE '%qf_q03r_idx%';
    -- กฎเหล็กข้อ 7ก: buffers ต้องรวม hit + read
    buf := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
         + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

    INSERT INTO qf_q03r_sweep
    VALUES (round(p_lt / 10.0, 1), n_match, p_limit, n_idx, n_exact, uses, buf);
END $$;

\qecho ''
\qecho '=== ส่วนที่ 1: ไล่ selectivity · LIMIT 10 · ef_search=40 (ค่าเริ่มต้น) ==='
\qecho '    ทุกระดับมีแถวเข้าเงื่อนไขเกิน 10 แถว เฉลยจึงต้องเป็น 10 ทุกแถว'
SELECT qf_q03r_probe(1000, 10);
SELECT qf_q03r_probe(500, 10);
SELECT qf_q03r_probe(200, 10);
SELECT qf_q03r_probe(100, 10);
SELECT qf_q03r_probe(50, 10);
SELECT qf_q03r_probe(20, 10);
SELECT qf_q03r_probe(10, 10);
SELECT qf_q03r_probe(5, 10);
SELECT qf_q03r_probe(2, 10);
SELECT qf_q03r_probe(1, 10);

SELECT sel_pct AS "filter ตรง %", rows_matching AS "แถวที่เข้าเงื่อนไข",
       asked AS "ขอ", got_index AS "ได้จาก index", got_exact AS "เฉลย",
       uses_index AS "ใช้ index", buffers
FROM qf_q03r_sweep ORDER BY sel_pct DESC;

-- ------------------------------------------------------------
-- ส่วนที่ 2 — ทางแก้ที่เอกสารบอก และเพดานของมัน
-- ------------------------------------------------------------
\qecho ''
\qecho '=== ส่วนที่ 2: ทางแก้ที่เอกสารบอก · ที่ filter ตรง 1% · ขอ 40 แถว ==='

CREATE OR REPLACE FUNCTION qf_q03r_fixstep(p_step text, p_desc text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE n bigint; j json; buf bigint;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT id FROM qf_q03r WHERE grp < 10
        ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 40) s;
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM qf_q03r WHERE grp < 10 '
            'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 40'
        INTO j;
    buf := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
         + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);
    INSERT INTO qf_q03r_fix VALUES (p_step, p_desc, 40, n, buf);
END $$;

SELECT qf_q03r_fixstep('1', 'ค่าเริ่มต้นทั้งหมด (iterative_scan = off)');

SET hnsw.iterative_scan = relaxed_order;
SELECT qf_q03r_fixstep('2', 'เปิด iterative_scan = relaxed_order');

SET hnsw.max_scan_tuples = 200000;
SELECT qf_q03r_fixstep('3', '+ max_scan_tuples 20000 -> 200000');

RESET hnsw.max_scan_tuples;
SET hnsw.scan_mem_multiplier = 8;
SELECT qf_q03r_fixstep('4', '+ scan_mem_multiplier 1 -> 8');

RESET hnsw.scan_mem_multiplier;
SET work_mem = '4MB';
SELECT qf_q03r_fixstep('5', '+ work_mem 64kB -> 4MB  <- ตัวที่เอกสารไม่ได้พูดถึง');

RESET work_mem;
RESET hnsw.iterative_scan;

SELECT step AS "ขั้น", descr AS "เปลี่ยนอะไร", asked AS "ขอ", got AS "ได้", buffers
FROM qf_q03r_fix ORDER BY step;

-- ------------------------------------------------------------
-- assertion
-- ------------------------------------------------------------
DO $$
DECLARE n_bad int; n_idx int; n_exact_bad int;
BEGIN
    -- เฉลยต้องได้ครบ 10 ทุกระดับ ไม่งั้นการทดลองไม่มีความหมาย
    SELECT count(*) INTO n_exact_bad FROM qf_q03r_sweep WHERE got_exact <> asked;
    IF n_exact_bad > 0 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: เฉลยได้ไม่ครบ % ระดับ — แถวที่เข้าเงื่อนไขน้อยเกินไป การทดลองใช้ไม่ได้',
            n_exact_bad;
    END IF;
    RAISE NOTICE '[1/2] OK เฉลยได้ครบ 10 ทุกระดับ';

    SELECT count(*) INTO n_bad FROM qf_q03r_sweep WHERE got_index < asked;
    RAISE NOTICE '[2/2] ระดับที่ index ให้ไม่ครบ: % จาก % ระดับ',
        n_bad, (SELECT count(*) FROM qf_q03r_sweep);
END $$;

DROP INDEX IF EXISTS qf_q03r_idx;

DO $$
DECLARE n_idx int;
BEGIN
    SELECT count(*) INTO n_idx
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว (กับดักข้อ 4)', n_idx;
    END IF;
    RAISE NOTICE 'ไม่มี index ค้าง';
END $$;
