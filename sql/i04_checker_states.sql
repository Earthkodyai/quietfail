-- ============================================================
-- I04 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ (สูตรข้อ 6)
--
-- รัน:  psql ... -f /sql/i04_checker_states.sql
--
-- ตัวตรวจของ I04 ไม่ได้ถามว่า "ใช้ IVFFlat อยู่ไหม" — ถ้าถามแบบนั้นมันจะตอบ
-- DETECTED ตลอดกาล และตัวนับที่ไม่มีวันตอบลบ = ไม่ได้วัดอะไรเลย
--
-- มันถามว่า **ตัวเลข recall ที่ทีมถืออยู่ วัดบน index ตัวปัจจุบันหรือเปล่า**
-- ใช้ relfilenode เป็นตัวชี้ตัวตนของ build (สร้างใหม่ทีไรเลขเปลี่ยนทุกครั้ง)
--
-- ⚠️ ไม่แตะ qf_corpus — สร้าง/ทิ้ง index เท่านั้น
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_i04_idx;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';

\i /sql/states_lib.sql

DROP INDEX IF EXISTS qf_i04_idx;
DROP TABLE IF EXISTS qf_i04_record;

\qecho '=== สถานะ 1: ไม่มี index และไม่เคยจดว่าวัด recall ไว้บน build ไหน ==='
\qecho '    -> CANNOT_CHECK  (ไม่ใช่ "ผ่าน" — ทีมที่ไม่เคยจดคือทีมที่เสี่ยงที่สุด)'
\i /sql/score.sql
\set note 'ไม่มี index และไม่เคยจดว่าวัด recall บน build ไหน'
\i /sql/states_capture.sql

\qecho ''
\qecho '=== สร้าง index แล้วจดไว้ว่า recall วัดบน build นี้ ==='
SET temp_file_limit = '2GB';
CREATE INDEX qf_i04_idx ON qf_corpus USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

CREATE TABLE qf_i04_record (
    index_name   text,
    relfilenode  oid,
    mean_recall  numeric,
    measured_at  timestamptz DEFAULT now()
);

SET ivfflat.probes = 1;

INSERT INTO qf_i04_record (index_name, relfilenode, mean_recall)
SELECT 'qf_i04_idx',
       (SELECT relfilenode FROM pg_class WHERE relname = 'qf_i04_idx'),
       round(avg(r), 4)
FROM (
    SELECT (SELECT count(*) FROM unnest(t.ids) AS truth_id
             WHERE truth_id = ANY (SELECT c.id FROM qf_corpus c
                                    ORDER BY c.embedding <=> q.embedding LIMIT 10)
           )::numeric / 10 AS r
    FROM qf_truth t JOIN qf_queries q ON q.id = t.query_id
    WHERE t.k = 10
) s;

SELECT index_name, relfilenode, mean_recall FROM qf_i04_record;

\qecho ''
\qecho '=== สถานะ 2: index ยังเป็น build เดิมที่วัด recall ไว้ -> NOT_DETECTED ==='
\i /sql/score.sql
\set note 'index ยังเป็น build เดิมที่จดไว้'
\i /sql/states_capture.sql

\qecho ''
\qecho '=== สร้าง index ใหม่ โดยไม่วัด recall ใหม่ — คือสิ่งที่ทีมทำจริงตอน reindex ==='
DROP INDEX qf_i04_idx;
CREATE INDEX qf_i04_idx ON qf_corpus USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

SELECT (SELECT relfilenode FROM qf_i04_record)                       AS relfilenode_ที่จดไว้,
       (SELECT relfilenode FROM pg_class WHERE relname='qf_i04_idx') AS relfilenode_ตอนนี้;

\qecho ''
\qecho '=== สถานะ 3: index ถูกสร้างใหม่หลังวัด -> DETECTED ==='
\qecho '    ตัวเลข recall ที่ทีมถืออยู่ อธิบาย index ตัวที่ใช้จริงไม่ได้แล้ว'
\i /sql/score.sql
\set note 'สร้าง index ใหม่หลังวัด recall'
\i /sql/states_capture.sql

\set expect 'CANNOT_CHECK,NOT_DETECTED,DETECTED'
\i /sql/states_assert.sql

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_i04_idx;
DROP TABLE IF EXISTS qf_i04_record;
RESET ivfflat.probes;
RESET temp_file_limit;

-- ============================================================
-- ด่านปิดท้าย — เดิมพิมพ์ตัวเลขออกมาเฉยๆ ไม่ได้ตรวจอะไร (แก้ 2026-08-02)
-- ใช้ qf_fingerprint() แทนการเขียนสูตรเอง (E40)
-- ============================================================
DO $$
DECLARE n int; fp text; want text;
BEGIN
    SELECT count(*) INTO n FROM pg_class c JOIN pg_am a ON a.oid = c.relam
    WHERE a.amname IN ('hnsw','ivfflat');
    IF n > 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว — ต้องไม่เหลือเลยหลังไฟล์นี้จบ', n;
    END IF;

    fp   := qf_fingerprint('qf_corpus');
    SELECT value INTO want FROM qf_manifest WHERE item = 'corpus_fingerprint_first5k';
    IF fp IS DISTINCT FROM want THEN
        RAISE EXCEPTION E'qf_corpus ถูกแตะ!
  ได้   : %
  ต้องได้: %', fp, want;
    END IF;
    RAISE NOTICE 'ไม่มี index ค้าง · qf_corpus fingerprint เดิม';
END $$;

\qecho '✅ เก็บกวาดครบ · qf_corpus ไม่ถูกแตะ'
