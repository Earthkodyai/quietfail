-- ============================================================================
-- Q06 + iterative_scan — ได้ครบ 100 แถวแล้ว แต่ "ถูก" กี่แถว
-- ============================================================================
-- รอบก่อนพบว่า iterative_scan ยกเพดาน 40 -> 100 ได้
-- **ห้ามสรุปว่า "แก้ Q06 ได้" จนกว่าจะวัด recall** ไม่งั้นจะเป็นความผิดพลาด
-- ชนิดเดียวกับที่เพิ่งถอนไป 3 ครั้ง คือดูตัวชี้วัดเดียวแล้วสรุป
--
-- เทียบกับ qf_truth (เฉลย exact ของชุด query 200 ข้อที่ล็อกไว้)
-- ============================================================================
\timing off
\set ON_ERROR_STOP on
SET client_min_messages = warning;
LOAD 'vector';
SET maintenance_work_mem = '256MB';

SELECT qf_fingerprint('qf_corpus') AS fp_before \gset

DROP TABLE IF EXISTS qf_q06r;
CREATE TABLE qf_q06r AS SELECT id, embedding FROM qf_corpus;
ALTER TABLE qf_q06r ADD PRIMARY KEY (id);
DROP INDEX IF EXISTS qf_q06r_idx;
CREATE INDEX qf_q06r_idx ON qf_q06r USING hnsw (embedding vector_cosine_ops);

DROP TABLE IF EXISTS qf_q06r_obs;
CREATE TABLE qf_q06r_obs (
    label     text,
    ef        int,
    got_avg   numeric,
    recall100 numeric,
    worst     numeric,
    full_100  int,
    buffers   bigint
);

DROP FUNCTION IF EXISTS qf_q06r_run(text, text, int, int);
CREATE FUNCTION qf_q06r_run(p_label text, p_iter text, p_mult int, p_ef int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r          record;
    hits       int;
    tot        numeric := 0;
    tot_got    numeric := 0;
    worst      numeric := 1;
    nfull      int := 0;
    nq         int := 0;
    got        int;
    j          jsonb;
    bufs       bigint := 0;
BEGIN
    PERFORM set_config('hnsw.iterative_scan',      p_iter,       true);
    PERFORM set_config('hnsw.ef_search',           p_ef::text,   true);
    PERFORM set_config('hnsw.scan_mem_multiplier', p_mult::text, true);
    PERFORM set_config('work_mem',                 '64kB',       true);

    FOR r IN SELECT q.id AS qid, q.embedding AS qv, t.ids AS truth
             FROM   qf_queries q
             JOIN   qf_truth  t ON t.query_id = q.id AND t.k = 100
             ORDER  BY q.id
    LOOP
        SELECT count(*), count(*) FILTER (WHERE a.id = ANY(r.truth))
        INTO   got, hits
        FROM  (SELECT id FROM qf_q06r
               ORDER BY embedding <=> r.qv LIMIT 100) a;

        nq      := nq + 1;
        tot_got := tot_got + got;
        tot     := tot + hits::numeric / 100;
        IF hits::numeric / 100 < worst THEN worst := hits::numeric / 100; END IF;
        IF got = 100 THEN nfull := nfull + 1; END IF;
    END LOOP;

    -- วัด buffers แยกหนึ่ง query เพื่อไม่ให้ลูปกวน
    EXECUTE format('
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id FROM qf_q06r
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries ORDER BY id LIMIT 1)
        LIMIT 100') INTO j;
    bufs := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0)
          + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0);

    INSERT INTO qf_q06r_obs
    VALUES (p_label, p_ef, round(tot_got/nq, 2), round(tot/nq, 4), worst, nfull, bufs);
END $$;

SELECT qf_q06r_run('warm', 'off', 1, 40);
DELETE FROM qf_q06r_obs;

\echo ''
\echo '=============================================================='
\echo 'ขอ 100 แถว · 200 query · เทียบเฉลย exact (qf_truth k=100)'
\echo '=============================================================='

SELECT qf_q06r_run('ค่าเริ่มต้น ef=40 · iterative off',  'off',            1,  40);
SELECT qf_q06r_run('ef=40 · iterative relaxed_order',   'relaxed_order',  1,  40);
SELECT qf_q06r_run('ef=40 · iterative strict_order',    'strict_order',   1,  40);
SELECT qf_q06r_run('ef=40 · relaxed + mult=32',         'relaxed_order', 32,  40);
SELECT qf_q06r_run('ทางแก้เดิม ef=100 · iterative off', 'off',            1, 100);
SELECT qf_q06r_run('ทางแก้เดิม ef=200 · iterative off', 'off',            1, 200);

SELECT label      AS "เงื่อนไข",
       got_avg    AS "ได้เฉลี่ย",
       recall100  AS "recall@100",
       worst      AS "แย่สุด",
       full_100   AS "ครบ 100/200q",
       buffers
FROM   qf_q06r_obs ORDER BY ctid;

DROP INDEX IF EXISTS qf_q06r_idx;
DROP TABLE IF EXISTS qf_q06r;
DROP FUNCTION IF EXISTS qf_q06r_run(text, text, int, int);

-- 🔴 เดิมลบ qf_q06r_obs แต่ตอนต้นไฟล์เท่านั้น (กับดักข้อ 14ฐ)
--    ต้นไฟล์กันรอบถัดไป ไม่ได้เก็บของรอบนี้ · ผลจริงอยู่ใน results/
DROP TABLE IF EXISTS qf_q06r_obs;

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

-- client_min_messages = warning ทำให้ NOTICE ข้างบนไม่โผล่ (กับดักข้อ 14ฑ)
\echo ''
\echo '✅ assertion ปิดท้ายผ่าน — qf_corpus fingerprint เดิม · ไม่มี vector index ค้าง'
