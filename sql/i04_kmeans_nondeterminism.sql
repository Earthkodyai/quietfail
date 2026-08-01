-- ============================================================
-- I04 — สร้าง index ใหม่แล้วได้คำตอบไม่เหมือนเดิม
--
-- ⚠️ **ชื่อไฟล์ล้าสมัย** — ตั้งชื่อว่า kmeans ตอนที่ยังเชื่อว่า k-means ของ IVFFlat
--    เป็นต้นเหตุ · E32 หักล้างแล้วด้วยกลุ่มควบคุม (HNSW ไม่มี k-means แต่ก็แกว่ง)
--    **ไม่เปลี่ยนชื่อไฟล์** เพราะ groundtruth/i04.json · audit_baseline.json
--    และ results/ หลายไฟล์อ้างชื่อนี้อยู่ การเปลี่ยนมีความเสี่ยงมากกว่าประโยชน์
--
-- รัน:  psql ... -f /sql/i04_kmeans_nondeterminism.sql
--
-- ⭐ ข้อนี้พิเศษกว่าอีก 11 ข้อ
--    `EVIDENCE.md` บอกว่า 11 จาก 12 ข้อยืนยันได้จากเอกสารทางการ
--    **I04 เป็นข้อเดียวที่เอกสารไม่พูดถึงเลย** — ไม่มีที่ไหนรับประกันว่า
--    สร้าง index ใหม่บนข้อมูลเดิมแล้วจะได้ผลเหมือนเดิม และไม่มีที่ไหนเตือนว่าจะไม่เหมือน
--    จึงต้องพิสูจน์ด้วยการรันล้วนๆ (กฎเหล็กข้อ 1 — ให้ผลรันจริงเป็นคนตัดสิน)
--
--    📌 ข้อความข้างบนยังถูกต้อง แต่ต้องอ่านให้แคบ (E41 · 2026-07-31)
--    **กลไกทราบแล้วจากซอร์ส** — HNSW สุ่มระดับชั้นให้ทุกจุดตอน build
--    (`int level = (int)(-log(RandomDouble()) * ml)` ใน hnswutils.c)
--    ที่เอกสารเงียบคือ **การรับประกันว่า build ซ้ำได้** ไม่ใช่ตัวกลไก
--
-- คำถาม: ข้อมูลเดิมเป๊ะ พารามิเตอร์เดิมเป๊ะ สร้าง index ใหม่ 5 รอบ
--         ได้คำตอบเหมือนเดิมไหม
--
-- ต้องมีกลุ่มควบคุม 2 ชั้น ไม่งั้นสรุปสาเหตุไม่ได้:
--
--   ควบคุม ก) วัดซ้ำบน index ตัวเดิม 2 ครั้ง
--             ถ้าต่างกัน = ฝั่ง query เองก็ไม่แน่นอน → โทษ build ไม่ได้
--
--   ควบคุม ข) ทำแบบเดียวกันกับ HNSW 5 รอบ
--             ถ้า HNSW แกว่งด้วย = "สร้าง index ใหม่ก็แกว่ง" ทั่วไป
--             ถ้า HNSW นิ่ง = ชี้ไปที่ k-means ของ IVFFlat โดยเฉพาะ
--
-- ⚠️ ไม่แตะ qf_corpus — ตรวจจำนวนแถวและ fingerprint ก่อน/หลัง
-- ============================================================

\set ON_ERROR_STOP on
\timing off
LOAD 'vector';

-- กับดักข้อ 4 — รอบที่ตายกลางคันทิ้ง state ค้าง
DROP INDEX IF EXISTS qf_i04_idx;
DROP TABLE IF EXISTS qf_i04_obs;
DROP TABLE IF EXISTS qf_i04_meta;
DROP TABLE IF EXISTS qf_i04_guard;

CREATE TABLE qf_i04_guard AS
SELECT count(*) AS rows_before,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS fp_before
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;

-- recall ราย query เก็บไว้ทุกตัว ไม่ใช่แค่ค่าเฉลี่ย
-- **ค่าเฉลี่ยนิ่งแต่ราย query สลับกัน = ยังพังอยู่** ซึ่งค่าเฉลี่ยมองไม่เห็น
CREATE TABLE qf_i04_obs (
    build_no   int,
    kind       text,
    param      text,
    pass_no    int,      -- ควบคุม ก: วัดซ้ำบน index ตัวเดิม
    query_id   int,
    recall     numeric
);

CREATE TABLE qf_i04_meta (
    build_no      int,
    kind          text,
    build_ms      numeric,
    index_size    text,
    relfilenode   oid,    -- ใช้เป็นฐานของตัวตรวจ: rebuild แล้วเลขนี้เปลี่ยนไหม
    n_parallel    int
);

\qecho '=== สภาพแวดล้อมที่ใช้วัด (บันทึกไว้เพราะอาจเป็นตัวแปรแฝง) ==='
SELECT current_setting('maintenance_work_mem')            AS mwm,
       current_setting('max_parallel_maintenance_workers') AS par_maint,
       current_setting('max_parallel_workers_per_gather')  AS par_gather,
       (SELECT count(*) FROM qf_corpus)                    AS corpus_rows;

-- ============================================================
-- ตัววัด: สร้าง index หนึ่งรอบ แล้ววัด recall ราย query
-- ============================================================
CREATE OR REPLACE FUNCTION qf_i04_build_and_measure(
    p_build_no int,
    p_kind     text,     -- 'ivfflat' หรือ 'hnsw'
    p_passes   int       -- วัดซ้ำกี่ครั้งบน index ตัวเดียวกัน
) RETURNS void AS $$
DECLARE
    t0     timestamptz;
    ms     numeric;
    rfn    oid;
    sz     text;
    npar   int;
    pass   int;
    prm    text;
    prm_v  int;
    params int[];
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i04_idx';

    -- กับดักข้อ 8 — IVFFlat build ชน temp_file_limit ของโปรไฟล์ fragile
    PERFORM set_config('temp_file_limit', '2GB', true);

    t0 := clock_timestamp();
    IF p_kind = 'ivfflat' THEN
        EXECUTE 'CREATE INDEX qf_i04_idx ON qf_corpus '
                'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    ELSE
        EXECUTE 'CREATE INDEX qf_i04_idx ON qf_corpus '
                'USING hnsw (embedding vector_cosine_ops)';
    END IF;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    SELECT c.relfilenode, pg_size_pretty(pg_relation_size(c.oid))
      INTO rfn, sz
      FROM pg_class c WHERE c.relname = 'qf_i04_idx';

    npar := current_setting('max_parallel_maintenance_workers')::int;

    INSERT INTO qf_i04_meta
    VALUES (p_build_no, p_kind, round(ms, 1), sz, rfn, npar);

    -- กฎเหล็กข้อ 8 — อุ่น cache ก่อนวัด รอบแรกหลัง CREATE INDEX จะมี read=
    PERFORM count(*) FROM (
        SELECT c.id FROM qf_corpus c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1)
        LIMIT 10) w;

    -- IVFFlat วัดที่ probes 1 (ค่าเริ่มต้น) และ 5 (ค่าที่ Q04 พบว่าได้ recall เต็ม)
    -- HNSW วัดที่ ef_search 40 (ค่าเริ่มต้น) และ 200
    IF p_kind = 'ivfflat' THEN
        params := ARRAY[1, 5];
    ELSE
        params := ARRAY[40, 200];
    END IF;

    FOREACH prm_v IN ARRAY params LOOP
        IF p_kind = 'ivfflat' THEN
            PERFORM set_config('ivfflat.probes', prm_v::text, true);
            prm := 'probes=' || prm_v;
        ELSE
            PERFORM set_config('hnsw.ef_search', prm_v::text, true);
            prm := 'ef_search=' || prm_v;
        END IF;

        FOR pass IN 1 .. p_passes LOOP
            INSERT INTO qf_i04_obs (build_no, kind, param, pass_no, query_id, recall)
            SELECT p_build_no, p_kind, prm, pass, t.query_id,
                   (
                       SELECT count(*)
                       FROM unnest(t.ids) AS truth_id
                       WHERE truth_id = ANY (
                           SELECT c.id FROM qf_corpus c
                           ORDER BY c.embedding <=> q.embedding
                           LIMIT 10
                       )
                   )::numeric / 10
            FROM qf_truth t
            JOIN qf_queries q ON q.id = t.query_id
            WHERE t.k = 10;
        END LOOP;
    END LOOP;
END $$ LANGUAGE plpgsql;

-- ============================================================
-- IVFFlat 5 รอบ · รอบที่ 1 วัดซ้ำ 2 ครั้ง (ควบคุม ก)
-- ============================================================
\qecho ''
\qecho '=== IVFFlat — สร้างใหม่ 5 รอบ ข้อมูลเดิม พารามิเตอร์เดิม ==='
SELECT qf_i04_build_and_measure(1, 'ivfflat', 2);
SELECT qf_i04_build_and_measure(2, 'ivfflat', 1);
SELECT qf_i04_build_and_measure(3, 'ivfflat', 1);
SELECT qf_i04_build_and_measure(4, 'ivfflat', 1);
SELECT qf_i04_build_and_measure(5, 'ivfflat', 1);

\qecho ''
\qecho '=== HNSW — กลุ่มควบคุม ข · 5 รอบเหมือนกัน ==='
SELECT qf_i04_build_and_measure(1, 'hnsw', 2);
SELECT qf_i04_build_and_measure(2, 'hnsw', 1);
SELECT qf_i04_build_and_measure(3, 'hnsw', 1);
SELECT qf_i04_build_and_measure(4, 'hnsw', 1);
SELECT qf_i04_build_and_measure(5, 'hnsw', 1);

-- ============================================================
-- ผล
-- ============================================================
\qecho ''
\qecho '=== ควบคุม ก: วัดซ้ำบน index ตัวเดิม 2 ครั้ง (build 1) ==='
\qecho '    ต้องเหมือนกันเป๊ะ ไม่งั้นความแกว่งอาจมาจากฝั่ง query ไม่ใช่ฝั่ง build'
SELECT kind, param,
       count(*) FILTER (WHERE r1 IS DISTINCT FROM r2) AS query_ที่ต่างกัน,
       CASE WHEN count(*) FILTER (WHERE r1 IS DISTINCT FROM r2) = 0
            THEN 'เหมือนกันทุก query -> ฝั่ง query นิ่ง'
            ELSE 'ต่างกัน -> สรุปไม่ได้' END AS ผล
FROM (
    SELECT kind, param, query_id,
           max(recall) FILTER (WHERE pass_no = 1) AS r1,
           max(recall) FILTER (WHERE pass_no = 2) AS r2
    FROM qf_i04_obs WHERE build_no = 1 GROUP BY kind, param, query_id
) s GROUP BY kind, param ORDER BY kind, param;

\qecho ''
\qecho '=== ค่าเฉลี่ยต่อ build (สิ่งที่ทีมทั่วไปมองเห็น) ==='
SELECT kind, param, build_no,
       round(avg(recall), 4) AS mean_recall,
       round(min(recall), 4) AS worst,
       count(*) FILTER (WHERE recall = 1.0) AS ครบ_10_10
FROM qf_i04_obs WHERE pass_no = 1
GROUP BY kind, param, build_no ORDER BY kind, param, build_no;

\qecho ''
\qecho '=== ช่วงการแกว่งข้าม 5 build ==='
SELECT kind, param,
       round(min(m), 4) AS ต่ำสุด, round(max(m), 4) AS สูงสุด,
       round(max(m) - min(m), 4) AS ช่วง,
       round((max(m) - min(m)) / nullif(avg(m), 0) * 100, 1) AS ร้อยละ
FROM (
    SELECT kind, param, build_no, avg(recall) AS m
    FROM qf_i04_obs WHERE pass_no = 1
    GROUP BY kind, param, build_no
) s GROUP BY kind, param ORDER BY kind, param;

\qecho ''
\qecho '=== ⭐ ราย query — สิ่งที่ค่าเฉลี่ยซ่อนไว้ ==='
\qecho '    query กี่ข้อที่ได้คำตอบไม่เท่ากันข้าม build'
SELECT kind, param,
       count(*)                                        AS query_ทั้งหมด,
       count(*) FILTER (WHERE n_distinct_vals > 1)     AS query_ที่เปลี่ยนคำตอบ,
       round(100.0 * count(*) FILTER (WHERE n_distinct_vals > 1) / count(*), 1) AS ร้อยละ,
       round(max(spread), 4)                           AS แกว่งมากสุดต่อ_query
FROM (
    SELECT kind, param, query_id,
           count(DISTINCT recall) AS n_distinct_vals,
           max(recall) - min(recall) AS spread
    FROM qf_i04_obs WHERE pass_no = 1
    GROUP BY kind, param, query_id
) s GROUP BY kind, param ORDER BY kind, param;

\qecho ''
\qecho '=== relfilenode เปลี่ยนทุก build ไหม (ฐานของตัวตรวจ) ==='
SELECT kind, count(DISTINCT relfilenode) AS relfilenode_ที่ต่างกัน,
       count(*) AS จำนวน_build,
       round(avg(build_ms), 1) AS build_ms_เฉลี่ย,
       max(index_size) AS ขนาด
FROM qf_i04_meta GROUP BY kind ORDER BY kind;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
\qecho ''
\qecho '=== assertion ==='
DO $$
DECLARE
    n_same_pass  int;
    ivf_spread   numeric;
    hnsw_spread  numeric;
    ivf_qchange  int;
    hnsw_qchange int;
    n_rfn        int;
    rows_now     bigint;
    fp_now       text;
    g            record;
BEGIN
    -- 1) ควบคุม ก — ฝั่ง query ต้องนิ่ง
    SELECT count(*) INTO n_same_pass FROM (
        SELECT query_id FROM qf_i04_obs WHERE build_no = 1
        GROUP BY kind, param, query_id
        HAVING count(DISTINCT recall) > 1
    ) s;
    IF n_same_pass > 0 THEN
        RAISE EXCEPTION 'ควบคุม ก ล้ม: วัดซ้ำบน index ตัวเดิมได้ผลต่างกัน % query '
                        '— สรุปไม่ได้ว่าความแกว่งมาจาก build', n_same_pass;
    END IF;
    RAISE NOTICE '[1/5] ✅ ควบคุม ก ผ่าน — วัดซ้ำบน index ตัวเดิมได้ผลเหมือนกันทุก query';

    -- 2) IVFFlat ต้องแกว่งจริง ไม่งั้น fault ไม่เกิด
    SELECT max(m) - min(m) INTO ivf_spread FROM (
        SELECT build_no, avg(recall) AS m FROM qf_i04_obs
        WHERE kind = 'ivfflat' AND param = 'probes=1' AND pass_no = 1
        GROUP BY build_no) s;
    IF ivf_spread IS NULL OR ivf_spread = 0 THEN
        RAISE EXCEPTION 'IVFFlat ไม่แกว่งเลยข้าม 5 build — fault ไม่เกิดตามที่ตั้งใจ';
    END IF;
    RAISE NOTICE '[2/5] ✅ IVFFlat แกว่งจริง — ช่วง recall เฉลี่ย % ข้าม 5 build',
                 round(ivf_spread, 4);

    -- 3) ต้องมี query ที่เปลี่ยนคำตอบจริง ไม่ใช่แค่ค่าเฉลี่ยขยับ
    SELECT count(*) INTO ivf_qchange FROM (
        SELECT query_id FROM qf_i04_obs
        WHERE kind = 'ivfflat' AND param = 'probes=1' AND pass_no = 1
        GROUP BY query_id HAVING count(DISTINCT recall) > 1) s;
    IF ivf_qchange = 0 THEN
        RAISE EXCEPTION 'ไม่มี query ไหนเปลี่ยนคำตอบเลย — ขัดกับค่าเฉลี่ยที่ขยับ';
    END IF;
    RAISE NOTICE '[3/5] ✅ มี % query ที่ได้คำตอบไม่เท่ากันข้าม build', ivf_qchange;

    -- 4) relfilenode ต้องเปลี่ยนทุก build (ฐานของตัวตรวจ)
    SELECT count(DISTINCT relfilenode) INTO n_rfn
    FROM qf_i04_meta WHERE kind = 'ivfflat';
    IF n_rfn < 5 THEN
        RAISE EXCEPTION 'relfilenode ซ้ำกัน (% ค่าจาก 5 build) — ตัวตรวจใช้ฐานนี้ไม่ได้', n_rfn;
    END IF;
    RAISE NOTICE '[4/5] ✅ relfilenode เปลี่ยนทุก build (5 ค่าไม่ซ้ำ) — ตัวตรวจใช้ได้';

    -- 5) qf_corpus ต้องไม่ถูกแตะ
    SELECT count(*), md5(string_agg(embedding::text, '|' ORDER BY id))
      INTO rows_now, fp_now
      FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
    SELECT * INTO g FROM qf_i04_guard;
    IF rows_now <> g.rows_before OR fp_now <> g.fp_before THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยน! แถว %->%  fingerprint %->%',
                        g.rows_before, rows_now, g.fp_before, fp_now;
    END IF;
    RAISE NOTICE '[5/5] ✅ qf_corpus ไม่ถูกแตะ — % แถวแรก fingerprint เดิม', rows_now;

    -- ข้อสังเกตของกลุ่มควบคุม ข (ไม่ใช่ assertion เพราะยังไม่รู้คำตอบ)
    SELECT max(m) - min(m) INTO hnsw_spread FROM (
        SELECT build_no, avg(recall) AS m FROM qf_i04_obs
        WHERE kind = 'hnsw' AND param = 'ef_search=40' AND pass_no = 1
        GROUP BY build_no) s;
    SELECT count(*) INTO hnsw_qchange FROM (
        SELECT query_id FROM qf_i04_obs
        WHERE kind = 'hnsw' AND param = 'ef_search=40' AND pass_no = 1
        GROUP BY query_id HAVING count(DISTINCT recall) > 1) s;
    RAISE NOTICE '';
    RAISE NOTICE 'ควบคุม ข (HNSW): ช่วงแกว่ง % · query ที่เปลี่ยนคำตอบ % ข้อ',
                 round(coalesce(hnsw_spread, 0), 4), hnsw_qchange;
    IF hnsw_spread = 0 AND hnsw_qchange = 0 THEN
        RAISE NOTICE '  -> HNSW นิ่งสนิท : ชี้ไปที่ k-means ของ IVFFlat โดยเฉพาะ';
    ELSE
        RAISE NOTICE '  -> HNSW แกว่งด้วย : ห้ามสรุปว่าเป็นเรื่องของ k-means อย่างเดียว';
    END IF;
END $$;

\qecho ''
\qecho '=== เก็บกวาด: ทิ้ง index ทดสอบ เก็บตารางผลไว้ให้ตัวตรวจอ่าน ==='
DROP INDEX IF EXISTS qf_i04_idx;
DROP TABLE IF EXISTS qf_i04_guard;
DROP FUNCTION IF EXISTS qf_i04_build_and_measure(int, text, int);
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');
