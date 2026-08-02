-- ============================================================
-- Q01 — recall collapse  ⭐ ตัวชูโรงของทั้งโปรเจค
--
-- รัน:  psql ... -f /sql/q01_recall_collapse.sql
--
-- อาการ  : ใส่ index แล้วเร็วขึ้นมาก ผลลัพธ์ดูสมเหตุสมผล
-- ของจริง: ANN คือการค้นแบบ **ประมาณ** — index เปลี่ยน **คำตอบ** ไม่ใช่แค่ความเร็ว
-- เฉลย   : exact search (ไม่ใช้ index) = คำตอบที่ถูกต้องตามนิยาม
--
-- ⚠️ ไม่มีการ "จูน" อะไรทั้งสิ้น
--    สร้าง index ด้วยค่าเริ่มต้นของ pgvector และ query ด้วยค่าเริ่มต้น
--    เพราะนั่นคือสิ่งที่คนทำจริง และคือสิ่งที่ Q01 ต้องการวัด
--    (การจูนคือ Q04 คนละข้อกัน)
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_corpus_hnsw;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';
\timing on

SET max_parallel_workers_per_gather = 0;

-- ============================================================
-- ด่านตรวจก่อนวัดอะไรทั้งสิ้น
--
-- CLAUDE.md สั่งไว้: ก่อนเชื่อ recall ใดๆ ต้องเช็ค 2 อย่าง
--   1. fingerprint ของชุด query ตรง
--   2. ระยะในกลุ่ม/ข้ามกลุ่มยังห่างกัน
-- เคยพลาดทั้งสองแบบมาแล้ว (E11, E12)
-- ============================================================
DO $$
DECLARE
    fp        text;
    n_truth   int;
    n_idx     int;
    d_within  numeric;
    d_across  numeric;
BEGIN
    SELECT value INTO fp FROM qf_manifest WHERE item = 'query_set_fingerprint';
    IF fp IS DISTINCT FROM '607babfb6344eab74d3e76496b04fa9f' THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: fingerprint ชุด query ไม่ตรงกับที่ล็อกไว้ (ได้ %) — ชุดโจทย์เปลี่ยนไปแล้ว', fp;
    END IF;

    SELECT count(*) INTO n_truth FROM qf_truth WHERE k = 10;
    IF n_truth <> 200 THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: เฉลย k=10 มี % แถว (ต้อง 200) — รัน qf13 ก่อน', n_truth;
    END IF;

    SELECT count(*) INTO n_idx
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'จุดเริ่มต้นไม่สะอาด: มี vector index ค้างอยู่ % ตัว', n_idx;
    END IF;

    WITH s AS (SELECT id, cluster_id, embedding FROM qf_corpus ORDER BY id LIMIT 400)
    SELECT round(avg(a.embedding <=> b.embedding) FILTER (WHERE a.cluster_id = b.cluster_id)::numeric, 4),
           round(avg(a.embedding <=> b.embedding) FILTER (WHERE a.cluster_id <> b.cluster_id)::numeric, 4)
      INTO d_within, d_across
    FROM s a JOIN s b ON a.id < b.id;

    IF d_across / greatest(d_within, 0.0001) < 1.5 THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: ข้อมูลไม่มีโครงสร้างกลุ่ม (ในกลุ่ม % ข้ามกลุ่ม %) — recall จะไม่มีความหมาย (ดู E12)',
            d_within, d_across;
    END IF;

    RAISE NOTICE 'ด่านตรวจผ่าน: fingerprint ตรง · เฉลยครบ · ไม่มี index ค้าง · ในกลุ่ม % ข้ามกลุ่ม %',
        d_within, d_across;
END $$;

DROP TABLE IF EXISTS qf_q01_results;
CREATE TABLE qf_q01_results (
    label        text,
    index_kind   text,
    index_params text,
    build_ms     numeric,
    index_size   text,
    recall_10    numeric,
    recall_100   numeric,
    min_recall10 numeric,
    n_perfect10  int,
    query_ms     numeric,   -- เวลารวมของ 200 query ที่ k=10
    buffers      bigint     -- ของ query ตัวแทนหนึ่งตัว
);

-- ============================================================
-- ตัววัด: ยิงครบ 200 query แล้วเทียบกับเฉลย
-- ============================================================
CREATE OR REPLACE FUNCTION qf_q01_measure(
    p_label text, p_kind text, p_params text,
    p_build_ms numeric, p_size text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    t0   timestamptz;
    ms   numeric;
    r10  record;
    r100 record;
    j    json;
    buf  bigint;
BEGIN
    -- กฎเหล็กข้อ 8: อุ่น cache ก่อนวัดเสมอ
    PERFORM (SELECT count(*) FROM (
        SELECT c.id FROM qf_corpus c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1)
        LIMIT 10) z);

    t0 := clock_timestamp();
    PERFORM (SELECT count(*) FROM (
                SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> q.embedding LIMIT 10) z)
    FROM qf_queries q;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    SELECT * INTO r10  FROM qf_recall_at(10);
    SELECT * INTO r100 FROM qf_recall_at(100);

    EXECUTE $q$
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT c.id FROM qf_corpus c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1)
        LIMIT 10
    $q$ INTO j;
    buf := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
         + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

    INSERT INTO qf_q01_results VALUES (
        p_label, p_kind, p_params, p_build_ms, p_size,
        r10.mean_recall, r100.mean_recall, r10.min_recall, r10.n_perfect,
        round(ms, 1), buf);
END $$;

-- ============================================================
-- 1) ค่าฐาน — exact search ไม่มี index
--    ตามนิยามต้องได้ 1.0000 ถ้าไม่ใช่ = สูตรวัดพัง
-- ============================================================
\qecho
\qecho '=== 1) exact search (ไม่มี index) ==='
SELECT qf_q01_measure('exact (no index)', '-', '-', NULL, '-');

-- ============================================================
-- 2) HNSW ด้วยค่าเริ่มต้นของ pgvector ทั้งหมด
--    ไม่ระบุ m / ef_construction เลย — ปล่อยให้เป็นค่าที่ pgvector ให้มา
-- ============================================================
\qecho
\qecho '=== 2) HNSW (ค่าเริ่มต้นทั้งหมด) ==='
SELECT set_config('qf.t0', clock_timestamp()::text, false);
CREATE INDEX qf_corpus_hnsw ON qf_corpus USING hnsw (embedding vector_cosine_ops);

SELECT qf_q01_measure(
    'HNSW default', 'hnsw',
    coalesce((SELECT array_to_string(reloptions, ', ') FROM pg_class WHERE relname='qf_corpus_hnsw'),
             'ค่าเริ่มต้น (ไม่ได้ระบุอะไรเลย)')
      || ' · ef_search=' || current_setting('hnsw.ef_search'),
    round(extract(epoch FROM clock_timestamp() - current_setting('qf.t0')::timestamptz) * 1000, 1),
    pg_size_pretty(pg_relation_size('qf_corpus_hnsw')));

DROP INDEX qf_corpus_hnsw;

-- ============================================================
-- 3) IVFFlat ด้วยค่าเริ่มต้น
--    เอกสารแนะนำ lists = rows/1000 สำหรับข้อมูล <= 1M แถว
--    ที่ 100,000 แถว จึงเท่ากับ 100 ซึ่งบังเอิญตรงกับค่าเริ่มต้นของ pgvector พอดี
-- ============================================================
\qecho
\qecho '=== 3) IVFFlat (ค่าเริ่มต้น) ==='
-- ⚠️ ต้องผ่อน temp_file_limit เฉพาะตอน build เท่านั้น
--
-- k-means ของ IVFFlat ใช้ temp file เกิน 64MB ของโปรไฟล์ fragile
-- ถ้าไม่ผ่อน จะ build ไม่ผ่านเลย แล้ว Q01 วัดอะไรไม่ได้
--
-- ผ่อนได้โดยไม่กระทบผล เพราะ **recall ไม่ขึ้นกับ temp_file_limit เลย**
-- ข้อจำกัดตอน build เป็นเรื่องของ I05 คนละข้อกัน
-- คืนค่าเดิมทันทีหลัง build เสร็จ และไม่แตะตอนวัด
SET temp_file_limit = '2GB';

SELECT set_config('qf.t0', clock_timestamp()::text, false);
CREATE INDEX qf_corpus_ivf ON qf_corpus USING ivfflat (embedding vector_cosine_ops);

RESET temp_file_limit;

SELECT qf_q01_measure(
    'IVFFlat default', 'ivfflat',
    coalesce((SELECT array_to_string(reloptions, ', ') FROM pg_class WHERE relname='qf_corpus_ivf'),
             'ค่าเริ่มต้น (lists=100)')
      || ' · probes=' || current_setting('ivfflat.probes'),
    round(extract(epoch FROM clock_timestamp() - current_setting('qf.t0')::timestamptz) * 1000, 1),
    pg_size_pretty(pg_relation_size('qf_corpus_ivf')));

DROP INDEX qf_corpus_ivf;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    e   qf_q01_results%ROWTYPE;
    h   qf_q01_results%ROWTYPE;
    v   qf_q01_results%ROWTYPE;
BEGIN
    SELECT * INTO e FROM qf_q01_results WHERE index_kind = '-';
    SELECT * INTO h FROM qf_q01_results WHERE index_kind = 'hnsw';
    SELECT * INTO v FROM qf_q01_results WHERE index_kind = 'ivfflat';

    IF e.recall_10 IS DISTINCT FROM 1.0000 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: exact search ได้ recall@10 = % (ต้องเป็น 1.0 ตามนิยาม) → สูตรวัดพัง ห้ามเชื่อผลใดๆ',
            e.recall_10;
    END IF;
    RAISE NOTICE '[1/3] OK exact search = 1.0000 ตามนิยาม สูตรวัดใช้ได้';

    IF h.recall_10 >= 1.0 AND v.recall_10 >= 1.0 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: index ทั้งสองแบบยังได้ recall 1.0 — fault ไม่เกิด ข้อมูลอาจง่ายเกินไป';
    END IF;
    RAISE NOTICE '[2/3] OK มี index ที่ทำให้ recall ตก (HNSW % · IVFFlat %)',
        h.recall_10, v.recall_10;

    IF h.query_ms >= e.query_ms AND v.query_ms >= e.query_ms THEN
        RAISE EXCEPTION
            'ข้อ 3 ตก: ไม่มี index ตัวไหนเร็วกว่า exact เลย — เรื่องราวของ Q01 ไม่ครบ';
    END IF;
    RAISE NOTICE '[3/3] OK index เร็วกว่า exact (exact % ms · HNSW % ms · IVFFlat % ms)',
        e.query_ms, h.query_ms, v.query_ms;

    RAISE NOTICE 'assertion ผ่านครบ 3 ข้อ';
END $$;

-- ============================================================
-- ผลลัพธ์
-- ============================================================
\qecho
\qecho '=== Q01: index เปลี่ยนคำตอบ ไม่ใช่แค่ความเร็ว ==='
SELECT label,
       recall_10   AS "recall@10",
       recall_100  AS "recall@100",
       min_recall10 AS "แย่สุด@10",
       n_perfect10 AS "ครบ 10/10 กี่ query",
       query_ms    AS "200 query (ms)",
       round(
         (SELECT r.query_ms FROM qf_q01_results r WHERE r.index_kind='-')
         / greatest(query_ms, 0.001), 1) AS "เร็วขึ้นกี่เท่า",
       index_size  AS "ขนาด index"
FROM qf_q01_results
ORDER BY CASE index_kind WHEN '-' THEN 0 WHEN 'hnsw' THEN 1 ELSE 2 END;

\qecho
\qecho '=== พารามิเตอร์ที่ใช้ (ไม่ได้จูนอะไรเลย) ==='
SELECT label, index_params, build_ms AS "build (ms)", buffers AS "buffers (1 query)"
FROM qf_q01_results
ORDER BY CASE index_kind WHEN '-' THEN 0 WHEN 'hnsw' THEN 1 ELSE 2 END;

\qecho
\qecho '=== ไม่มี error · ไม่มี warning · ผลลัพธ์ดูสมเหตุสมผลทุกแถว ==='
\qecho '=== สิ่งเดียวที่บอกได้ว่าของหายคือการเทียบกับ exact search ==='
