-- ============================================================================
-- Q03 — ปุ่มที่เอกสารให้ หมุนแรงพอแล้วได้ผลไหม  (หลักฐานของ E42)
-- ============================================================================
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/q03_multiplier_probe.sql
--
-- 🔴 ไฟล์นี้ถูกสร้างขึ้นใหม่เมื่อ 2026-08-02 — ของเดิมหายไป
--
--    การวัดครั้งแรก (2026-08-01) ทำในไฟล์ชั่วคราวชื่อ `sql/_q03_multiplier_probe.sql`
--    ซึ่งขึ้นต้นด้วย `_` ตามธรรมเนียมของไฟล์ทิ้ง จึงถูกลบหลังใช้งาน
--    **แต่ผลของมัน (`results/q03_multiplier_probe.txt`) ถูกอ้างใน 8 เอกสาร**
--    รวมทั้งเล่มโครงงาน · REPORT.md · EVIDENCE.md · groundtruth/q03.json
--    ในฐานะหลักฐานของ **E42** ซึ่งเป็นการถอนข้ออ้างเรื่องเอกสารข้อสุดท้าย
--
--    -> ข้อสรุปที่สำคัญที่สุดข้อหนึ่งของโครงงาน **ทำซ้ำจากรีโปไม่ได้**
--       (กับดักข้อ 14ณ · เจอตอนทวน sql/ ทีละไฟล์)
--
-- คำถาม: เอกสารนิยาม `hnsw.scan_mem_multiplier` ว่าเป็น
--        "the max amount of memory to use, as a multiple of `work_mem`"
--        การทดลองเดิมของ Q03 ไล่ค่านี้ถึงแค่ 8 แล้วสรุปว่า "ทางแก้ที่เอกสาร
--        ระบุไม่เพียงพอ" · ถ้าไล่ต่อจะครบไหม
--
-- ⚠️ คงค่า `work_mem` ไว้ที่ 64kB (ค่าโปรไฟล์ fragile) ตลอดทุกเงื่อนไข
--    เพื่อพิสูจน์ว่า multiplier อย่างเดียวก็พอ ไม่ต้องแตะ work_mem
-- ⚠️ ต้องมี assertion ว่าใช้ vector index จริง ไม่งั้นได้ 40/40 เพราะ exact scan
--    (กับดักเดียวกับ V07 · E25 · และเคยเกิดกับ doc_reread_probe.sql มาแล้ว)
-- ห้ามแตะ qf_corpus — ตรวจ fingerprint ก่อน/หลัง
-- ============================================================================
\timing off
\set ON_ERROR_STOP on
SET client_min_messages = warning;
LOAD 'vector';
SET maintenance_work_mem = '256MB';

SELECT qf_fingerprint('qf_corpus') AS fp_before \gset

-- เวกเตอร์ query ต้องมาจากนอกตารางที่ค้น (บทเรียน E35 · H27)
DROP TABLE IF EXISTS qf_q03m_qv;
CREATE TABLE qf_q03m_qv AS SELECT embedding AS q FROM qf_real_q ORDER BY id LIMIT 1;

DROP INDEX IF EXISTS qf_q03m_idx;
CREATE INDEX qf_q03m_idx ON qf_real USING hnsw (embedding vector_cosine_ops);

DROP TABLE IF EXISTS qf_q03m_obs;
CREATE TABLE qf_q03m_obs (
    label      text,
    work_mem   text,
    mult       int,
    got        int,
    buffers    bigint,
    used_index bool
);

DROP FUNCTION IF EXISTS qf_q03m_run(text, text, int);
CREATE FUNCTION qf_q03m_run(p_label text, p_wm text, p_mult int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; n int; bufs bigint; used bool;
BEGIN
    PERFORM set_config('hnsw.iterative_scan',      'relaxed_order', true);
    PERFORM set_config('hnsw.ef_search',           '40',            true);
    PERFORM set_config('hnsw.max_scan_tuples',     '20000',         true);
    PERFORM set_config('hnsw.scan_mem_multiplier', p_mult::text,    true);
    PERFORM set_config('work_mem',                 p_wm,            true);

    EXECUTE '
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id FROM qf_real
        WHERE  id % 100 = 0
        ORDER BY embedding <=> (SELECT q FROM qf_q03m_qv)
        LIMIT 40' INTO j;

    n    := (j->0->'Plan'->>'Actual Rows')::int;
    bufs := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0)
          + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0);
    used := j::text LIKE '%qf_q03m_idx%';    -- ตรวจจากชื่อ index (กฎเหล็กข้อ 6)

    INSERT INTO qf_q03m_obs VALUES (p_label, p_wm, p_mult, n, bufs, used);
END $$;

SELECT qf_q03m_run('warm', '64kB', 1);       -- อุ่น cache (กฎเหล็กข้อ 8)
DELETE FROM qf_q03m_obs;

\echo ''
\echo '=============================================================='
\echo 'qf_real 384 มิติ · filter 1% (1,000 แถวเข้าเงื่อนไข) · ขอ 40 แถว'
\echo 'iterative_scan = relaxed_order · ef_search = 40 ตลอด'
\echo '=============================================================='

SELECT qf_q03m_run('work_mem 64kB · multiplier 1',   '64kB',   1);
SELECT qf_q03m_run('work_mem 64kB · multiplier 8',   '64kB',   8);
SELECT qf_q03m_run('work_mem 64kB · multiplier 32',  '64kB',  32);
SELECT qf_q03m_run('work_mem 64kB · multiplier 64',  '64kB',  64);
SELECT qf_q03m_run('work_mem 64kB · multiplier 128', '64kB', 128);
SELECT qf_q03m_run('work_mem 4MB  · multiplier 1',   '4MB',    1);

SELECT label AS "เงื่อนไข", got AS "ได้/40", buffers, used_index AS "ใช้ index"
FROM   qf_q03m_obs ORDER BY ctid;

DO $$
DECLARE n_bad int; got_1 int; got_8 int; got_32 int; got_wm int;
BEGIN
    SELECT count(*) INTO n_bad FROM qf_q03m_obs WHERE NOT used_index;
    IF n_bad > 0 THEN
        RAISE EXCEPTION 'ตก: มี % เงื่อนไขที่ไม่ได้ใช้ vector index — การวัดใช้ไม่ได้', n_bad;
    END IF;

    SELECT got INTO got_1  FROM qf_q03m_obs WHERE mult = 1   AND work_mem = '64kB';
    SELECT got INTO got_8  FROM qf_q03m_obs WHERE mult = 8   AND work_mem = '64kB';
    SELECT got INTO got_32 FROM qf_q03m_obs WHERE mult = 32  AND work_mem = '64kB';
    SELECT got INTO got_wm FROM qf_q03m_obs WHERE mult = 1   AND work_mem = '4MB';

    -- ข้ออ้างของ E42: multiplier อย่างเดียวพอ ไม่ต้องแตะ work_mem
    IF got_32 < 40 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: multiplier=32 ได้ % ไม่ครบ 40 — ข้ออ้างของ E42 ใช้ไม่ได้', got_32;
    END IF;
    IF got_8 >= 40 THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: multiplier=8 ได้ครบแล้ว — งั้นการทดลองเดิมไม่ได้หยุดเร็วเกินไป';
    END IF;
    IF got_1 >= got_8 THEN
        RAISE EXCEPTION 'ข้อ 3 ตก: multiplier ไม่ได้ทำให้ผลดีขึ้นเป็นลำดับ (% -> %)', got_1, got_8;
    END IF;
    IF got_wm <> got_32 THEN
        RAISE EXCEPTION 'ข้อ 4 ตก: work_mem 4MB ได้ % แต่ multiplier=32 ได้ % — ควรเท่ากัน',
                        got_wm, got_32;
    END IF;

    RAISE NOTICE 'ผ่าน 4/4: %/40 -> %/40 -> %/40 · work_mem 4MB ได้ %/40 เท่ากับ mult=32',
                 got_1, got_8, got_32, got_wm;
END $$;

-- เก็บกวาด — ต้องมีทั้งต้นและท้ายไฟล์ (กับดักข้อ 14ฐ)
DROP INDEX IF EXISTS qf_q03m_idx;
DROP TABLE IF EXISTS qf_q03m_qv;
DROP FUNCTION IF EXISTS qf_q03m_run(text, text, int);
DROP TABLE IF EXISTS qf_q03m_obs;

SELECT qf_fingerprint('qf_corpus') AS fp_after \gset
SET quietfail.fp_before = :'fp_before';
SET quietfail.fp_after  = :'fp_after';

DO $$
DECLARE n int;
BEGIN
    IF current_setting('quietfail.fp_before') <> current_setting('quietfail.fp_after') THEN
        RAISE EXCEPTION 'qf_corpus fingerprint เปลี่ยน';
    END IF;
    SELECT count(*) INTO n FROM pg_class c JOIN pg_am a ON a.oid = c.relam
    WHERE a.amname IN ('hnsw','ivfflat');
    IF n <> 0 THEN RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n; END IF;
END $$;

-- client_min_messages = warning ทำให้ NOTICE ข้างบนไม่โผล่ (กับดักข้อ 14ฑ)
\echo ''
\echo '✅ assertion ผ่านครบ — multiplier=32 ได้ครบ 40 โดยไม่แตะ work_mem'
\echo '   qf_corpus fingerprint เดิม · ไม่มี vector index ค้าง'
