-- ============================================================
-- เฟส 2.5 — คำนวณ recall ของ Qdrant ด้วย "สูตรเดียวกัน เฉลยเดียวกัน"
--
-- รัน:  psql ... -f /sql/q01_qdrant_recall.sql
--
-- จุดสำคัญของทั้งเฟส 2.5: **ตัวแปรเดียวที่เปลี่ยนคือ engine**
--   corpus     — ชุดเดียวกัน ส่งออกจาก qf_corpus ไปตรงๆ
--   ชุด query  — ชุดเดียวกัน fingerprint 607babfb6344eab74d3e76496b04fa9f
--   เฉลย       — qf_truth ตัวเดิม ที่มาจาก exact search ของ PostgreSQL
--   สูตร recall — |truth_k ∩ approx_k| / k เหมือนกันทุกตัวอักษร
--
-- ถ้าไม่คุมสี่อย่างนี้ ผลที่ได้จะเป็นการเทียบยี่ห้อ ไม่ใช่การพิสูจน์ว่า
-- recall collapse เป็นคุณสมบัติของ ANN
-- ============================================================

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS qf_qdrant_raw;
CREATE TABLE qf_qdrant_raw (
    mode     text,
    query_id int,
    k        int,
    ids_csv  text
);

\copy qf_qdrant_raw FROM '/results/qdrant_search_results.csv' WITH (FORMAT csv)

-- ============================================================
-- ด่านตรวจ — กฎเหล็กข้อ 10
-- ============================================================
DO $$
DECLARE
    fp    text;
    n_ex  int;
    n_hn  int;
BEGIN
    SELECT value INTO fp FROM qf_manifest WHERE item = 'query_set_fingerprint';
    IF fp IS DISTINCT FROM '607babfb6344eab74d3e76496b04fa9f' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: fingerprint ชุด query ไม่ตรง (ได้ %)', fp;
    END IF;

    SELECT count(*) FILTER (WHERE mode='exact'),
           count(*) FILTER (WHERE mode LIKE 'hnsw%')
      INTO n_ex, n_hn FROM qf_qdrant_raw;

    -- 200 query × 2 ค่า k = 400 แถวต่อโหมด · มี 2 โหมด hnsw = 800
    IF n_ex <> 400 OR n_hn <> 800 THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: ผลจาก Qdrant ไม่ครบ (exact=% hnsw*=% ต้อง 400 และ 800)', n_ex, n_hn;
    END IF;
    RAISE NOTICE 'ด่านตรวจผ่าน: fingerprint ตรง · ผลจาก Qdrant ครบทั้งสองโหมด';
END $$;

-- ============================================================
-- แปลงเป็น array แล้วเทียบกับเฉลยด้วยสูตรเดิม
-- ============================================================
DROP TABLE IF EXISTS qf_qdrant_recall;
CREATE TABLE qf_qdrant_recall AS
WITH parsed AS (
    SELECT mode, query_id, k,
           string_to_array(ids_csv, ',')::bigint[] AS ids
    FROM qf_qdrant_raw
),
per_query AS (
    SELECT p.mode, p.k, p.query_id,
           (SELECT count(*) FROM unnest(t.ids) AS truth_id
             WHERE truth_id = ANY (p.ids))::numeric / p.k AS recall,
           cardinality(p.ids) AS returned
    FROM parsed p
    JOIN qf_truth t ON t.query_id = p.query_id AND t.k = p.k
)
SELECT mode, k,
       count(*)::int                                   AS n_queries,
       round(avg(recall), 4)                           AS mean_recall,
       round(min(recall), 4)                           AS min_recall,
       count(*) FILTER (WHERE recall = 1.0)::int       AS n_perfect,
       min(returned)::int                              AS min_returned
FROM per_query
GROUP BY mode, k;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    ex10 numeric; hn10 numeric; hn100 numeric; ef40_10 numeric; ef40_100 numeric;
BEGIN
    SELECT mean_recall INTO ex10     FROM qf_qdrant_recall WHERE mode='exact'     AND k=10;
    SELECT mean_recall INTO hn10     FROM qf_qdrant_recall WHERE mode='hnsw'      AND k=10;
    SELECT mean_recall INTO hn100    FROM qf_qdrant_recall WHERE mode='hnsw'      AND k=100;
    SELECT mean_recall INTO ef40_10  FROM qf_qdrant_recall WHERE mode='hnsw_ef40' AND k=10;
    SELECT mean_recall INTO ef40_100 FROM qf_qdrant_recall WHERE mode='hnsw_ef40' AND k=100;

    -- ข้อ 1 คือตัวสอบทานทั้งเฟส 2.5
    -- Qdrant ค้นแบบ exact ต้องได้คำตอบเดียวกับ exact search ของ PostgreSQL
    -- ถ้าไม่ตรง แปลว่าข้อมูลส่งมาไม่ครบ หรือใช้คนละระยะทาง
    IF ex10 IS DISTINCT FROM 1.0000 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: Qdrant exact ได้ recall@10 = % (ต้อง 1.0) → เทียบกันไม่ได้', ex10;
    END IF;
    RAISE NOTICE '[1/2] OK Qdrant exact ตรงกับเฉลยของ PostgreSQL 100%% → เทียบกันได้จริง';

    -- ข้อ 2: **เทียบที่ความพยายามค้นหาเท่ากัน** (ef=40 เท่ากับ pgvector)
    -- นี่คือข้อที่ตอบคำถามของเฟส 2.5 จริงๆ
    -- ส่วนโหมด hnsw ที่ค่าเริ่มต้นของ Qdrant เอง เป็นข้อมูลประกอบ ไม่ใช่ตัวตัดสิน
    IF ef40_100 >= 1.0 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: ที่ ef=40 เท่ากับ pgvector แล้ว Qdrant ยังได้ recall@100 = % '
            '— ยังสรุปไม่ได้ว่ากลไกเหมือนกัน', ef40_100;
    END IF;
    RAISE NOTICE '[2/2] OK ที่ ef=40 เท่ากัน: Qdrant recall@10 = % · recall@100 = %',
        ef40_10, ef40_100;
    RAISE NOTICE '      (ค่าเริ่มต้นของ Qdrant เอง: recall@10 = % · recall@100 = %)', hn10, hn100;
END $$;

\qecho
\qecho '=== Q01 บน Qdrant — เฉลยและสูตรเดียวกับฝั่ง pgvector ==='
SELECT mode, k, n_queries, mean_recall, min_recall, n_perfect, min_returned
FROM qf_qdrant_recall ORDER BY mode DESC, k;

\qecho
\qecho '=== เทียบสอง engine ที่ 100,000 แถว · corpus/query/เฉลย/สูตร ชุดเดียวกัน ==='
SELECT 'pgvector HNSW (ef_search=40)' AS engine, 0.8565 AS "recall@10", 0.3903 AS "recall@100"
UNION ALL
SELECT 'Qdrant HNSW (hnsw_ef=40)',
       (SELECT mean_recall FROM qf_qdrant_recall WHERE mode='hnsw_ef40' AND k=10),
       (SELECT mean_recall FROM qf_qdrant_recall WHERE mode='hnsw_ef40' AND k=100)
UNION ALL
SELECT 'Qdrant HNSW (ค่าเริ่มต้นของ Qdrant)',
       (SELECT mean_recall FROM qf_qdrant_recall WHERE mode='hnsw' AND k=10),
       (SELECT mean_recall FROM qf_qdrant_recall WHERE mode='hnsw' AND k=100);

\qecho
\qecho '>>> ตัวเลข pgvector มาจาก results/q01_recall_collapse_100k.txt'
\qecho '>>> สองแถวแรกคือการเทียบที่ยุติธรรม: ความพยายามค้นหาเท่ากัน ตัวแปรเดียวที่ต่างคือ engine'
