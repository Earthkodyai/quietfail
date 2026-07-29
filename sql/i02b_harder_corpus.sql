-- ============================================================
-- I02b — ข้อสรุปของ I02 รอดบนข้อมูลที่ "ยาก" กว่าไหม
--
-- รัน:  psql ... -f /sql/i02b_harder_corpus.sql
--
-- ⭐ ทำไมต้องมีการทดลองนี้
--    `REPORT.md` หัวข้อ 8 และเล่มวิทยานิพนธ์ข้อจำกัดข้อ 2 ระบุตรงๆ ว่า
--    **ผลของ I02 ผูกกับคุณสมบัติของ corpus ชุดหลักโดยตรง**
--    เพราะ qf_corpus ใช้ cluster_id = 1 + (id % 50) → กลุ่มสลับกันเป๊ะ
--    50 แถวแรกจึงมีครบ 50 กลุ่มพอดี = ตัวอย่างที่เป็นตัวแทนสมบูรณ์แบบ
--    ซึ่ง **ไม่ใช่สิ่งที่เกิดกับข้อมูลจริง**
--
--    การทดลองนี้สร้าง corpus ที่ยากขึ้น 4 ทาง แล้ววัดซ้ำด้วยเงื่อนไขเดียวกับ I02
--    ถ้าข้อสรุป "ความเป็นตัวแทนสำคัญกว่าจำนวนแถว" ยังยืน = ผลแข็งขึ้นมาก
--    ถ้าไม่ยืน = ต้องแก้ข้อสรุปของ I02 ซึ่งก็เป็นผลที่ต้องรายงาน
--
-- 4 อย่างที่ทำให้ยากขึ้น (เลียนแบบข้อมูลจริง)
--    1. **ลำดับ id เรียงตามกลุ่ม** ไม่ใช่สลับ — ข้อมูลชุดแรกของระบบจริง
--       มักมาจากลูกค้ากลุ่มแรก หมวดแรก ภูมิภาคแรก
--    2. **ขนาดกลุ่มไม่เท่ากัน** แบบ power law — กลุ่มใหญ่สุดมากกว่ากลุ่มเล็กสุดหลายสิบเท่า
--    3. **ขอบกลุ่มพร่ามัวขึ้น** noise 0.04 -> 0.10
--    4. **มี outlier 2%** จุดที่ไม่ได้อยู่ใกล้ centroid ไหนเลย
--
-- ใช้ centroid ชุดเดิม เพื่อให้ชุดคำถาม 200 ข้อยังใช้ได้ และแยกตัวแปรได้ชัด
--
-- ⚠️ ไม่แตะ qf_corpus — สร้างตารางใหม่แยกต่างหาก
-- ============================================================

\set ON_ERROR_STOP on
\timing off
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP INDEX IF EXISTS qf_i02b_idx;
DROP TABLE IF EXISTS qf_i02b;
DROP TABLE IF EXISTS qf_i02b_truth;
DROP TABLE IF EXISTS qf_i02b_obs;
DROP TABLE IF EXISTS qf_i02b_meta;

CREATE TABLE qf_i02b (id int PRIMARY KEY, cluster_id int, is_outlier bool,
                      embedding vector(384));

-- ============================================================
-- 1) สร้าง corpus ที่ยากขึ้น
-- ============================================================
\qecho '=== สร้าง corpus ที่ยากขึ้น 100,000 แถว ==='

DO $$
DECLARE
    v_rows  int    := 100000;
    v_clu   int    := 50;
    v_dim   int    := 384;
    v_noise float8 := 0.10;      -- เดิม 0.04 — ขอบกลุ่มพร่ามัวขึ้น
    v_out   float8 := 0.02;      -- สัดส่วน outlier
BEGIN
    -- ขนาดกลุ่มแบบ power law (น้ำหนักกลุ่ม k = 1/k) และ **id เรียงตามกลุ่มเป็นบล็อก**
    -- ต่างจาก qf_corpus ที่ใช้ id % 50 ซึ่งสลับกลุ่มให้เท่ากันเป๊ะ
    INSERT INTO qf_i02b (id, cluster_id, is_outlier, embedding)
    WITH ks AS (
        SELECT k, 1.0 / k AS w FROM generate_series(1, v_clu) k
    ), sized AS (
        SELECT k, greatest(1, floor(v_rows * w / (SELECT sum(w) FROM ks))::int) AS n
        FROM ks
    ), bounds AS (
        SELECT k, n,
               coalesce(sum(n) OVER (ORDER BY k
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS start_at
        FROM sized
    ), assigned AS (
        SELECT b.k AS cluster_id, (b.start_at + i)::int AS id
        FROM bounds b, generate_series(1, b.n) i
        WHERE b.start_at + i <= v_rows
    ), flagged AS (
        SELECT a.id, a.cluster_id,
               (qf_u01('out|' || a.id) < v_out) AS is_outlier,
               (c.embedding::real[]) AS cv
        FROM assigned a JOIN qf_centroids c ON c.id = a.cluster_id
    )
    SELECT f.id, f.cluster_id, f.is_outlier,
           (SELECT array_agg(
                CASE WHEN f.is_outlier
                     THEN qf_gauss('o|' || f.id || '|' || d)          -- ไม่เกาะ centroid
                     ELSE f.cv[d] + v_noise * qf_gauss('n|' || f.id || '|' || d)
                END ORDER BY d)
            FROM generate_series(1, v_dim) d)::vector
    FROM flagged f;
END $$;

ANALYZE qf_i02b;

\qecho ''
\qecho '=== เทียบโครงสร้างกับ corpus ชุดหลัก ==='
WITH a AS (SELECT count(*) n FROM qf_corpus GROUP BY cluster_id),
     b AS (SELECT count(*) n FROM qf_i02b  GROUP BY cluster_id)
SELECT 'qf_corpus (ชุดหลัก)' AS corpus,
       (SELECT count(*) FROM qf_corpus)               AS แถว,
       (SELECT count(*) FROM a)                        AS กลุ่ม,
       (SELECT min(n) FROM a)                          AS เล็กสุด,
       (SELECT max(n) FROM a)                          AS ใหญ่สุด,
       0                                               AS outlier_pct
UNION ALL
SELECT 'qf_i02b (ยากขึ้น)',
       (SELECT count(*) FROM qf_i02b),
       (SELECT count(*) FROM b),
       (SELECT min(n) FROM b),
       (SELECT max(n) FROM b),
       (SELECT round(100.0*count(*) FILTER (WHERE is_outlier)/count(*)) FROM qf_i02b);

\qecho ''
\qecho '=== ⭐ จุดชี้ขาด: N แถวแรกครอบคลุมกี่กลุ่ม ==='
\qecho '    ชุดหลักได้ครบ 50 ตั้งแต่ 50 แถวแรก · ชุดนี้ควรได้น้อยกว่ามาก'
SELECT n AS แถวแรก,
       (SELECT count(DISTINCT cluster_id) FROM (
            SELECT cluster_id FROM qf_corpus ORDER BY id LIMIT n) s) AS ชุดหลัก,
       (SELECT count(DISTINCT cluster_id) FROM (
            SELECT cluster_id FROM qf_i02b ORDER BY id LIMIT n) s)   AS ยากขึ้น
FROM (VALUES (50), (1000), (5000), (20000)) v(n);

-- ============================================================
-- 2) เฉลย — exact search บน corpus ชุดใหม่
-- ============================================================
\qecho ''
\qecho '=== สร้างเฉลยด้วย exact search (200 คำถาม k=10) ==='
CREATE TABLE qf_i02b_truth (query_id int PRIMARY KEY, ids int[]);

BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
INSERT INTO qf_i02b_truth
SELECT q.id,
       (SELECT array_agg(c.id) FROM (
            SELECT id FROM qf_i02b
            ORDER BY embedding <=> q.embedding LIMIT 10) c)
FROM qf_queries q;
COMMIT;

SELECT count(*) AS เฉลย, min(array_length(ids,1)) AS สั้นสุด FROM qf_i02b_truth;

-- ============================================================
-- 3) วัดเงื่อนไขเดียวกับ I02
-- ============================================================
CREATE TABLE qf_i02b_obs (round int, cond text, rows_at_build int,
                          query_id int, recall numeric);
CREATE TABLE qf_i02b_meta (round int, cond text, rows_at_build int,
                           clusters_seen int, rows_final bigint, build_ms numeric);

CREATE OR REPLACE FUNCTION qf_i02b_run(p_round int, p_cond text, p_rows int)
RETURNS void AS $$
DECLARE t0 timestamptz; ms numeric; seen int; n_fin bigint;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02b_idx';
    CREATE TEMP TABLE IF NOT EXISTS _keep AS SELECT 1;
    DROP TABLE IF EXISTS _keep;

    -- เก็บสำเนาไว้ แล้วตัดให้เหลือ p_rows แถวแรก
    CREATE TEMP TABLE _full AS SELECT * FROM qf_i02b;
    DELETE FROM qf_i02b WHERE id NOT IN (
        SELECT id FROM _full ORDER BY id LIMIT p_rows);

    SELECT count(DISTINCT cluster_id) INTO seen FROM qf_i02b;

    PERFORM set_config('temp_file_limit', '2GB', true);
    t0 := clock_timestamp();
    EXECUTE 'CREATE INDEX qf_i02b_idx ON qf_i02b '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    -- ข้อมูลโตกลับมาครบ โดยไม่สร้าง index ใหม่
    INSERT INTO qf_i02b SELECT * FROM _full f
     WHERE NOT EXISTS (SELECT 1 FROM qf_i02b x WHERE x.id = f.id);
    DROP TABLE _full;
    ANALYZE qf_i02b;

    SELECT count(*) INTO n_fin FROM qf_i02b;
    INSERT INTO qf_i02b_meta VALUES (p_round, p_cond, p_rows, seen, n_fin, round(ms,1));

    -- อุ่น cache (กฎเหล็กข้อ 8)
    PERFORM count(*) FROM (SELECT id FROM qf_i02b
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 10) w;

    INSERT INTO qf_i02b_obs
    SELECT p_round, p_cond, p_rows, t.query_id,
           (SELECT count(*) FROM unnest(t.ids) AS tid
             WHERE tid = ANY (SELECT c.id FROM qf_i02b c
                              ORDER BY c.embedding <=> q.embedding LIMIT 10)
           )::numeric / 10
    FROM qf_i02b_truth t JOIN qf_queries q ON q.id = t.query_id;
END $$ LANGUAGE plpgsql;

SET ivfflat.probes = 1;

\qecho ''
\qecho '=== 5 รอบ x 3 เงื่อนไข (I04 บังคับให้ต้อง 5 รอบ) ==='
SELECT qf_i02b_run(r, 'A_build_at_50', 50)      FROM generate_series(1,5) r;
SELECT qf_i02b_run(r, 'B_build_at_1000', 1000)  FROM generate_series(1,5) r;
SELECT qf_i02b_run(r, 'C_build_at_full', 100000) FROM generate_series(1,5) r;

\qecho ''
\qecho '=== ผล: corpus ยากขึ้น ==='
SELECT o.cond,
       max(m.clusters_seen)          AS กลุ่มที่เห็นตอน_build,
       round(avg(s.m), 4)            AS recall_เฉลี่ย,
       round(min(s.m), 4)            AS ต่ำสุด,
       round(max(s.m), 4)            AS สูงสุด
FROM (SELECT cond, round, avg(recall) AS m FROM qf_i02b_obs GROUP BY 1,2) s
JOIN qf_i02b_obs o ON o.cond = s.cond
JOIN qf_i02b_meta m ON m.cond = s.cond
GROUP BY o.cond ORDER BY o.cond;

-- ============================================================
\qecho ''
\qecho '=== assertion ==='
DO $$
DECLARE
    a_seen int; c_seen int; a numeric; b numeric; c numeric; n_fin int;
BEGIN
    SELECT count(DISTINCT rows_final) INTO n_fin FROM qf_i02b_meta;
    IF n_fin <> 1 THEN
        RAISE EXCEPTION 'ข้อมูลปลายทางไม่เท่ากันทุกเงื่อนไข (% แบบ) เทียบไม่ได้', n_fin;
    END IF;
    RAISE NOTICE '[1/3] OK ข้อมูลปลายทางเท่ากันทุกเงื่อนไข';

    SELECT max(clusters_seen) INTO a_seen FROM qf_i02b_meta WHERE cond='A_build_at_50';
    SELECT max(clusters_seen) INTO c_seen FROM qf_i02b_meta WHERE cond='C_build_at_full';
    IF a_seen >= c_seen THEN
        RAISE EXCEPTION 'corpus ยังไม่ยากจริง — 50 แถวแรกเห็น % กลุ่ม เท่ากับ build ครบ (%)',
                        a_seen, c_seen;
    END IF;
    RAISE NOTICE '[2/3] OK corpus ยากจริง — 50 แถวแรกเห็นแค่ % กลุ่ม จากทั้งหมด %', a_seen, c_seen;

    SELECT avg(m) INTO a FROM (SELECT avg(recall) m FROM qf_i02b_obs
        WHERE cond='A_build_at_50' GROUP BY round) s;
    SELECT avg(m) INTO b FROM (SELECT avg(recall) m FROM qf_i02b_obs
        WHERE cond='B_build_at_1000' GROUP BY round) s;
    SELECT avg(m) INTO c FROM (SELECT avg(recall) m FROM qf_i02b_obs
        WHERE cond='C_build_at_full' GROUP BY round) s;
    RAISE NOTICE '[3/3] OK วัดครบ — A=% B=% C=%', round(a,4), round(b,4), round(c,4);
    RAISE NOTICE '';
    IF a < c AND b < c THEN
        RAISE NOTICE '-> build ตอนข้อมูลน้อยแย่กว่า build ครบ **ตรงกับที่เอกสารเตือน**';
        RAISE NOTICE '   = ผลกลับด้านจาก I02 บน corpus ชุดหลัก -> ยืนยันว่าผลเดิมผูกกับโครงสร้างข้อมูล';
    ELSIF a > c THEN
        RAISE NOTICE '-> build ตอนข้อมูลน้อยยังดีกว่า แม้บน corpus ที่ยากขึ้น';
        RAISE NOTICE '   = ข้อสรุปของ I02 แข็งกว่าที่คิด ไม่ได้ผูกกับการสลับกลุ่มอย่างเดียว';
    ELSE
        RAISE NOTICE '-> ผลไม่ไปทางเดียวกัน ต้องดูรายเงื่อนไข';
    END IF;
END $$;

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_i02b_idx;
DROP FUNCTION IF EXISTS qf_i02b_run(int, text, int);
RESET ivfflat.probes;
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat');
SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text,'|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
