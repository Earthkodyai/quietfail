-- ============================================================
-- I04 ควบคุม ค — ปิด parallel build แล้วยังแกว่งอยู่ไหม
--
-- รัน:  psql ... -f /sql/i04_parallel_control.sql
--       (ต้องรัน i04_kmeans_nondeterminism.sql ก่อน เพราะใช้ตารางผลร่วมกัน)
--
-- ทำไมต้องมี:
--   รอบแรกพบว่า **HNSW ก็แกว่ง** ทั้งที่ HNSW ไม่มี k-means เลย
--   ชื่อ fault เดิมใน FAULTS.md คือ "k-means ของ IVFFlat สุ่ม" จึงอธิบายไม่ครบ
--
--   สมมติฐานที่ต้องแยก: parallel build ทำให้ลำดับการใส่ข้อมูลไม่แน่นอน
--   ซึ่งกระทบ HNSW โดยตรง (กราฟขึ้นกับลำดับ) และอาจกระทบ IVFFlat ด้วย
--
--   max_parallel_maintenance_workers = 2 ตอนรอบแรก → ตั้งเป็น 0 แล้ววัดใหม่
--
--   ถ้า HNSW นิ่งลงแต่ IVFFlat ยังแกว่ง = สองกลไกคนละตัว
--   ถ้านิ่งทั้งคู่                      = parallel build เป็นต้นเหตุร่วม
--   ถ้าแกว่งทั้งคู่                     = ไม่ใช่เรื่อง parallel
--
-- ⚠️ ห้ามเดาคำตอบล่วงหน้า (กฎเหล็กข้อ 1) — สคริปต์นี้รายงานทั้งสามทาง
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_i04_idx;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';

DROP INDEX IF EXISTS qf_i04_idx;
DROP TABLE IF EXISTS qf_i04_ser;
DROP TABLE IF EXISTS qf_i04p_guard;

-- ด่านกัน qf_corpus ถูกแตะ — ฝาแฝด i04_kmeans_nondeterminism.sql มีแล้ว
-- ไฟล์นี้ไม่เคยมี ทั้งที่สร้าง index บนตารางเดียวกัน (กับดักข้อ 14บ · เพิ่ม 2026-08-02)
-- ⚠️ ต้องมี FROM qf_corpus — เขียนครั้งแรกลืมไป แล้ว count(*) คืน 1 (ไม่ใช่ 100,000)
--    ด่านจึงฟ้องว่า "qf_corpus เปลี่ยน! แถว 1->100000" ทั้งที่ fingerprint ตรงเป๊ะ
--    = ด่านที่เพิ่งเขียนเพื่อจับความล้มเหลวเงียบ กลับให้ผลบวกลวงเสียเอง
CREATE TABLE qf_i04p_guard AS
SELECT count(*) AS rows_before, qf_fingerprint('qf_corpus') AS fp_before
FROM qf_corpus;

CREATE TABLE qf_i04_ser (
    build_no int, kind text, query_id int, recall numeric, build_ms numeric
);

-- ปิด parallel ทั้งฝั่ง build — ตัวแปรเดียวที่เปลี่ยนจากรอบแรก
SET max_parallel_maintenance_workers = 0;

\qecho '=== ยืนยันว่าปิด parallel แล้วจริง ==='
SELECT current_setting('max_parallel_maintenance_workers') AS par_maint_now,
       current_setting('maintenance_work_mem')             AS mwm;

-- 🔴 เดิม**พิมพ์ค่าออกมาเฉยๆ ไม่ได้ตรวจ** — ถ้าตั้งไม่ติด กลุ่มควบคุมทั้งไฟล์เป็นโมฆะ
--    โดยไม่มีอะไรบอก · ตัวแปรเดียวที่ไฟล์นี้เปลี่ยนคือค่านี้ (เพิ่ม 2026-08-02)
DO $$
BEGIN
    IF current_setting('max_parallel_maintenance_workers') <> '0' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: max_parallel_maintenance_workers = % ไม่ใช่ 0 '
                        '— ตัวแปรที่ตั้งใจควบคุมไม่ได้ถูกควบคุม',
                        current_setting('max_parallel_maintenance_workers');
    END IF;
    RAISE NOTICE 'ปิด parallel build แล้วจริง';
END $$;

CREATE OR REPLACE FUNCTION qf_i04_serial_one(p_build int, p_kind text)
RETURNS void AS $$
DECLARE t0 timestamptz; ms numeric;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i04_idx';
    PERFORM set_config('temp_file_limit', '2GB', true);

    t0 := clock_timestamp();
    IF p_kind = 'ivfflat' THEN
        EXECUTE 'CREATE INDEX qf_i04_idx ON qf_corpus '
                'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
        PERFORM set_config('ivfflat.probes', '1', true);
    ELSE
        EXECUTE 'CREATE INDEX qf_i04_idx ON qf_corpus '
                'USING hnsw (embedding vector_cosine_ops)';
        PERFORM set_config('hnsw.ef_search', '40', true);
    END IF;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    -- กฎเหล็กข้อ 8 — อุ่น cache ก่อนวัด
    PERFORM count(*) FROM (
        SELECT c.id FROM qf_corpus c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1)
        LIMIT 10) w;

    INSERT INTO qf_i04_ser
    SELECT p_build, p_kind, t.query_id,
           (SELECT count(*) FROM unnest(t.ids) AS truth_id
             WHERE truth_id = ANY (SELECT c.id FROM qf_corpus c
                                    ORDER BY c.embedding <=> q.embedding LIMIT 10)
           )::numeric / 10,
           round(ms, 1)
    FROM qf_truth t JOIN qf_queries q ON q.id = t.query_id
    WHERE t.k = 10;
END $$ LANGUAGE plpgsql;

\qecho ''
\qecho '=== IVFFlat 5 รอบ · parallel ปิด ==='
SELECT qf_i04_serial_one(1, 'ivfflat');
SELECT qf_i04_serial_one(2, 'ivfflat');
SELECT qf_i04_serial_one(3, 'ivfflat');
SELECT qf_i04_serial_one(4, 'ivfflat');
SELECT qf_i04_serial_one(5, 'ivfflat');

\qecho ''
\qecho '=== HNSW 5 รอบ · parallel ปิด ==='
SELECT qf_i04_serial_one(1, 'hnsw');
SELECT qf_i04_serial_one(2, 'hnsw');
SELECT qf_i04_serial_one(3, 'hnsw');
SELECT qf_i04_serial_one(4, 'hnsw');
SELECT qf_i04_serial_one(5, 'hnsw');

\qecho ''
\qecho '=== เทียบตรงๆ: parallel เปิด (รอบแรก) vs ปิด (รอบนี้) ==='
WITH par AS (
    SELECT kind,
           round(max(m) - min(m), 4) AS spread,
           (SELECT count(*) FROM (
                SELECT query_id FROM qf_i04_obs o2
                WHERE o2.kind = o.kind AND o2.pass_no = 1
                  AND o2.param IN ('probes=1', 'ef_search=40')
                GROUP BY query_id HAVING count(DISTINCT recall) > 1) x) AS q_changed
    FROM (SELECT kind, build_no, avg(recall) AS m FROM qf_i04_obs
          WHERE pass_no = 1 AND param IN ('probes=1', 'ef_search=40')
          GROUP BY kind, build_no) o
    GROUP BY kind
), ser AS (
    SELECT kind,
           round(max(m) - min(m), 4) AS spread,
           (SELECT count(*) FROM (
                SELECT query_id FROM qf_i04_ser s2 WHERE s2.kind = s.kind
                GROUP BY query_id HAVING count(DISTINCT recall) > 1) y) AS q_changed
    FROM (SELECT kind, build_no, avg(recall) AS m FROM qf_i04_ser
          GROUP BY kind, build_no) s
    GROUP BY kind
)
SELECT par.kind,
       par.spread AS ช่วงแกว่ง_parallel_เปิด,
       ser.spread AS ช่วงแกว่ง_parallel_ปิด,
       par.q_changed AS query_เปลี่ยน_เปิด,
       ser.q_changed AS query_เปลี่ยน_ปิด
FROM par JOIN ser ON ser.kind = par.kind ORDER BY par.kind;

\qecho ''
\qecho '=== ค่าเฉลี่ยต่อ build ตอนปิด parallel ==='
SELECT kind, build_no, round(avg(recall), 4) AS mean_recall,
       round(max(build_ms), 0) AS build_ms
FROM qf_i04_ser GROUP BY kind, build_no ORDER BY kind, build_no;

\qecho ''
\qecho '=== ข้อสรุปที่ข้อมูลรองรับ ==='
DO $$
DECLARE
    ivf_q int; hnsw_q int; n_ivf int; n_hnsw int;
    rows_now bigint; fp_now text; g record;
BEGIN
    -- 🔴 ด่านนี้สำคัญที่สุดในไฟล์ (เพิ่ม 2026-08-02)
    --
    --    ถ้า qf_i04_ser ว่างหรือไม่ครบ ตัวแปร ivf_q กับ hnsw_q จะเป็น 0 ทั้งคู่
    --    แล้วสาขาที่สองข้างล่างจะพิมพ์ข้อสรุปที่ **แรงที่สุด** ของทั้งการทดลอง
    --    คือ "parallel build คือต้นเหตุร่วม ไม่ใช่ k-means"
    --    **จากข้อมูลศูนย์แถว** โดยไม่มีอะไรเตือน
    --
    --    เป็นความล้มเหลวเงียบชนิดเดียวกับที่โครงงานนี้ศึกษาอยู่ · กฎเหล็กข้อ 10
    SELECT count(DISTINCT build_no) INTO n_ivf  FROM qf_i04_ser WHERE kind = 'ivfflat';
    SELECT count(DISTINCT build_no) INTO n_hnsw FROM qf_i04_ser WHERE kind = 'hnsw';
    IF n_ivf < 5 OR n_hnsw < 5 THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: วัดได้ IVFFlat % build · HNSW % build (ต้องอย่างละ 5) '
                        '— ห้ามสรุปว่า "นิ่ง" จากข้อมูลที่ไม่ครบ', n_ivf, n_hnsw;
    END IF;

    SELECT count(*) INTO ivf_q FROM (
        SELECT query_id FROM qf_i04_ser WHERE kind = 'ivfflat'
        GROUP BY query_id HAVING count(DISTINCT recall) > 1) s;
    SELECT count(*) INTO hnsw_q FROM (
        SELECT query_id FROM qf_i04_ser WHERE kind = 'hnsw'
        GROUP BY query_id HAVING count(DISTINCT recall) > 1) s;

    RAISE NOTICE 'ปิด parallel แล้ว: IVFFlat เปลี่ยน % query · HNSW เปลี่ยน % query',
                 ivf_q, hnsw_q;

    IF hnsw_q = 0 AND ivf_q > 0 THEN
        RAISE NOTICE '-> HNSW นิ่งเมื่อปิด parallel แต่ IVFFlat ยังแกว่ง';
        RAISE NOTICE '   = สองกลไกคนละตัว · IVFFlat แกว่งเองโดยไม่ต้องมี parallel';
    ELSIF hnsw_q = 0 AND ivf_q = 0 THEN
        RAISE NOTICE '-> นิ่งทั้งคู่ = parallel build คือต้นเหตุร่วม ไม่ใช่ k-means';
    ELSIF hnsw_q > 0 AND ivf_q > 0 THEN
        RAISE NOTICE '-> แกว่งทั้งคู่แม้ปิด parallel = ไม่ใช่เรื่อง parallel';
    ELSE
        RAISE NOTICE '-> IVFFlat นิ่งแต่ HNSW แกว่ง = ผลกลับด้านจากที่ตั้งสมมติฐานไว้';
    END IF;

    -- qf_corpus ต้องไม่ถูกแตะ
    SELECT count(*) INTO rows_now FROM qf_corpus;
    fp_now := qf_fingerprint('qf_corpus');
    SELECT * INTO g FROM qf_i04p_guard;
    IF rows_now <> g.rows_before OR fp_now IS DISTINCT FROM g.fp_before THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยน! แถว %->% fingerprint %->%',
                        g.rows_before, rows_now, g.fp_before, fp_now;
    END IF;
    RAISE NOTICE 'qf_corpus ไม่ถูกแตะ (% แถว · fingerprint เดิม)', rows_now;
END $$;

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_i04_idx;
DROP TABLE IF EXISTS qf_i04p_guard;
DROP FUNCTION IF EXISTS qf_i04_serial_one(int, text);
RESET max_parallel_maintenance_workers;
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');
