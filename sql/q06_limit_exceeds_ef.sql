-- ============================================================
-- Q06 — LIMIT มากกว่า ef_search → ได้ผลไม่ครบ โดยไม่มี error
--
-- รัน:  psql ... -f /sql/q06_limit_exceeds_ef.sql
--
-- อาการ  : ขอ 100 ได้ 40 · ไม่มี error ไม่มี warning
-- ต้นเหตุ: HNSW คืนผลได้ไม่เกินขนาด candidate list ซึ่ง ef_search กำหนดไว้
--          ค่าเริ่มต้นของ pgvector คือ 40
--
-- ⭐ ต่างจาก Q01 ตรงที่ Q01 คือ "ผลที่ได้ผิด" ส่วน Q06 คือ "ผลหายไปเลย"
--    Q01 ได้ครบ k แถว แต่บางแถวไม่ใช่คำตอบที่ถูก
--    Q06 ได้ไม่ครบ k แถวตั้งแต่แรก
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_q06_idx;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';                      -- กฎเหล็กข้อ 9
SET max_parallel_workers_per_gather = 0;

-- ============================================================
-- ด่านตรวจ
-- ============================================================
DO $$
DECLARE fp text; n int;
BEGIN
    SELECT value INTO fp FROM qf_manifest WHERE item = 'query_set_fingerprint';
    IF fp IS DISTINCT FROM '607babfb6344eab74d3e76496b04fa9f' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: fingerprint ชุด query ไม่ตรง (ได้ %)', fp;
    END IF;
    SELECT count(*) INTO n FROM qf_truth WHERE k = 100;
    IF n <> 200 THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: เฉลย k=100 มี % แถว (ต้อง 200)', n;
    END IF;
    RAISE NOTICE 'ด่านตรวจผ่าน';
END $$;

DROP TABLE IF EXISTS qf_q06_rows;
CREATE TABLE qf_q06_rows (
    ef_search   int,
    requested_k int,
    rows_min    int,
    rows_max    int,
    rows_avg    numeric,
    got_error   boolean
);

DROP TABLE IF EXISTS qf_q06_recall;
CREATE TABLE qf_q06_recall (
    ef_search   int,
    k           int,
    mean_recall numeric,
    min_recall  numeric,
    n_perfect   int
);

SET temp_file_limit = '2GB';
SET maintenance_work_mem = '256MB';
DROP INDEX IF EXISTS qf_q06_idx;
CREATE INDEX qf_q06_idx ON qf_corpus USING hnsw (embedding vector_cosine_ops);
RESET temp_file_limit;

-- ============================================================
-- ส่วนที่ 1 — นับจำนวนแถวที่ได้จริง เทียบกับที่ขอ
--
-- ส่วนนี้ **ไม่ต้องใช้เฉลยเลย** เพราะไม่ได้วัดคุณภาพ
-- วัดแค่ว่า "ขอ k แถว ได้กี่แถว" ซึ่งเป็นข้อเท็จจริงล้วน
-- ============================================================
CREATE OR REPLACE FUNCTION qf_q06_count_rows(p_ef int, p_k int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    lo int; hi int; av numeric; err boolean := false;
BEGIN
    PERFORM set_config('hnsw.ef_search', p_ef::text, false);

    BEGIN
        WITH per_query AS (
            SELECT q.id,
                   (SELECT count(*) FROM (
                        SELECT c.id FROM qf_corpus c
                        ORDER BY c.embedding <=> q.embedding
                        LIMIT p_k) z) AS got
            FROM qf_queries q
        )
        SELECT min(got), max(got), round(avg(got), 1)
          INTO lo, hi, av
        FROM per_query;
    EXCEPTION WHEN OTHERS THEN
        err := true;
    END;

    INSERT INTO qf_q06_rows VALUES (p_ef, p_k, lo, hi, av, err);
END $$;

\qecho
\qecho '=== ส่วนที่ 1: ef_search = 40 (ค่าเริ่มต้น) · ขอ k แถว ได้กี่แถว ==='
SELECT qf_q06_count_rows(40, 10);
SELECT qf_q06_count_rows(40, 20);
SELECT qf_q06_count_rows(40, 39);
SELECT qf_q06_count_rows(40, 40);
SELECT qf_q06_count_rows(40, 41);
SELECT qf_q06_count_rows(40, 60);
SELECT qf_q06_count_rows(40, 100);

SELECT ef_search, requested_k,
       rows_min AS "ได้น้อยสุด", rows_max AS "ได้มากสุด",
       CASE WHEN rows_max < requested_k THEN 'ขาด ' || (requested_k - rows_max) || ' แถว'
            ELSE 'ครบ' END AS "ผล",
       got_error AS "มี error ไหม"
FROM qf_q06_rows ORDER BY requested_k;

-- ============================================================
-- ส่วนที่ 2 — เพิ่ม ef_search แล้วผลกลับมาครบไหม (กลุ่มควบคุม)
-- ============================================================
\qecho
\qecho '=== ส่วนที่ 2: ขอ 100 แถวเสมอ · เปลี่ยน ef_search ==='
DELETE FROM qf_q06_rows WHERE requested_k = 100 AND ef_search <> 40;
SELECT qf_q06_count_rows(100, 100);
SELECT qf_q06_count_rows(200, 100);

SELECT ef_search, requested_k, rows_min AS "ได้น้อยสุด", rows_max AS "ได้มากสุด"
FROM qf_q06_rows WHERE requested_k = 100 ORDER BY ef_search;

-- ============================================================
-- ส่วนที่ 3 — recall@100 ที่ ef_search ต่างๆ
-- ============================================================
\qecho
\qecho '=== ส่วนที่ 3: recall@100 เทียบกับเฉลย exact ==='
DO $$
DECLARE ef int; r record;
BEGIN
    FOREACH ef IN ARRAY ARRAY[40, 100, 200] LOOP
        PERFORM set_config('hnsw.ef_search', ef::text, false);
        SELECT * INTO r FROM qf_recall_at(100);
        INSERT INTO qf_q06_recall VALUES (ef, 100, r.mean_recall, r.min_recall, r.n_perfect);
    END LOOP;
END $$;

SELECT ef_search, k, mean_recall AS "recall@100", min_recall AS "แย่สุด",
       n_perfect AS "ครบ 100/100 กี่ query"
FROM qf_q06_recall ORDER BY ef_search;

DROP INDEX qf_q06_idx;
RESET hnsw.ef_search;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    r40_100 qf_q06_rows%ROWTYPE;
    r40_40  qf_q06_rows%ROWTYPE;
    r200    qf_q06_rows%ROWTYPE;
    rec40   numeric; rec200 numeric;
    n_err   int;
BEGIN
    SELECT * INTO r40_100 FROM qf_q06_rows WHERE ef_search = 40  AND requested_k = 100;
    SELECT * INTO r40_40  FROM qf_q06_rows WHERE ef_search = 40  AND requested_k = 40;
    SELECT * INTO r200    FROM qf_q06_rows WHERE ef_search = 200 AND requested_k = 100;

    -- ข้อ 1: ขอ 100 ที่ ef=40 ต้องได้ไม่ครบ และต้องได้เท่ากับ ef พอดี
    IF r40_100.rows_max >= 100 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: ขอ 100 ที่ ef=40 ได้ % แถว (ต้องได้ไม่ครบ) — fault ไม่เกิด',
            r40_100.rows_max;
    END IF;
    RAISE NOTICE '[1/5] OK ขอ 100 ที่ ef_search=40 ได้แค่ % แถว', r40_100.rows_max;

    IF r40_100.rows_max <> 40 THEN
        RAISE NOTICE '      (หมายเหตุ: ได้ % แถว ไม่ใช่ 40 พอดี — กลไกอาจไม่ตรงที่คิด)',
            r40_100.rows_max;
    ELSE
        RAISE NOTICE '      เพดานเท่ากับ ef_search พอดี → ยืนยันว่า candidate list คือตัวจำกัด';
    END IF;

    -- ข้อ 2: ขอ 40 ที่ ef=40 ต้องได้ครบ (กลุ่มควบคุม — พิสูจน์ว่าไม่ได้พังทุกกรณี)
    IF r40_40.rows_min < 40 THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: ขอ 40 ที่ ef=40 ได้แค่ % แถว — กลไกไม่ตรงที่คิด', r40_40.rows_min;
    END IF;
    RAISE NOTICE '[2/5] OK ขอ 40 ที่ ef_search=40 ได้ครบ 40 แถว → พังเฉพาะตอน k > ef';

    -- ข้อ 3: เพิ่ม ef ให้ >= k แล้วต้องได้ครบ (กลุ่มควบคุม)
    IF r200.rows_min < 100 THEN
        RAISE EXCEPTION 'ข้อ 3 ตก: ที่ ef=200 ขอ 100 ยังได้แค่ % แถว', r200.rows_min;
    END IF;
    RAISE NOTICE '[3/5] OK ที่ ef_search=200 ขอ 100 ได้ครบ 100 แถว → ทางแก้ใช้ได้จริง';

    -- ข้อ 4: ต้องไม่มี error เลยสักกรณี — นี่คือหัวใจของ "ความล้มเหลวเงียบ"
    SELECT count(*) INTO n_err FROM qf_q06_rows WHERE got_error;
    IF n_err > 0 THEN
        RAISE EXCEPTION 'ข้อ 4 ตก: มี error เกิดขึ้น % กรณี — ถ้ามี error แปลว่าไม่เงียบ', n_err;
    END IF;
    RAISE NOTICE '[4/5] OK ไม่มี error เลยสักกรณี → เงียบสนิทตามนิยาม';

    -- ข้อ 5: recall@100 ต้องดีขึ้นชัดเจนเมื่อเพิ่ม ef
    SELECT mean_recall INTO rec40  FROM qf_q06_recall WHERE ef_search = 40;
    SELECT mean_recall INTO rec200 FROM qf_q06_recall WHERE ef_search = 200;
    IF rec200 <= rec40 * 1.5 THEN
        RAISE EXCEPTION 'ข้อ 5 ตก: recall ไม่ดีขึ้นพอ (ef40=% ef200=%)', rec40, rec200;
    END IF;
    RAISE NOTICE '[5/5] OK recall@100 ดีขึ้นจาก % เป็น % เมื่อเพิ่ม ef_search', rec40, rec200;

    RAISE NOTICE 'assertion ผ่านครบ 5 ข้อ';
END $$;

\qecho
\qecho '=== ขอ 100 ได้ 40 · ไม่มี error · ไม่มี warning ==='
\qecho '=== Q01 = ผลที่ได้ผิด · Q06 = ผลหายไปเลยตั้งแต่ต้น ==='
\qecho '=== และตรวจได้แบบ static: เทียบ hnsw.ef_search กับ LIMIT ที่โค้ดใช้ ==='
