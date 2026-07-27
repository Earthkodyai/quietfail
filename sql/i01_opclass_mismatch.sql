-- ============================================================
-- I01 — opclass ตอนสร้าง ไม่ตรงกับ operator ตอน query
--
-- รัน:  psql ... -f /sql/i01_opclass_mismatch.sql
--
-- อาการ  : ช้าเหมือนไม่มี index ทั้งที่ \di เห็น index อยู่ชัดๆ
-- ต้นเหตุ: สร้างด้วย vector_l2_ops แต่ค้นด้วย <=> (cosine)
--          planner ใช้ index นั้นไม่ได้เลย
--
-- ⭐ I01 คือภาพสะท้อนกลับด้านของ Q01
--    Q01 — index ถูกใช้ → เร็วขึ้นมาก แต่ recall ตก
--    I01 — index ไม่ถูกใช้ → recall สมบูรณ์ แต่ไม่เร็วขึ้นเลย
--    ทั้งคู่ไม่มี error และดูปกติจากฝั่งผู้ใช้
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET max_parallel_workers_per_gather = 0;

\if :{?index_type}
\else
\set index_type hnsw
\endif

-- ============================================================
-- ด่านตรวจ
-- ============================================================
DO $$
DECLARE fp text; n int;
BEGIN
    SELECT value INTO fp FROM qf_manifest WHERE item = 'query_set_fingerprint';
    IF fp IS DISTINCT FROM '607babfb6344eab74d3e76496b04fa9f' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: fingerprint ชุด query ไม่ตรง (ได้ %)', fp;
    END IF;

    SELECT count(*) INTO n
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n <> 0 THEN
        RAISE EXCEPTION 'จุดเริ่มต้นไม่สะอาด: มี vector index ค้าง % ตัว', n;
    END IF;
    RAISE NOTICE 'ด่านตรวจผ่าน';
END $$;

DROP TABLE IF EXISTS qf_i01_results;
CREATE TABLE qf_i01_results (
    phase        text,
    opclass      text,
    index_used   boolean,
    plan_node    text,
    build_ms     numeric,
    index_size   text,
    query_ms     numeric,
    buffers      bigint,
    recall_10    numeric
);

-- ============================================================
-- ตัววัด — ยิง 200 query แล้วอ่าน plan ของ query ตัวแทน
-- ============================================================
CREATE OR REPLACE FUNCTION qf_i01_measure(
    p_phase text, p_opclass text, p_build_ms numeric, p_size text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz; ms numeric; j json; buf bigint;
    qvec vector; node text; used boolean; r record;
    plan_txt text; line text;
BEGIN
    -- ⚠️ ต้องดึง vector ออกมาเป็นค่าคงที่ก่อน แล้วค่อยใส่ลง EXPLAIN
    --
    -- เดิมเขียน EXPLAIN ... ORDER BY embedding <=> (SELECT ... WHERE id = 1)
    -- แล้วเช็คว่าใน plan มีคำว่า "Index Scan" ไหม
    -- ปรากฏว่า subquery นั้นใช้ **primary key ของ qf_queries** ซึ่งเป็น Index Scan
    -- ตัวตรวจเลยรายงานว่า "planner ใช้ index" ทุกกรณี รวมกรณีที่ opclass ผิด (ดู E25)
    --
    -- แก้สองชั้น: เอา subquery ออก และอ่าน node ของ qf_corpus ตรงๆ จาก JSON
    SELECT embedding INTO qvec FROM qf_queries WHERE id = 1;

    -- กฎเหล็กข้อ 8: อุ่น cache
    PERFORM (SELECT count(*) FROM (
        SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> qvec LIMIT 10) z);

    t0 := clock_timestamp();
    PERFORM (SELECT count(*) FROM (
                SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> q.embedding LIMIT 10) z)
    FROM qf_queries q;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
        'SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> %L::vector LIMIT 10',
        qvec::text) INTO j;

    -- อ่าน node ที่สแกน qf_corpus โดยเฉพาะ
    --
    -- ⚠️ ห้ามดูแค่ลูกโดยตรงของ Plan — แผนของ Seq Scan คือ
    --    Limit -> Sort -> Seq Scan  ซึ่ง qf_corpus อยู่ลึกสองชั้น
    --    เคยเขียนแบบดูชั้นเดียวแล้วได้ node = "Limit" (ดู E25)
    --
    -- ใช้ EXPLAIN แบบ TEXT แล้ว match บรรทัดที่สแกน qf_corpus ตรงๆ
    -- อ่านง่ายกว่าไล่ JSON แบบ recursive และไม่พลาดชั้น
    plan_txt := '';
    FOR line IN EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS) '
        'SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> %L::vector LIMIT 10',
        qvec::text)
    LOOP
        plan_txt := plan_txt || line || E'
';
    END LOOP;

    node := (regexp_match(plan_txt, '([A-Z][A-Za-z ]*Scan)[^
]* on qf_corpus'))[1];

    -- กฎเหล็กข้อ 10: หา node ที่สแกนตารางไม่เจอ = ตรวจไม่ได้ ห้ามเดา
    IF node IS NULL THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: หา node ที่สแกน qf_corpus ในแผนไม่เจอ · แผนที่ได้:%', E'
' || plan_txt;
    END IF;
    used := node ILIKE '%Index%';

    buf  := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
          + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

    SELECT * INTO r FROM qf_recall_at(10);

    INSERT INTO qf_i01_results VALUES
        (p_phase, p_opclass, used, node, p_build_ms, p_size, round(ms,1), buf, r.mean_recall);
END $$;

-- ============================================================
-- A) ไม่มี index เลย — ค่าฐาน
-- ============================================================
\qecho
\qecho '=== A) ไม่มี index ==='
SELECT qf_i01_measure('A no index', '-', NULL, '-');

-- ============================================================
-- B) opclass ผิด — l2 แต่ค้นด้วย cosine  ← นี่คือ fault
-- ============================================================
\qecho
\qecho '=== B) opclass ผิด: vector_l2_ops แต่ query ใช้ <=> (cosine) ==='
SELECT set_config('qf.t0', clock_timestamp()::text, false);
SET temp_file_limit = '2GB';
CREATE INDEX qf_i01_bad ON qf_corpus USING :index_type (embedding vector_l2_ops);
RESET temp_file_limit;

SELECT qf_i01_measure('B wrong opclass', 'vector_l2_ops',
    round(extract(epoch FROM clock_timestamp() - current_setting('qf.t0')::timestamptz)*1000, 1),
    pg_size_pretty(pg_relation_size('qf_i01_bad')));

\qecho
\qecho '--- catalog: ตรวจได้โดยไม่ต้องรัน query เลย (นี่คือชั้นที่ quietfail-check ใช้) ---'
SELECT c.relname AS index_name, am.amname AS index_type, opc.opcname AS opclass
FROM pg_index i
JOIN pg_class c    ON c.oid = i.indexrelid
JOIN pg_am am      ON am.oid = c.relam
JOIN pg_opclass opc ON opc.oid = i.indclass[0]
WHERE c.relname = 'qf_i01_bad';

\qecho
\qecho '--- operator ที่ opclass นี้รองรับจริง (ไม่มี <=> อยู่ในนั้น) ---'
SELECT opc.opcname, amop.amopopr::regoperator AS supported_operator
FROM pg_opclass opc
JOIN pg_amop amop ON amop.amopfamily = opc.opcfamily
WHERE opc.opcname IN ('vector_l2_ops','vector_cosine_ops')
ORDER BY opc.opcname;

DROP INDEX qf_i01_bad;

-- ============================================================
-- C) opclass ถูก — กลุ่มควบคุม
--    ถ้าข้อนี้ไม่ใช้ index แปลว่าสภาพแวดล้อมมีปัญหา ข้อ B ไม่พิสูจน์อะไร
-- ============================================================
\qecho
\qecho '=== C) opclass ถูก: vector_cosine_ops (กลุ่มควบคุม) ==='
SELECT set_config('qf.t0', clock_timestamp()::text, false);
SET temp_file_limit = '2GB';
CREATE INDEX qf_i01_good ON qf_corpus USING :index_type (embedding vector_cosine_ops);
RESET temp_file_limit;

SELECT qf_i01_measure('C right opclass', 'vector_cosine_ops',
    round(extract(epoch FROM clock_timestamp() - current_setting('qf.t0')::timestamptz)*1000, 1),
    pg_size_pretty(pg_relation_size('qf_i01_good')));

DROP INDEX qf_i01_good;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE a qf_i01_results%ROWTYPE; b qf_i01_results%ROWTYPE; c qf_i01_results%ROWTYPE;
        cat_ok boolean;
BEGIN
    SELECT * INTO a FROM qf_i01_results WHERE phase LIKE 'A%';
    SELECT * INTO b FROM qf_i01_results WHERE phase LIKE 'B%';
    SELECT * INTO c FROM qf_i01_results WHERE phase LIKE 'C%';

    IF b.index_used THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: opclass ผิดแต่ planner ยังใช้ index (node=%) — fault ไม่เกิด', b.plan_node;
    END IF;
    RAISE NOTICE '[1/4] OK opclass ผิด → ไม่ใช้ index (%)', b.plan_node;

    -- กลุ่มควบคุม: ถ้าข้อนี้ตก ข้อ 1 ไม่ได้พิสูจน์อะไรเลย
    IF NOT c.index_used THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: opclass ถูกแล้วยังไม่ใช้ index (node=%) '
            '→ สภาพแวดล้อมใช้ index ไม่ได้ ข้อ 1 จึงไม่พิสูจน์อะไร', c.plan_node;
    END IF;
    RAISE NOTICE '[2/4] OK opclass ถูก → ใช้ index (%)', c.plan_node;

    -- กฎเหล็กข้อ 10: อ่าน catalog ไม่ได้ = ตรวจไม่ได้ ไม่ใช่ผ่าน
    -- นับ DISTINCT ชื่อ เพราะ opclass ชื่อเดียวกันมีทั้งของ hnsw และ ivfflat
    -- เขียนเป็น count(*) = 2 ตอนแรกแล้วได้ 4 (ดู E25)
    SELECT count(DISTINCT opcname) = 2 INTO cat_ok FROM pg_opclass
    WHERE opcname IN ('vector_l2_ops','vector_cosine_ops');
    IF NOT cat_ok THEN
        RAISE EXCEPTION 'ข้อ 3 ตรวจไม่ได้: หา opclass ใน catalog ไม่ครบ';
    END IF;
    RAISE NOTICE '[3/4] OK catalog อ่าน opclass ได้ → ตรวจแบบ static ได้จริง';

    -- opclass ผิด ต้องช้าพอๆ กับไม่มี index (ต่างไม่เกิน 2 เท่า)
    IF b.query_ms > a.query_ms * 2 OR a.query_ms > b.query_ms * 2 THEN
        RAISE EXCEPTION
            'ข้อ 4 ตก: เวลาต่างกันมากเกินคาด (ไม่มี index % ms · opclass ผิด % ms)',
            a.query_ms, b.query_ms;
    END IF;
    RAISE NOTICE '[4/4] OK opclass ผิดช้าพอๆ กับไม่มี index (% ms vs % ms)',
        a.query_ms, b.query_ms;

    RAISE NOTICE 'assertion ผ่านครบ 4 ข้อ';
END $$;

-- ============================================================
\qecho
\qecho '=== I01: จ่ายค่า build เต็มราคา แล้วไม่ได้อะไรกลับมา ==='
SELECT phase, opclass, index_used, plan_node,
       build_ms AS "build (ms)", index_size AS "ขนาด",
       query_ms AS "200 query (ms)", buffers, recall_10 AS "recall@10"
FROM qf_i01_results ORDER BY phase;

\qecho
\qecho '=== I01 คือภาพสะท้อนกลับด้านของ Q01 ==='
\qecho '  Q01 : index ถูกใช้    -> เร็วขึ้น 32.6 เท่า  แต่ recall ตกเหลือ 0.8565'
\qecho '  I01 : index ไม่ถูกใช้ -> recall สมบูรณ์ 1.0  แต่ไม่เร็วขึ้นเลย'
\qecho '  ทั้งคู่ไม่มี error · ผลลัพธ์ดูปกติ · ต่างกันแค่ว่าอะไรถูกเสียไป'
\qecho
\qecho '=== ตรวจแบบ static ได้จาก catalog โดยไม่ต้องรัน query ==='
\qecho '=== -> quietfail-check ทำข้อนี้ได้ใน CI และ fail build ได้ทันที ==='
