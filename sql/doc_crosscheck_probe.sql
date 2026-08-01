-- ============================================================================
-- ตรวจข้ออ้าง 2 ข้อที่ "ไม่เคยวัด" และดูเหมือนขัดกับเอกสาร
-- ============================================================================
-- A. Q04 · เอกสารเขียนว่า probes ตั้งเท่า lists ได้ แต่ "at which point the
--    planner won't use the index"  ->  แถว probes=100 ในตาราง Q04 อาจไม่ได้
--    ใช้ index เลย ทำให้ตัวเลขเวลาเป็นของ exact search ไม่ใช่ของ IVFFlat
--    (กับดักเดียวกับ V07 · E25)
--
-- B. L02 · ทะเบียนเขียนว่า REINDEX = "คนมักแก้ผิด (แพงกว่า VACUUM มากโดยไม่จำเป็น)"
--    แต่ **เอกสารแนะนำ REINDEX ตรงๆ**:
--      "Vacuuming can take a while for HNSW indexes. Speed it up by
--       reindexing first.  REINDEX INDEX CONCURRENTLY ...;  VACUUM ...;"
--    และ repo นี้ **ไม่เคยวัด REINDEX สักครั้ง** -> เป็นข้ออ้างที่ไม่มีหลักฐาน
--
-- ห้ามแตะ qf_corpus — ตรวจ fingerprint ก่อน/หลัง
-- ============================================================================
\timing off
\set ON_ERROR_STOP on
SET client_min_messages = warning;
LOAD 'vector';
SET maintenance_work_mem = '256MB';

SELECT qf_fingerprint('qf_corpus') AS fp_before \gset

DROP TABLE IF EXISTS qf_probe_qv;
CREATE TABLE qf_probe_qv AS SELECT embedding AS q FROM qf_queries ORDER BY id LIMIT 1;

-- ============================================================================
-- A. Q04 — ที่ probes = lists planner ยังใช้ index อยู่ไหม
-- ============================================================================
\echo ''
\echo '=============================================================='
\echo 'A. Q04 · probes = lists  ->  planner ยังใช้ index อยู่ไหม'
\echo '=============================================================='

DROP TABLE IF EXISTS qf_q04x;
CREATE TABLE qf_q04x AS SELECT id, embedding FROM qf_corpus;
ALTER TABLE qf_q04x ADD PRIMARY KEY (id);
DROP INDEX IF EXISTS qf_q04x_idx;
CREATE INDEX qf_q04x_idx ON qf_q04x USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

DROP TABLE IF EXISTS qf_q04x_obs;
CREATE TABLE qf_q04x_obs (probes int, used_index bool, buffers bigint, node text);

DROP FUNCTION IF EXISTS qf_q04x_run(int);
CREATE FUNCTION qf_q04x_run(p_probes int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; bufs bigint; used bool;
BEGIN
    PERFORM set_config('ivfflat.probes', p_probes::text, true);
    EXECUTE '
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id FROM qf_q04x
        ORDER BY embedding <=> (SELECT q FROM qf_probe_qv)
        LIMIT 10' INTO j;
    bufs := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint,0)
          + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint,0);
    used := j::text LIKE '%qf_q04x_idx%';        -- ตรวจจากชื่อ index (กฎเหล็กข้อ 6)
    INSERT INTO qf_q04x_obs
    VALUES (p_probes, used, bufs, j->0->'Plan'->'Plans'->0->>'Node Type');
END $$;

SELECT qf_q04x_run(1);    -- อุ่น cache
DELETE FROM qf_q04x_obs;

SELECT qf_q04x_run(1);
SELECT qf_q04x_run(10);
SELECT qf_q04x_run(50);
SELECT qf_q04x_run(100);   -- = lists  <- จุดที่เอกสารเตือน

SELECT probes AS "probes", used_index AS "ใช้ index", buffers, node AS "node ใต้ Limit"
FROM qf_q04x_obs ORDER BY probes;

DROP INDEX IF EXISTS qf_q04x_idx;
DROP TABLE IF EXISTS qf_q04x;

-- ============================================================================
-- B. L02 — REINDEX เทียบ VACUUM ทั้งเวลาและผล
-- ============================================================================
\echo ''
\echo '=============================================================='
\echo 'B. L02 · REINDEX เทียบ VACUUM — เอกสารแนะนำ REINDEX ก่อน VACUUM'
\echo '=============================================================='

DROP TABLE IF EXISTS qf_l02x;
CREATE TABLE qf_l02x AS SELECT id, embedding FROM qf_corpus;
ALTER TABLE qf_l02x SET (autovacuum_enabled = false);
ALTER TABLE qf_l02x ADD PRIMARY KEY (id);
DROP INDEX IF EXISTS qf_l02x_idx;
CREATE INDEX qf_l02x_idx ON qf_l02x USING hnsw (embedding vector_cosine_ops);
DELETE FROM qf_l02x WHERE id % 10 <> 0;      -- ตาย 90%

DROP TABLE IF EXISTS qf_l02x_obs;
CREATE TABLE qf_l02x_obs (step text, got int, idx_mb numeric, secs numeric);

DROP FUNCTION IF EXISTS qf_l02x_got();
CREATE FUNCTION qf_l02x_got() RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    PERFORM set_config('hnsw.ef_search','40',true);
    PERFORM set_config('hnsw.iterative_scan','off',true);
    SELECT count(*) INTO n FROM (
        SELECT id FROM qf_l02x
        ORDER BY embedding <=> (SELECT q FROM qf_probe_qv) LIMIT 10) s;
    RETURN n;
END $$;

DO $$
DECLARE t timestamptz; n int;
BEGIN
    n := qf_l02x_got();
    INSERT INTO qf_l02x_obs VALUES ('ก่อนแก้ (ตาย 90% ไม่ VACUUM)', n,
        round(pg_relation_size('qf_l02x_idx')/1048576.0,1), NULL);

    -- REINDEX อย่างเดียว (ตามที่เอกสารบอกให้ทำก่อน)
    t := clock_timestamp();
    REINDEX INDEX qf_l02x_idx;
    n := qf_l02x_got();
    INSERT INTO qf_l02x_obs VALUES ('REINDEX อย่างเดียว', n,
        round(pg_relation_size('qf_l02x_idx')/1048576.0,1),
        round(EXTRACT(epoch FROM clock_timestamp()-t)::numeric,1));
END $$;

-- VACUUM รันใน DO block ไม่ได้ ต้องแยกคำสั่ง
\echo '-- VACUUM หลัง REINDEX (ลำดับที่เอกสารแนะนำ) --'
SELECT clock_timestamp() AS t0 \gset
VACUUM qf_l02x;
SELECT round(EXTRACT(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric,1) AS vac_secs \gset
INSERT INTO qf_l02x_obs
SELECT 'VACUUM (หลัง REINDEX)', qf_l02x_got(),
       round(pg_relation_size('qf_l02x_idx')/1048576.0,1), :'vac_secs'::numeric;

SELECT step AS "ขั้น", got AS "ได้/10", idx_mb AS "index MB", secs AS "วินาที"
FROM qf_l02x_obs ORDER BY ctid;

DROP INDEX IF EXISTS qf_l02x_idx;
DROP TABLE IF EXISTS qf_l02x;
DROP TABLE IF EXISTS qf_probe_qv;
DROP FUNCTION IF EXISTS qf_q04x_run(int);
DROP FUNCTION IF EXISTS qf_l02x_got();

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
