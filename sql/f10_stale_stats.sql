-- ============================================================
-- F10 — statistics เก่า ทำให้ planner เลือกผิด
--
-- รัน:  psql ... -v rows=300000 -f /sql/f10_stale_stats.sql
--
-- อาการ    : query เดิม โค้ดเดิม ช้าลงหลายสิบเท่า **ไม่มี error**
-- ต้นเหตุ   : สถิติไม่ทันข้อมูล planner จึงประมาณจำนวนแถวผิด
-- ทำไมไม่เจอ: dev ไม่ได้ bulk insert แล้ว query ทันที
--
-- ground truth ปิดวงจรได้ในตัว: สั่ง ANALYZE แล้วหายไหม
-- ถ้าหาย = ยืนยันสาเหตุแบบเถียงไม่ได้
--
-- ⚠️ ใช้ตารางของตัวเอง (qf_f10_*) ไม่แตะ orders
--    เพราะ orders คือฐานของ EXP01/01b/01c ที่ตัวเลขถูกอ้างทั่วทั้ง repo
--    ถ้าฉีด F10 ใส่ orders จะเท่ากับทำลาย baseline ทุกครั้งที่รัน (ดู E22)
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

\set ON_ERROR_STOP on

\if :{?rows}
\else
\set rows 300000
\endif

\timing on

SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS qf_f10_obs, qf_f10_big, qf_f10_lookup;

-- ตารางที่จะถูก join เข้าไป — สถิติของมันถูกต้องเสมอ
--
-- ต้องใหญ่พอที่ "ไล่หาทีละแถวผ่าน index" กับ "อ่านรวดเดียวแล้ว hash"
-- จะมีต้นทุนต่างกันมาก ไม่งั้น planner เลือกท่าเดิมทั้งก่อนและหลัง ANALYZE
-- แล้ว fault จะไม่โผล่ (ลองด้วย 1,000 แถวมาแล้ว plan ไม่เปลี่ยน — ดู E22)
CREATE TABLE qf_f10_lookup (
    id      int PRIMARY KEY,
    label   text NOT NULL
);
INSERT INTO qf_f10_lookup
SELECT g, 'label-' || g FROM generate_series(1, 200000) g;
ANALYZE qf_f10_lookup;

-- ตารางใหญ่ที่สถิติจะล้าสมัย
CREATE TABLE qf_f10_big (
    id         bigserial PRIMARY KEY,
    lookup_id  int NOT NULL,   -- ใช้ join
    tag        int NOT NULL,   -- ใช้กรอง — คอลัมน์ที่สถิติจะล้าสมัย
    amount     bigint NOT NULL
);

-- ใส่ข้อมูลชุดแรก แล้ว ANALYZE ตอนนี้
-- histogram ของ tag จะครอบแค่ช่วง 1..1000 เท่านั้น
INSERT INTO qf_f10_big (lookup_id, tag, amount)
SELECT 1 + (g % 200000), 1 + (g % 1000), g FROM generate_series(1, 100000) g;
ANALYZE qf_f10_big;

-- กัน autovacuum มาช่วยกลางคัน ไม่งั้น fault จะหายเองแบบสุ่ม
ALTER TABLE qf_f10_big SET (autovacuum_enabled = off);

-- เก็บสถิติที่ planner เชื่ออยู่ ณ ตอนนี้ ไว้เป็นหลักฐาน
CREATE TABLE qf_f10_obs (
    phase        text,
    est_rows     bigint,
    actual_rows  bigint,
    buffers      bigint,
    node_type    text,
    exec_ms      numeric,
    reltuples    real
);

-- ============================================================
-- bulk insert — จุดที่สถิติเริ่มโกหก
--
-- ⚠️ หัวใจอยู่ที่ tag = 999999 ซึ่งเป็น **ค่าใหม่ที่ histogram ไม่เคยเห็น**
--
-- ความล้าสมัยของ "จำนวนแถวรวม" อย่างเดียวหลอก planner ไม่ได้
-- เพราะ PostgreSQL ปรับสเกล reltuples ตามขนาดไฟล์จริงเสมอ
-- ลองมาแล้ว: reltuples บอก 100 แต่ planner เดา 191,200 จากของจริง 300,100
-- คลาดแค่ 1.6 เท่า ไม่พอสำหรับ assertion (ดู E22)
--
-- ความล้าสมัยที่หลอกได้จริงคือ **สถิติระดับคอลัมน์** — MCV และ histogram
-- ค่าที่ไม่เคยปรากฏตอน ANALYZE ครั้งล่าสุด จะถูกเดาว่าเจอน้อยมาก
-- ============================================================
INSERT INTO qf_f10_big (lookup_id, tag, amount)
SELECT 1 + (g % 200000), 999999, g FROM generate_series(1, :rows) g;

-- ❗ จงใจไม่ ANALYZE ตรงนี้

CREATE OR REPLACE FUNCTION qf_f10_measure(p_phase text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    j    json;
    p    json;
BEGIN
    -- กฎเหล็กข้อ 8: อุ่น cache ก่อนวัด
    PERFORM count(*) FROM qf_f10_big b
      JOIN qf_f10_lookup l ON l.id = b.lookup_id WHERE b.tag = 999999;

    EXECUTE $q$
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT count(*)
        FROM qf_f10_big b
        JOIN qf_f10_lookup l ON l.id = b.lookup_id
        WHERE b.tag = 999999
    $q$ INTO j;

    -- ⚠️ ต้องอ่านตัวเลขจาก node ของ **join** ไม่ใช่ node บนสุด
    --
    -- node บนสุดคือ Aggregate ของ count(*) ซึ่งประมาณ 1 แถวและได้จริง 1 แถวเสมอ
    -- ไม่ว่าสถิติจะเพี้ยนแค่ไหน — วัดตรงนั้นแล้วจะได้ "คลาด 1.0 เท่า" ตลอด
    -- แล้วสรุปผิดว่า fault ไม่เกิด (ดู E22)
    --
    -- buffers ยังอ่านจาก node บนสุดได้ เพราะ EXPLAIN รวมของลูกมาให้แล้ว
    p := j -> 0 -> 'Plan' -> 'Plans' -> 0;

    INSERT INTO qf_f10_obs (phase, est_rows, actual_rows, buffers, node_type, exec_ms, reltuples)
    SELECT p_phase,
           (p ->> 'Plan Rows')::bigint,
           (p ->> 'Actual Rows')::bigint,
           coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
             + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0),
           p ->> 'Node Type',
           (j -> 0 ->> 'Execution Time')::numeric,
           (SELECT reltuples FROM pg_class WHERE oid = 'qf_f10_big'::regclass);
END $$;

SELECT qf_f10_measure('before_analyze');

-- ============================================================
-- ปิดวงจร: สั่ง ANALYZE แล้ววัดซ้ำด้วย query เดิมทุกตัวอักษร
-- ============================================================
ANALYZE qf_f10_big;

SELECT qf_f10_measure('after_analyze');

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    b   qf_f10_obs%ROWTYPE;
    a   qf_f10_obs%ROWTYPE;
    ratio_before numeric;
    ratio_after  numeric;
    buf_ratio    numeric;
BEGIN
    SELECT * INTO b FROM qf_f10_obs WHERE phase = 'before_analyze';
    SELECT * INTO a FROM qf_f10_obs WHERE phase = 'after_analyze';

    IF b.actual_rows IS NULL OR a.actual_rows IS NULL THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: วัดไม่ครบทั้งสองเฟส';
    END IF;

    ratio_before := b.actual_rows::numeric / greatest(b.est_rows, 1);
    ratio_after  := a.actual_rows::numeric / greatest(a.est_rows, 1);
    buf_ratio    := b.buffers::numeric / greatest(a.buffers, 1);

    RAISE NOTICE '--- ก่อน ANALYZE: ประมาณ % จริง % (คลาด %x) · buffers % · % · % ms',
        b.est_rows, b.actual_rows, round(ratio_before,1), b.buffers, b.node_type, round(b.exec_ms,1);
    RAISE NOTICE '--- หลัง ANALYZE: ประมาณ % จริง % (คลาด %x) · buffers % · % · % ms',
        a.est_rows, a.actual_rows, round(ratio_after,1), a.buffers, a.node_type, round(a.exec_ms,1);

    -- ข้อ 1: ก่อน ANALYZE ต้องประมาณคลาดอย่างน้อย 10 เท่า
    IF ratio_before < 10 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: ก่อน ANALYZE คลาดแค่ %x (ต้อง >= 10x) — autovacuum แอบมาทำงานหรือเปล่า · reltuples = %',
            round(ratio_before,1), b.reltuples;
    END IF;
    RAISE NOTICE '[1/3] OK ก่อน ANALYZE ประมาณคลาด %x (ต้อง >= 10x)', round(ratio_before,1);

    -- ข้อ 2: หลัง ANALYZE ต้องเหลือไม่เกิน 2 เท่า
    IF ratio_after > 2 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: หลัง ANALYZE ยังคลาด %x (ต้อง <= 2x)', round(ratio_after,1);
    END IF;
    RAISE NOTICE '[2/3] OK หลัง ANALYZE ประมาณคลาด %x (ต้อง <= 2x)', round(ratio_after,1);

    -- ข้อ 3: buffers ต้องลดลงอย่างน้อย 5 เท่า
    IF buf_ratio < 5 THEN
        RAISE EXCEPTION
            'ข้อ 3 ตก: buffers ลดแค่ %x (ต้อง >= 5x) — ก่อน % หลัง % · plan ก่อน=% หลัง=%',
            round(buf_ratio,1), b.buffers, a.buffers, b.node_type, a.node_type;
    END IF;
    RAISE NOTICE '[3/3] OK buffers ลดลง %x (ต้อง >= 5x)', round(buf_ratio,1);

    RAISE NOTICE 'assertion ผ่านครบ 3 ข้อ';
END $$;

-- ============================================================
-- ground truth
-- ============================================================
\qecho
\qecho '=== หลักฐาน: query เดิมทุกตัวอักษร ต่างกันแค่ ANALYZE ==='
SELECT phase,
       est_rows      AS "planner คิดว่า",
       actual_rows   AS "ของจริง",
       round(actual_rows::numeric / greatest(est_rows,1), 1) AS "คลาดกี่เท่า",
       buffers,
       node_type     AS "plan ที่เลือก",
       round(exec_ms, 1) AS ms,
       reltuples     AS "reltuples ที่ planner เห็น"
FROM qf_f10_obs
ORDER BY phase DESC;

\qecho
\qecho '=== ANALYZE แล้วหาย = ยืนยันสาเหตุแบบเถียงไม่ได้ ==='
\qecho '=== ทางแก้ผิดที่คนมักทำ: rewrite query / เพิ่ม index ที่ไม่จำเป็น ==='
