-- ============================================================
-- V07 บน embedding จริง — แถวหายถาวรเพราะคุณภาพข้อมูล
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real2_v07.sql
--
-- ข้ออ้างเดิม (corpus สังเคราะห์ · 500 ปกติ + 5 NULL + 5 zero = 510):
--   ไม่มี index (exact)        ขอ 510 ได้ 510
--   มี index แต่ปิด index scan  ขอ 510 ได้ 510   <- กลุ่มควบคุมสำคัญ
--   ใช้ index                  ขอ 510 ได้ **500** — หายไป 10 แถวพอดี
--
-- ⚠️ ใช้ ef_search สูง (1000) เพื่อแยกจาก Q06 ให้ขาด
--    ถ้าใช้ค่าเริ่มต้น 40 จะแยกไม่ออกว่าหายเพราะ NULL/zero หรือเพราะเพดาน ef
-- ⚠️ แถวปกติมาจาก qf_real2 (embedding จริง) ไม่ใช่เวกเตอร์ที่ปั้นเอง
-- ============================================================
\timing on
\set ON_ERROR_STOP on

DROP INDEX IF EXISTS qf_v07r2_idx;
DROP TABLE IF EXISTS qf_v07r2;

CREATE TABLE qf_v07r2 (id bigint PRIMARY KEY, kind text, embedding vector(768));

-- 500 แถวปกติจาก embedding จริง
INSERT INTO qf_v07r2 SELECT id, 'ปกติ', embedding FROM qf_real2 ORDER BY id LIMIT 500;

-- 5 NULL
INSERT INTO qf_v07r2
SELECT 1000000 + g, 'NULL', NULL FROM generate_series(1, 5) g;

-- 5 zero vector — เวกเตอร์ศูนย์ 768 มิติ
INSERT INTO qf_v07r2
SELECT 2000000 + g, 'zero',
       (SELECT ('[' || string_agg('0', ',') || ']')::vector FROM generate_series(1, 768))
FROM generate_series(1, 5) g;

DO $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM qf_v07r2;
    IF n <> 510 THEN
        RAISE EXCEPTION 'จุดเริ่มต้นผิด: มี % แถว (ต้อง 510)', n;
    END IF;
    LOAD 'vector';
    PERFORM set_config('temp_file_limit', '2GB', false);
    RAISE NOTICE 'เตรียมข้อมูลแล้ว 510 แถว (ปกติ 500 · NULL 5 · zero 5)';
END $$;

-- ------------------------------------------------------------
-- แสดงว่า NaN / NULL เกิดขึ้นจริงในระดับ operator
-- ------------------------------------------------------------
\qecho ''
\qecho '=== operator ตอบอะไรกับ zero / NULL ==='
SELECT ('[' || string_agg('0', ',') || ']')::vector <=> (SELECT embedding FROM qf_real2_q WHERE id=0)
       AS "zero <=> query"
FROM generate_series(1, 768);
SELECT NULL::vector(768) <=> (SELECT embedding FROM qf_real2_q WHERE id=0) AS "NULL <=> query";

-- ------------------------------------------------------------
-- ตัววัด 3 เส้นทาง
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_v07r2_obs;
CREATE TABLE qf_v07r2_obs (
    path text, asked int, got bigint, n_normal bigint, n_null bigint, n_zero bigint,
    used_vector_index bool
);

-- ⚠️ ต้อง **บังคับ** ให้ใช้ index ด้วย enable_seqscan = off
--    ตาราง 510 แถวเล็กมาก planner จะเลือก Seq Scan เองเสมอ
--    รุ่นแรกไม่ได้บังคับ แล้วรายงานว่า "ไม่มีแถวหาย" ทั้งที่ไม่เคยใช้ index เลย
-- ⚠️ และต้องตรวจจาก **ชื่อ index** ไม่ใช่ค้นคำว่า "Index Scan" ทั้ง plan
--    เพราะ subquery ที่ดึง query vector ใช้ pkey ของอีกตาราง แล้วจะ match ผิด (E25)
DROP FUNCTION IF EXISTS qf_v07r2_probe(text, boolean);
CREATE FUNCTION qf_v07r2_probe(p_path text, p_use_index bool) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE qvec vector; j json; used bool;
BEGIN
    SELECT embedding INTO qvec FROM qf_real2_q WHERE id = 0;

    IF p_use_index THEN
        PERFORM set_config('enable_indexscan', 'on',  true);
        PERFORM set_config('enable_seqscan',   'off', true);
        PERFORM set_config('hnsw.ef_search',   '1000', true);
    ELSE
        PERFORM set_config('enable_indexscan', 'off', true);
        PERFORM set_config('enable_bitmapscan','off', true);
        PERFORM set_config('enable_seqscan',   'on',  true);
    END IF;

    EXECUTE 'EXPLAIN (FORMAT JSON) SELECT kind FROM qf_v07r2 '
            'ORDER BY embedding <=> $1 LIMIT 510'
      INTO j USING qvec;
    used := j::text LIKE '%qf_v07r2_idx%';

    INSERT INTO qf_v07r2_obs
    SELECT p_path, 510, count(*),
           count(*) FILTER (WHERE kind = 'ปกติ'),
           count(*) FILTER (WHERE kind = 'NULL'),
           count(*) FILTER (WHERE kind = 'zero'),
           used
    FROM (SELECT kind FROM qf_v07r2 ORDER BY embedding <=> qvec LIMIT 510) s;

    PERFORM set_config('enable_indexscan', 'on', true);
    PERFORM set_config('enable_bitmapscan','on', true);
    PERFORM set_config('enable_seqscan',   'on', true);
END $$;

-- เส้นทางที่ 1 — ยังไม่มี index เลย
SELECT qf_v07r2_probe('1. ไม่มี index (exact)', false);

-- สร้าง index แล้ววัดอีกสองเส้นทาง
SET hnsw.ef_search = 1000;
CREATE INDEX qf_v07r2_idx ON qf_v07r2 USING hnsw (embedding vector_cosine_ops);
ANALYZE qf_v07r2;

-- เส้นทางที่ 2 — **กลุ่มควบคุม** index มีอยู่ แต่บังคับไม่ให้ใช้
SELECT qf_v07r2_probe('2. มี index แต่ปิด index scan', false);

-- เส้นทางที่ 3 — ใช้ index จริง
SELECT qf_v07r2_probe('3. ใช้ index', true);

RESET hnsw.ef_search;

-- ------------------------------------------------------------
-- ผล
-- ------------------------------------------------------------
\qecho ''
SELECT path AS "เส้นทาง", asked AS "ขอ", got AS "ได้",
       n_normal AS "ปกติ", n_null AS "NULL", n_zero AS "zero",
       used_vector_index AS "ใช้ vector index จริง"
FROM qf_v07r2_obs ORDER BY path;

-- ------------------------------------------------------------
-- assertion
-- ------------------------------------------------------------
DO $$
DECLARE g1 bigint; g2 bigint; g3 bigint;
BEGIN
    SELECT got INTO g1 FROM qf_v07r2_obs WHERE path LIKE '1.%';
    SELECT got INTO g2 FROM qf_v07r2_obs WHERE path LIKE '2.%';
    SELECT got INTO g3 FROM qf_v07r2_obs WHERE path LIKE '3.%';

    IF g1 <> 510 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: exact ได้ % (ต้อง 510) — ข้อมูลหายจริง ไม่ใช่ index', g1;
    END IF;
    RAISE NOTICE '[1/3] OK exact ได้ครบ 510 — ข้อมูลไม่ได้หาย';

    -- ⭐ กลุ่มควบคุมสำคัญที่สุด: index มีอยู่แต่ไม่ได้ใช้ ต้องได้ครบ
    IF g2 <> 510 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: ปิด index scan แล้วยังได้ % (ต้อง 510) — แปลว่าไม่ใช่เส้นทาง index', g2;
    END IF;
    RAISE NOTICE '[2/3] OK กลุ่มควบคุมได้ครบ 510 — เส้นทาง index ต่างหากที่ทำหาย';

    -- 🔴 ถ้าเส้นทางที่ 3 ไม่ได้ใช้ index จริง ผลไม่มีความหมาย ต้องหยุด
    IF NOT (SELECT used_vector_index FROM qf_v07r2_obs WHERE path LIKE '3.%') THEN
        RAISE EXCEPTION
            'ข้อ 3 ตก: เส้นทางที่ 3 ไม่ได้ใช้ vector index จริง — การวัดใช้ไม่ได้ (กฎเหล็กข้อ 10)';
    END IF;
    RAISE NOTICE '[3/3] ใช้ index จริง ได้ % แถว (หายไป %)', g3, 510 - g3;
END $$;

DROP INDEX IF EXISTS qf_v07r2_idx;

DO $$
DECLARE n_idx int;
BEGIN
    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE 'ไม่มี index ค้าง';
END $$;
