-- ============================================================
-- Q01 บน embedding จริง — recall ตกเหมือนบน corpus สังเคราะห์ไหม
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -v builds=1 -f //sql/real_q01.sql
--
-- ต้องรัน real_load.sql ก่อน
--
-- คุมทุกอย่างให้เท่ากับการวัดบน qf_corpus เป๊ะ:
--   100,000 แถว · 384 มิติ · 200 query · cosine
--   HNSW ค่าเริ่มต้น (ef_search = 40) · IVFFlat ค่าเริ่มต้น (lists = 100, probes = 1)
-- ต่างกันอย่างเดียวคือ **ที่มาของเวกเตอร์**
--
-- ⚠️ ไม่แตะ qf_corpus — สร้าง index บน qf_real เท่านั้น
-- ⚠️ index ถูก DROP ทุกครั้งที่ต้นและท้าย ตามกับดักข้อ 4
-- ============================================================
\timing on
\set ON_ERROR_STOP on

-- จำนวน build ต่อการตั้งค่า — ส่งมาด้วย -v builds=N
SET qf.builds = :'builds';

DROP INDEX IF EXISTS qf_real_hnsw;
DROP INDEX IF EXISTS qf_real_ivf;

DROP TABLE IF EXISTS qf_real_q01;
CREATE TABLE qf_real_q01 (
    label        text,
    build_no     int,
    build_ms     numeric,
    index_size   text,
    recall_10    numeric,
    recall_100   numeric,
    min_recall10 numeric,
    n_perfect10  int,
    query_ms     numeric
);

-- ------------------------------------------------------------
-- ตัววัด — ยิงครบ 200 query แล้วเทียบกับเฉลย exact
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_real_measure(
    p_label text, p_build int, p_build_ms numeric, p_size text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz; ms numeric; r10 record; r100 record;
BEGIN
    -- กฎเหล็กข้อ 8: อุ่น cache ก่อนวัดเสมอ
    PERFORM (SELECT count(*) FROM (
        SELECT c.id FROM qf_real c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_real_q WHERE id = 0)
        LIMIT 10) z);

    t0 := clock_timestamp();
    PERFORM (SELECT count(*) FROM (
                SELECT c.id FROM qf_real c ORDER BY c.embedding <=> q.embedding LIMIT 10) z)
    FROM qf_real_q q;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    SELECT * INTO r10  FROM qf_real_recall_at(10);
    SELECT * INTO r100 FROM qf_real_recall_at(100);

    INSERT INTO qf_real_q01 VALUES (
        p_label, p_build, round(p_build_ms), p_size,
        r10.mean_recall, r100.mean_recall, r10.min_recall, r10.n_perfect,
        round(ms));
END $$;

-- ------------------------------------------------------------
-- 1. ค่าฐาน — ไม่มี index เลย (ต้องได้ 1.0 ตามนิยาม)
-- ------------------------------------------------------------
DO $$
DECLARE t0 timestamptz;
BEGIN
    RAISE NOTICE '--- exact (ไม่มี index) ---';
    PERFORM qf_real_measure('exact', 0, 0, '-');
END $$;

-- ------------------------------------------------------------
-- 2. HNSW ค่าเริ่มต้น · สร้างซ้ำหลายรอบเพราะ I04 พิสูจน์แล้วว่า build ไม่นิ่ง
-- ------------------------------------------------------------
DO $$
DECLARE
    i int; t0 timestamptz; ms numeric; sz text;
    n_builds int := coalesce(current_setting('qf.builds', true)::int, 1);
BEGIN
    LOAD 'vector';                       -- กฎเหล็กข้อ 9
    -- ⚠️ ห้ามแตะ maintenance_work_mem — Q01 เดิมปล่อยไว้ที่ 64MB ตามโปรไฟล์ fragile
    --    เปลี่ยนเมื่อไหร่ เทียบกับตัวเลขเดิมไม่ได้ทันที
    PERFORM set_config('temp_file_limit', '2GB', false);   -- กับดักข้อ 8

    FOR i IN 1..n_builds LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_real_hnsw';
        t0 := clock_timestamp();
        EXECUTE 'CREATE INDEX qf_real_hnsw ON qf_real '
                'USING hnsw (embedding vector_cosine_ops)';
        ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
        sz := pg_size_pretty(pg_relation_size('qf_real_hnsw'));
        RAISE NOTICE '--- HNSW build %/% (% วิ) ---', i, n_builds, round(ms/1000);
        PERFORM qf_real_measure('HNSW ef_search=40', i, ms, sz);
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_real_hnsw';
END $$;

-- ------------------------------------------------------------
-- 3. IVFFlat ค่าเริ่มต้น (lists = 100 ตามสูตร rows/1000 · probes = 1)
-- ------------------------------------------------------------
DO $$
DECLARE
    i int; t0 timestamptz; ms numeric; sz text;
    n_builds int := coalesce(current_setting('qf.builds', true)::int, 1);
BEGIN
    LOAD 'vector';
    PERFORM set_config('temp_file_limit', '2GB', false);

    FOR i IN 1..n_builds LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_real_ivf';
        t0 := clock_timestamp();
        EXECUTE 'CREATE INDEX qf_real_ivf ON qf_real '
                'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
        ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
        sz := pg_size_pretty(pg_relation_size('qf_real_ivf'));
        RAISE NOTICE '--- IVFFlat build %/% (% วิ) ---', i, n_builds, round(ms/1000);
        PERFORM qf_real_measure('IVFFlat probes=1', i, ms, sz);
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_real_ivf';
END $$;

-- ------------------------------------------------------------
-- 4. assertion — ต้องพิสูจน์ว่าการวัดนี้มีความหมาย
-- ------------------------------------------------------------
DO $$
DECLARE e numeric; h numeric; v numeric; n_idx int;
BEGIN
    SELECT recall_10 INTO e FROM qf_real_q01 WHERE label = 'exact';
    IF e IS DISTINCT FROM 1.0000 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: exact ได้ recall@10 = % (ต้อง 1.0) → สูตรวัดพัง ห้ามเชื่อผลใดๆ', e;
    END IF;
    RAISE NOTICE '[1/3] OK exact = 1.0000 ตามนิยาม';

    SELECT avg(recall_10) INTO h FROM qf_real_q01 WHERE label LIKE 'HNSW%';
    SELECT avg(recall_10) INTO v FROM qf_real_q01 WHERE label LIKE 'IVFFlat%';
    IF h IS NULL OR v IS NULL THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: ไม่มีผลของ index แบบใดแบบหนึ่ง';
    END IF;
    RAISE NOTICE '[2/3] OK วัดครบทั้งสอง index (HNSW % · IVFFlat %)',
        round(h,4), round(v,4);

    -- กับดักข้อ 4: ห้ามทิ้ง index ค้าง
    SELECT count(*) INTO n_idx
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'ข้อ 3 ตก: มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE '[3/3] OK ไม่มี index ค้าง';
END $$;

-- ------------------------------------------------------------
-- 5. ผล
-- ------------------------------------------------------------
SELECT label            AS "การตั้งค่า",
       build_no         AS "build",
       recall_10        AS "recall@10",
       recall_100       AS "recall@100",
       min_recall10     AS "แย่สุด@10",
       n_perfect10      AS "ครบ 10/10",
       build_ms         AS "build (ms)",
       index_size       AS "ขนาด index",
       query_ms         AS "200 query (ms)"
FROM qf_real_q01
ORDER BY label, build_no;

SELECT label                       AS "การตั้งค่า",
       count(*)                    AS "จำนวน build",
       round(avg(recall_10), 4)    AS "recall@10 เฉลี่ย",
       min(recall_10)              AS "ต่ำสุด",
       max(recall_10)              AS "สูงสุด",
       round(avg(recall_100), 4)   AS "recall@100 เฉลี่ย",
       min(min_recall10)           AS "แย่สุดต่อ query"
FROM qf_real_q01
GROUP BY label ORDER BY label;
