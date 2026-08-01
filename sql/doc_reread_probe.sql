-- ============================================================================
-- ตรวจข้อสรุปที่อาจเกิดจากการอ่านเอกสารไม่ครบ — รอบตามหลัง E42
-- ============================================================================
-- สองข้อที่มีรูปร่างเหมือน E42 คือ "ปรับแล้วไม่เห็นอะไรเปลี่ยน จึงสรุปว่ามันไม่ทำงาน"
--
--   A. `hnsw.max_scan_tuples` — เราเขียนว่า "ไม่ได้อะไรเลย buffers ไม่ขยับ"
--      เอกสารเขียนไว้เองว่า "Try increasing this [scan_mem_multiplier] if
--      increasing hnsw.max_scan_tuples does not improve recall"
--      -> เอกสารทำนายอาการนี้ไว้แล้ว และบอกด้วยว่าให้ทำอะไรต่อ
--      คำถาม: ปุ่มนี้ตายจริง หรือแค่ไม่ใช่ตัวที่ผูกอยู่ในตอนนั้น
--
--   B. L02 — เราเขียนว่า "ขอเยอะไม่ช่วย · VACUUM แก้ได้"
--      แต่ **ไม่เคยลอง `hnsw.iterative_scan`** ทั้งที่เอกสารระบุว่า dead tuple
--      เป็นสาเหตุของผลน้อย และ iterative scan มีไว้แก้ผลน้อยโดยตรง
--      และ CLAUDE.md เขียนเองว่า "L02 กลไกเดียวกับ Q03 เป๊ะ"
--
-- 🔴 บทเรียนจากรอบแรกของสคริปต์นี้เอง: รันครั้งแรกโดยไม่มี vector index
--    ทุกเงื่อนไขจึงได้ 40/40 เท่ากันหมด แล้วเกือบสรุปว่า "ปุ่มไม่มีผล"
--    ซึ่งเป็นกับดักเดียวกับ V07 (E25) -> ตอนนี้มี assertion บังคับ
--
-- ห้ามแตะ qf_corpus — ตรวจ fingerprint ก่อน/หลัง · เก็บกวาด index ทุกตัวท้ายไฟล์
-- ============================================================================
\timing off
\set ON_ERROR_STOP on
SET client_min_messages = warning;
LOAD 'vector';
SET maintenance_work_mem = '256MB';

\echo ''
\echo '=============================================================='
\echo 'fingerprint ของ qf_corpus ก่อนเริ่ม'
\echo '=============================================================='
SELECT qf_fingerprint('qf_corpus') AS fp_before \gset
\echo :fp_before

-- เวกเตอร์ query ต้องมาจากนอกตารางที่ทดสอบเสมอ (บทเรียน E35 · H27)
DROP TABLE IF EXISTS qf_probe_qv;
CREATE TABLE qf_probe_qv AS SELECT embedding AS q FROM qf_real_q ORDER BY id LIMIT 1;

-- ============================================================================
-- ส่วน A — max_scan_tuples ตายจริงไหม
-- ============================================================================
\echo ''
\echo '=============================================================='
\echo 'A. hnsw.max_scan_tuples — ปุ่มตาย หรือแค่ไม่ใช่ตัวที่ผูกอยู่'
\echo '=============================================================='
\echo 'qf_real (384 มิติ · 100k) · filter 1% · ขอ 40 แถว · relaxed_order'
\echo ''

DROP INDEX IF EXISTS qf_probe_a_idx;
CREATE INDEX qf_probe_a_idx ON qf_real USING hnsw (embedding vector_cosine_ops);

DROP TABLE IF EXISTS qf_probe_a;
CREATE TABLE qf_probe_a (
    label      text,
    got        int,
    buffers    bigint,
    used_index bool
);

DROP FUNCTION IF EXISTS qf_probe_a_run(text, int, int);
CREATE FUNCTION qf_probe_a_run(p_label text, p_mult int, p_max int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    j    jsonb;
    n    int;
    bufs bigint;
    used bool;
BEGIN
    PERFORM set_config('hnsw.iterative_scan',      'relaxed_order', true);
    PERFORM set_config('hnsw.ef_search',           '40',            true);
    PERFORM set_config('hnsw.scan_mem_multiplier', p_mult::text,    true);
    PERFORM set_config('hnsw.max_scan_tuples',     p_max::text,     true);
    PERFORM set_config('work_mem',                 '64kB',          true);

    EXECUTE '
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id FROM qf_real
        WHERE  id % 100 = 0
        ORDER BY embedding <=> (SELECT q FROM qf_probe_qv)
        LIMIT 40' INTO j;

    n    := (j->0->'Plan'->>'Actual Rows')::int;
    bufs := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0)
          + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0);
    -- ตรวจจาก **ชื่อ index** ไม่ใช่ค้นคำว่า Index Scan (กฎเหล็กข้อ 6 · E25)
    used := j::text LIKE '%qf_probe_a_idx%';

    INSERT INTO qf_probe_a VALUES (p_label, n, bufs, used);
END $$;

SELECT qf_probe_a_run('warm', 1, 20000);   -- อุ่น cache (กฎเหล็กข้อ 8)
DELETE FROM qf_probe_a;

-- A1: หน่วยความจำคับ (สภาพเดิมของการทดลอง Q03) -> max_scan_tuples ไม่ควรมีผล
SELECT qf_probe_a_run('mem คับ  mult=1  · max_scan_tuples 20000 (ปริยาย)', 1,  20000);
SELECT qf_probe_a_run('mem คับ  mult=1  · max_scan_tuples 200000 (x10)',   1, 200000);

-- A2: หน่วยความจำเหลือเฟือ -> ถ้าปุ่มยังทำงาน การไล่ค่าต้องเห็นผล
SELECT qf_probe_a_run('mem เหลือ mult=32 · max_scan_tuples 100',    32,    100);
SELECT qf_probe_a_run('mem เหลือ mult=32 · max_scan_tuples 1000',   32,   1000);
SELECT qf_probe_a_run('mem เหลือ mult=32 · max_scan_tuples 5000',   32,   5000);
SELECT qf_probe_a_run('mem เหลือ mult=32 · max_scan_tuples 20000',  32,  20000);
SELECT qf_probe_a_run('mem เหลือ mult=32 · max_scan_tuples 200000', 32, 200000);

SELECT label AS "เงื่อนไข", got AS "ได้/40", buffers, used_index AS "ใช้ index"
FROM   qf_probe_a ORDER BY ctid;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM qf_probe_a WHERE NOT used_index) THEN
        RAISE EXCEPTION 'ส่วน A ตก: มีเงื่อนไขที่ไม่ได้ใช้ vector index จริง — การวัดใช้ไม่ได้';
    END IF;
END $$;

DROP INDEX IF EXISTS qf_probe_a_idx;

\echo ''
\echo 'อ่านผล: ถ้ากลุ่ม mult=32 เปลี่ยนตาม max_scan_tuples -> ปุ่มทำงานปกติ'
\echo '        ที่ Q03 เห็นว่า "ไม่ได้อะไร" คือมันไม่ใช่ตัวที่ผูกอยู่ในตอนนั้น'


-- ============================================================================
-- ส่วน B — L02 กับ iterative_scan ที่ไม่เคยลอง
-- ============================================================================
\echo ''
\echo '=============================================================='
\echo 'B. L02 — iterative_scan ช่วยได้ไหม โดยไม่ต้อง VACUUM'
\echo '=============================================================='

DROP TABLE IF EXISTS qf_l02p;
CREATE TABLE qf_l02p AS SELECT id, embedding FROM qf_corpus;   -- อ่านอย่างเดียว
ALTER TABLE qf_l02p SET (autovacuum_enabled = false);
ALTER TABLE qf_l02p ADD PRIMARY KEY (id);

DROP INDEX IF EXISTS qf_l02p_idx;
CREATE INDEX qf_l02p_idx ON qf_l02p USING hnsw (embedding vector_cosine_ops);

-- ฆ่า 90% ตามการทดลองเดิม · ไม่ VACUUM
DELETE FROM qf_l02p WHERE id % 10 <> 0;

SELECT count(*) AS "แถวที่ยังอยู่หลังลบ 90%" FROM qf_l02p;

DROP TABLE IF EXISTS qf_probe_b;
CREATE TABLE qf_probe_b (
    label      text,
    got        int,
    buffers    bigint,
    used_index bool
);

DROP FUNCTION IF EXISTS qf_probe_b_run(text, text, int, int);
CREATE FUNCTION qf_probe_b_run(p_label text, p_iter text, p_mult int, p_lim int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    j    jsonb;
    n    int;
    bufs bigint;
    used bool;
BEGIN
    PERFORM set_config('hnsw.iterative_scan',      p_iter,       true);
    PERFORM set_config('hnsw.ef_search',           '40',         true);
    PERFORM set_config('hnsw.scan_mem_multiplier', p_mult::text, true);
    PERFORM set_config('hnsw.max_scan_tuples',     '20000',      true);
    PERFORM set_config('work_mem',                 '64kB',       true);

    EXECUTE format('
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id FROM qf_l02p
        ORDER BY embedding <=> (SELECT q FROM qf_probe_qv)
        LIMIT %s', p_lim) INTO j;

    n    := (j->0->'Plan'->>'Actual Rows')::int;
    bufs := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0)
          + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0);
    used := j::text LIKE '%qf_l02p_idx%';

    INSERT INTO qf_probe_b VALUES (p_label, n, bufs, used);
END $$;

SELECT qf_probe_b_run('warm', 'off', 1, 10);   -- อุ่น cache
DELETE FROM qf_probe_b;

SELECT qf_probe_b_run('ค่าเริ่มต้น (iterative off) ขอ 10',        'off',            1,   10);
SELECT qf_probe_b_run('ค่าเริ่มต้น (iterative off) ขอ 1000',      'off',            1, 1000);
SELECT qf_probe_b_run('iterative relaxed_order    ขอ 10',        'relaxed_order',  1,   10);
SELECT qf_probe_b_run('iterative strict_order     ขอ 10',        'strict_order',   1,   10);
SELECT qf_probe_b_run('iterative relaxed + mult=32 ขอ 10',       'relaxed_order', 32,   10);

SELECT label AS "เงื่อนไข", got AS "ได้", buffers, used_index AS "ใช้ index"
FROM   qf_probe_b ORDER BY ctid;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM qf_probe_b WHERE NOT used_index) THEN
        RAISE EXCEPTION 'ส่วน B ตก: มีเงื่อนไขที่ไม่ได้ใช้ vector index จริง — การวัดใช้ไม่ได้';
    END IF;
END $$;

\echo ''
\echo '-- กลุ่มควบคุม: VACUUM แล้ววัดซ้ำ (ต้องกลับมาครบ) --'
VACUUM qf_l02p;
DELETE FROM qf_probe_b;
SELECT qf_probe_b_run('หลัง VACUUM · iterative off ขอ 10', 'off', 1, 10);
SELECT label AS "เงื่อนไข", got AS "ได้", buffers, used_index AS "ใช้ index"
FROM   qf_probe_b ORDER BY ctid;

-- ============================================================================
-- เก็บกวาด + assertion ปิดท้าย
-- ============================================================================
DROP INDEX IF EXISTS qf_l02p_idx;
DROP TABLE IF EXISTS qf_l02p;
DROP TABLE IF EXISTS qf_probe_qv;
DROP FUNCTION IF EXISTS qf_probe_a_run(text, int, int);
DROP FUNCTION IF EXISTS qf_probe_b_run(text, text, int, int);

\echo ''
\echo '=============================================================='
\echo 'ตรวจว่าไม่ได้แตะ qf_corpus และไม่มี index ค้าง'
\echo '=============================================================='
SELECT qf_fingerprint('qf_corpus') AS fp_after \gset
\echo :fp_after

-- ⚠️ psql ไม่แทนค่า :'ตัวแปร' ข้างใน dollar-quoted block ต้องส่งผ่าน SET แทน
SET quietfail.fp_before = :'fp_before';
SET quietfail.fp_after  = :'fp_after';

DO $$
DECLARE n int;
BEGIN
    IF current_setting('quietfail.fp_before') <> current_setting('quietfail.fp_after') THEN
        RAISE EXCEPTION 'qf_corpus fingerprint เปลี่ยน — การทดลองนี้ใช้ไม่ได้';
    END IF;
    SELECT count(*) INTO n
    FROM   pg_class c JOIN pg_am a ON a.oid = c.relam
    WHERE  a.amname IN ('hnsw','ivfflat');
    IF n <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n;
    END IF;
    RAISE NOTICE 'ผ่าน: fingerprint เดิม · ไม่มี index ค้าง';
END $$;
