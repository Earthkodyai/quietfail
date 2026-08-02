-- ============================================================
-- RQ3 — เก็บกวาดหลังใช้งาน
--
-- รัน:  psql ... -f /sql/rq3_teardown.sql
--
-- ต้องเก็บกวาดเพราะสภาพสะอาดที่ทั้งโปรเจคใช้อ้างอิงคือ **ไม่มี vector index ค้าง**
-- ถ้าปล่อย index ของ RQ3 ไว้ `scripts/audit.py` จะรายงานว่ามี index ค้างทุกครั้ง
-- แล้วคนอ่านจะแยกไม่ออกว่าเป็นของ RQ3 หรือเป็นรอบทดลองที่ตายกลางคัน (กับดักข้อ 4)
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS search_queries CASCADE;

-- 🔴 เดิมบล็อกนี้ **พิมพ์ตัวเลขออกมาเฉยๆ ไม่ได้ตรวจ** (แก้ 2026-08-02)
--    ทั้งที่หัวไฟล์อธิบายเองว่าถ้าเหลือ index ค้าง audit จะรายงานผิดทุกครั้ง
--    ถ้า DROP ไม่สำเร็จ มันก็พิมพ์ "1" แล้วจบด้วย exit 0 เหมือนตอนสำเร็จ
--    = รูปแบบเดียวกับ *_checker_states ก่อนแก้ · เงียบ ≠ ผ่าน
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');

SELECT count(*) AS corpus_rows, qf_fingerprint('qf_corpus') AS corpus_fingerprint
FROM qf_corpus;

DO $$
DECLARE n int; fp text; want text; n_tab int;
BEGIN
    SELECT count(*) INTO n FROM pg_class c JOIN pg_am a ON a.oid = c.relam
     WHERE a.amname IN ('hnsw','ivfflat');
    IF n > 0 THEN
        RAISE EXCEPTION 'เก็บกวาดไม่สำเร็จ: ยังมี vector index ค้าง % ตัว '
                        '— audit.py จะรายงานผิดทุกครั้งจนกว่าจะลบ', n;
    END IF;

    SELECT count(*) INTO n_tab FROM pg_class
     WHERE relname IN ('documents','search_queries') AND relkind = 'r';
    IF n_tab > 0 THEN
        RAISE EXCEPTION 'เก็บกวาดไม่สำเร็จ: ตารางของ RQ3 ยังเหลือ % ตัว', n_tab;
    END IF;

    fp := qf_fingerprint('qf_corpus');
    SELECT value INTO want FROM qf_manifest WHERE item = 'corpus_fingerprint_first5k';
    IF fp IS DISTINCT FROM want THEN
        RAISE EXCEPTION E'qf_corpus ถูกแตะ!
  ได้   : %
  ต้องได้: %', fp, want;
    END IF;

    RAISE NOTICE 'เก็บกวาดครบ — ไม่มี index ค้าง · ไม่มีตาราง RQ3 เหลือ · qf_corpus เดิม';
END $$;

\qecho '✅ เก็บกวาดครบ'
