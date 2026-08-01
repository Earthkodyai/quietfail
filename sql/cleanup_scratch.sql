-- ============================================================
-- เก็บกวาดตารางทำงานขนาดใหญ่ที่สร้างใหม่ได้
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/cleanup_scratch.sql
--
-- ⚠️ ห้ามแตะฐานที่ล็อกไว้ — qf_corpus · qf_queries · qf_truth · qf_manifest · qf_centroids
--    มี guard ตรวจ fingerprint ก่อนและหลัง ถ้าเปลี่ยนจะหยุดทันที
--
-- ⚠️ เก็บตารางบันทึกผล (ขนาดหลัก kB) ไว้ทั้งหมด เพราะ score.sql อ่านบางตัว
--    และเก็บ qf_v07 · qf_v07r ไว้ เพราะถ้าลบ verdict ของ V07 จะเปลี่ยนจาก
--    DETECTED เป็นอย่างอื่น ซึ่งไม่ตรงกับสภาพสะอาดที่ CLAUDE.md บันทึกไว้
--
-- ⚠️ เก็บ qf_real · qf_real_q · qf_real_truth ไว้ เพราะสร้างใหม่ต้องฝัง embedding ใหม่
--    (ต้องมี sentence-transformers + ดาวน์โหลดชุดข้อมูล ~10 นาที)
-- ============================================================
\timing on
\set ON_ERROR_STOP on

-- ------------------------------------------------------------
-- 0. guard — จดสภาพฐานที่ล็อกไว้
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_cleanup_guard;
CREATE TEMP TABLE qf_cleanup_guard AS
SELECT (SELECT count(*) FROM qf_corpus)                             AS corpus_rows,
       (SELECT count(*) FROM qf_queries)                            AS query_rows,
       (SELECT count(*) FROM qf_truth)                              AS truth_rows,
       (SELECT md5(string_agg(embedding::text, '|' ORDER BY id))
          FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s) AS fp;

DO $$
DECLARE g record;
BEGIN
    SELECT * INTO g FROM qf_cleanup_guard;
    IF g.fp <> '5a32cba54ea2be4ed022fe8bfedae9b0' THEN
        RAISE EXCEPTION 'จุดเริ่มต้นผิด: fingerprint ของ qf_corpus = %', g.fp;
    END IF;
    RAISE NOTICE 'ฐานที่ล็อกไว้ปกติ — corpus % · query % · truth % แถว',
        g.corpus_rows, g.query_rows, g.truth_rows;
END $$;

SELECT pg_size_pretty(sum(pg_total_relation_size(oid))) AS "ขนาดรวมก่อนเก็บกวาด"
FROM pg_class WHERE relkind = 'r' AND relname LIKE 'qf%';

-- ------------------------------------------------------------
-- 1. ตารางทำงานของ corpus สังเคราะห์ — สร้างใหม่จาก qf_corpus ได้
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_i02  CASCADE;   -- ตารางทำงานของ I02
DROP TABLE IF EXISTS qf_q03  CASCADE;   -- ตารางทำงานของ Q03
DROP TABLE IF EXISTS qf_l02  CASCADE;   -- ตารางทำงานของ L02

-- ------------------------------------------------------------
-- 2. corpus "ยากขึ้น" ของ E36 — สร้างใหม่ด้วย sql/i02b_harder_corpus.sql
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_i02b       CASCADE;
DROP TABLE IF EXISTS qf_i02b_truth CASCADE;

-- ------------------------------------------------------------
-- 3. ตารางทำงานของชุด embedding จริง — สร้างใหม่จาก qf_real ได้เร็ว
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_i02r CASCADE;
DROP TABLE IF EXISTS qf_l02r CASCADE;
DROP TABLE IF EXISTS qf_q03r CASCADE;

-- ⭐ ชุด 768 มิติ (รอบแบบจำลองที่สอง) — เพิ่ม 2026-08-02
--    สร้างใหม่ได้เร็วจาก qf_real2 ด้วย sql/real2_{i02,l02,q03}.sql
--    **ห้ามลบ qf_real2 เอง** เพราะต้องฝัง embedding ใหม่ด้วย mpnet (~10 นาที)
--    สามตารางนี้กินรวมกัน 1.2 GB — เป็นสาเหตุหลักที่ฐานโตจาก 411 MB เป็น 2.7 GB
DROP TABLE IF EXISTS qf_i02r2 CASCADE;
DROP TABLE IF EXISTS qf_l02r2 CASCADE;
DROP TABLE IF EXISTS qf_q03r2 CASCADE;
DROP TABLE IF EXISTS qf_q03r2_fix    CASCADE;
DROP TABLE IF EXISTS qf_q03r2_sweep  CASCADE;
DROP TABLE IF EXISTS qf_q03r_fix     CASCADE;
DROP TABLE IF EXISTS qf_q03r_sweep   CASCADE;

-- ------------------------------------------------------------
-- 4. พิสูจน์ว่าฐานที่ล็อกไว้ไม่ถูกแตะ
-- ------------------------------------------------------------
DO $$
DECLARE g record; now_fp text; n_c bigint; n_q bigint; n_t bigint;
BEGIN
    SELECT * INTO g FROM qf_cleanup_guard;
    SELECT count(*) INTO n_c FROM qf_corpus;
    SELECT count(*) INTO n_q FROM qf_queries;
    SELECT count(*) INTO n_t FROM qf_truth;
    SELECT md5(string_agg(embedding::text, '|' ORDER BY id)) INTO now_fp
      FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;

    IF n_c <> g.corpus_rows OR n_q <> g.query_rows OR n_t <> g.truth_rows
       OR now_fp <> g.fp THEN
        RAISE EXCEPTION 'ฐานที่ล็อกไว้เปลี่ยนไป! ก่อน % / % / % / % · หลัง % / % / % / %',
            g.corpus_rows, g.query_rows, g.truth_rows, g.fp, n_c, n_q, n_t, now_fp;
    END IF;
    RAISE NOTICE 'ยืนยัน qf_corpus · qf_queries · qf_truth ไม่ถูกแตะ (fingerprint %)', now_fp;
END $$;

-- ------------------------------------------------------------
-- 5. ต้องไม่มี vector index ค้าง (กับดักข้อ 4)
-- ------------------------------------------------------------
DO $$
DECLARE n_idx int;
BEGIN
    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE 'ไม่มี vector index ค้าง';
END $$;

SELECT pg_size_pretty(sum(pg_total_relation_size(oid))) AS "ขนาดรวมหลังเก็บกวาด"
FROM pg_class WHERE relkind = 'r' AND relname LIKE 'qf%';
