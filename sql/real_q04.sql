-- ============================================================
-- Q04 บน embedding จริง — ค่าที่เอกสารแนะนำยังเกินจำเป็นไหม
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -v builds=3 -f //sql/real_q04.sql
--
-- ต้องรัน real_load.sql ก่อน
--
-- ข้ออ้างที่ต้องตรวจ (REPORT.md 4.1) — วัดบน corpus สังเคราะห์ไว้ว่า:
--   probes = 5  ได้ recall สมบูรณ์แล้ว
--   probes = 10 (สูตร sqrt(lists) ที่เอกสารแนะนำ) ช้ากว่า 2.2 เท่าโดยไม่ได้อะไรเพิ่ม
--
-- I02 เพิ่งถูกหักล้างไปหนึ่งข้อเพราะไม่เคยตรวจข้ามชุดข้อมูล
-- ไฟล์นี้ทำแบบเดียวกันกับ Q04 ก่อนที่จะโดนถามในห้องสอบ
--
-- ⚠️ ไล่ค่าเดียวกับ q04_default_params.sql เป๊ะ เพื่อให้เทียบกันได้ตรงๆ
-- ⚠️ สร้าง index หลายรอบเพราะ I04 — probes เป็นค่าตอน query แต่ผลขึ้นกับ build ด้วย
-- ============================================================
\timing on
\set ON_ERROR_STOP on

SET qf.builds = :'builds';

DROP INDEX IF EXISTS qf_real_ivf;
DROP INDEX IF EXISTS qf_real_hnsw;
DROP TABLE IF EXISTS qf_real_q04;

CREATE TABLE qf_real_q04 (
    kind        text,
    param       text,
    val         int,
    build_no    int,
    recall_10   numeric,
    min_recall  numeric,
    n_perfect   int,
    query_ms    numeric
);

-- ------------------------------------------------------------
-- ตัววัด — ตั้งค่าแล้วยิงครบ 200 query
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_real_q04_measure(
    p_kind text, p_param text, p_val int, p_build int
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; ms numeric; r record;
BEGIN
    PERFORM set_config(p_param, p_val::text, false);

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

    SELECT * INTO r FROM qf_real_recall_at(10);

    INSERT INTO qf_real_q04 VALUES (
        p_kind, p_param, p_val, p_build,
        r.mean_recall, r.min_recall, r.n_perfect, round(ms));
END $$;

-- ------------------------------------------------------------
-- ส่วนที่ 1 — IVFFlat lists = 100 · ไล่ค่า probes
-- ------------------------------------------------------------
DO $$
DECLARE
    b int; v int;
    n int := coalesce(current_setting('qf.builds', true)::int, 3);
    vals int[] := ARRAY[1, 2, 5, 10, 20, 50, 100];
BEGIN
    LOAD 'vector';                                        -- กฎเหล็กข้อ 9
    PERFORM set_config('temp_file_limit', '2GB', false);  -- กับดักข้อ 8

    FOR b IN 1..n LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_real_ivf';
        EXECUTE 'CREATE INDEX qf_real_ivf ON qf_real '
                'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
        RAISE NOTICE '=== IVFFlat build %/% ===', b, n;
        FOREACH v IN ARRAY vals LOOP
            PERFORM qf_real_q04_measure('ivfflat', 'ivfflat.probes', v, b);
        END LOOP;
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_real_ivf';
    PERFORM set_config('ivfflat.probes', '1', false);
END $$;

-- ------------------------------------------------------------
-- ส่วนที่ 2 — HNSW · ไล่ค่า ef_search (วัดที่ k=10 เพื่อแยกจาก Q06)
-- ------------------------------------------------------------
DO $$
DECLARE
    b int; v int;
    n int := coalesce(current_setting('qf.builds', true)::int, 3);
    vals int[] := ARRAY[40, 80, 160, 320];
BEGIN
    LOAD 'vector';
    PERFORM set_config('temp_file_limit', '2GB', false);

    FOR b IN 1..n LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_real_hnsw';
        EXECUTE 'CREATE INDEX qf_real_hnsw ON qf_real '
                'USING hnsw (embedding vector_cosine_ops)';
        RAISE NOTICE '=== HNSW build %/% ===', b, n;
        FOREACH v IN ARRAY vals LOOP
            PERFORM qf_real_q04_measure('hnsw', 'hnsw.ef_search', v, b);
        END LOOP;
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_real_hnsw';
    PERFORM set_config('hnsw.ef_search', '40', false);
END $$;

-- ------------------------------------------------------------
-- assertion
-- ------------------------------------------------------------
DO $$
DECLARE n_idx int; n_rows int;
BEGIN
    SELECT count(*) INTO n_rows FROM qf_real_q04;
    IF n_rows = 0 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: ไม่มีผลการวัดเลย';
    END IF;
    RAISE NOTICE '[1/2] OK วัดได้ % แถว', n_rows;

    SELECT count(*) INTO n_idx
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: มี vector index ค้าง % ตัว (กับดักข้อ 4)', n_idx;
    END IF;
    RAISE NOTICE '[2/2] OK ไม่มี index ค้าง';
END $$;

-- ------------------------------------------------------------
-- ผล
-- ------------------------------------------------------------
\qecho ''
\qecho '=== IVFFlat lists=100 · ไล่ probes (เอกสารแนะนำ sqrt(100) = 10) ==='
SELECT val                          AS "probes",
       count(*)                     AS "builds",
       round(avg(recall_10), 4)     AS "recall@10 เฉลี่ย",
       min(recall_10)               AS "ต่ำสุด",
       max(recall_10)               AS "สูงสุด",
       min(min_recall)              AS "แย่สุดต่อ query",
       round(avg(n_perfect))        AS "ครบ 10/10",
       round(avg(query_ms))         AS "200 query (ms)"
FROM qf_real_q04 WHERE kind = 'ivfflat'
GROUP BY val ORDER BY val;

\qecho ''
\qecho '=== HNSW · ไล่ ef_search ==='
SELECT val                          AS "ef_search",
       count(*)                     AS "builds",
       round(avg(recall_10), 4)     AS "recall@10 เฉลี่ย",
       min(recall_10)               AS "ต่ำสุด",
       max(recall_10)               AS "สูงสุด",
       min(min_recall)              AS "แย่สุดต่อ query",
       round(avg(n_perfect))        AS "ครบ 10/10",
       round(avg(query_ms))         AS "200 query (ms)"
FROM qf_real_q04 WHERE kind = 'hnsw'
GROUP BY val ORDER BY val;
