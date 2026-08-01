-- ============================================================================
-- Q06 — เคยลอง iterative_scan หรือยัง (รอบตามหลัง E42/E43)
-- ============================================================================
-- Q06 อ้างว่า "เพดาน = ef_search พอดีเป๊ะ · ทางแก้คือเพิ่ม ef_search"
-- แต่ **ไม่เคยทดสอบ `hnsw.iterative_scan`** ซึ่งเอกสารเขียนว่า
--   "will automatically scan more of the index until enough results are found"
-- ถ้ามันยกเพดานได้ ข้ออ้างเรื่องทางแก้ของ Q06 ก็ไม่ครบเหมือน L02
--
-- ห้ามแตะ qf_corpus — สร้างสำเนาแล้วลบทิ้ง
-- ============================================================================
\timing off
\set ON_ERROR_STOP on
SET client_min_messages = warning;
LOAD 'vector';
SET maintenance_work_mem = '256MB';

SELECT qf_fingerprint('qf_corpus') AS fp_before \gset

DROP TABLE IF EXISTS qf_q06p;
CREATE TABLE qf_q06p AS SELECT id, embedding FROM qf_corpus;
ALTER TABLE qf_q06p ADD PRIMARY KEY (id);
DROP INDEX IF EXISTS qf_q06p_idx;
CREATE INDEX qf_q06p_idx ON qf_q06p USING hnsw (embedding vector_cosine_ops);

DROP TABLE IF EXISTS qf_probe_qv;
CREATE TABLE qf_probe_qv AS SELECT embedding AS q FROM qf_queries ORDER BY id LIMIT 1;

DROP TABLE IF EXISTS qf_q06p_obs;
CREATE TABLE qf_q06p_obs (label text, asked int, got int, buffers bigint, used_index bool);

DROP FUNCTION IF EXISTS qf_q06p_run(text, text, int, int);
CREATE FUNCTION qf_q06p_run(p_label text, p_iter text, p_mult int, p_lim int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; n int; bufs bigint; used bool;
BEGIN
    PERFORM set_config('hnsw.iterative_scan',      p_iter,       true);
    PERFORM set_config('hnsw.ef_search',           '40',         true);   -- ค่าเริ่มต้น
    PERFORM set_config('hnsw.scan_mem_multiplier', p_mult::text, true);
    PERFORM set_config('hnsw.max_scan_tuples',     '20000',      true);
    PERFORM set_config('work_mem',                 '64kB',       true);

    EXECUTE format('
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id FROM qf_q06p
        ORDER BY embedding <=> (SELECT q FROM qf_probe_qv)
        LIMIT %s', p_lim) INTO j;

    n    := (j->0->'Plan'->>'Actual Rows')::int;
    bufs := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0)
          + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0);
    used := j::text LIKE '%qf_q06p_idx%';       -- ตรวจจากชื่อ index (กฎเหล็กข้อ 6)

    INSERT INTO qf_q06p_obs VALUES (p_label, p_lim, n, bufs, used);
END $$;

SELECT qf_q06p_run('warm', 'off', 1, 100);
DELETE FROM qf_q06p_obs;

\echo ''
\echo '=============================================================='
\echo 'Q06 ที่ ef_search = 40 (ค่าเริ่มต้น) — ไม่มี filter ใดๆ'
\echo '=============================================================='

SELECT qf_q06p_run('ค่าเริ่มต้น (iterative off)',        'off',            1,  100);
SELECT qf_q06p_run('iterative relaxed_order',           'relaxed_order',  1,  100);
SELECT qf_q06p_run('iterative strict_order',            'strict_order',   1,  100);
SELECT qf_q06p_run('iterative relaxed + mult=32',       'relaxed_order', 32,  100);
SELECT qf_q06p_run('iterative strict  + mult=32',       'strict_order',  32,  100);
SELECT qf_q06p_run('iterative relaxed + mult=32 ขอ 500','relaxed_order', 32,  500);

SELECT label AS "เงื่อนไข", asked AS "ขอ", got AS "ได้", buffers, used_index AS "ใช้ index"
FROM qf_q06p_obs ORDER BY ctid;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM qf_q06p_obs WHERE NOT used_index) THEN
        RAISE EXCEPTION 'ตก: มีเงื่อนไขที่ไม่ได้ใช้ vector index — การวัดใช้ไม่ได้';
    END IF;
END $$;

-- เก็บกวาด
DROP INDEX IF EXISTS qf_q06p_idx;
DROP TABLE IF EXISTS qf_q06p;
DROP TABLE IF EXISTS qf_probe_qv;
DROP FUNCTION IF EXISTS qf_q06p_run(text, text, int, int);

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
    RAISE NOTICE 'ผ่าน: fingerprint เดิม · ไม่มี index ค้าง';
END $$;
