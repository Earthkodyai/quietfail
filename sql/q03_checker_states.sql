-- ============================================================
-- Q03 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ (สูตรข้อ 6)
--
-- รัน:  psql ... -f /sql/q03_checker_states.sql
--
-- ตัวตรวจของ Q03 **ไม่ต้องรู้เฉลย** — แค่เทียบ
--   "จำนวนแถวที่เข้าเงื่อนไข filter" กับ "จำนวนแถวที่ query คืนมาจริง"
-- ถ้ามีแถวเข้าเงื่อนไขเกิน k แต่ได้คืนไม่ถึง k = ผลหายไปแน่นอน
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

\i /sql/states_lib.sql

DROP INDEX IF EXISTS qf_q03_idx;
DROP TABLE IF EXISTS qf_q03;

\qecho '=== สถานะ 1: ยังไม่มีตาราง -> CANNOT_CHECK ==='
\i /sql/score.sql
\set note 'ยังไม่มีตาราง'
\i /sql/states_capture.sql

\qecho ''
\qecho '=== สร้างตารางและ hnsw index ==='
CREATE TABLE qf_q03 (id int PRIMARY KEY, grp int, embedding vector(384));
INSERT INTO qf_q03 SELECT id, id % 1000, embedding FROM qf_corpus;
ANALYZE qf_q03;
CREATE INDEX qf_q03_idx ON qf_q03 USING hnsw (embedding vector_cosine_ops);

SELECT count(*) AS แถวที่เข้าเงื่อนไข_grp_lt_10 FROM qf_q03 WHERE grp < 10;

\qecho ''
\qecho '=== สถานะ 2: ค่าเริ่มต้น (iterative_scan = off) -> DETECTED ==='
\qecho '    มีแถวเข้าเงื่อนไข 1,000 แถว แต่ขอ 10 จะได้ไม่ครบ'
\i /sql/score.sql
\set note 'ค่าเริ่มต้น iterative_scan = off'
\i /sql/states_capture.sql

\qecho ''
\qecho '=== เปิดทางแก้ให้ครบ: iterative_scan + work_mem ==='
\qecho '    (เปิด iterative_scan อย่างเดียวไม่พอ — วัดแล้วใน q03_filter_after_scan.sql)'
SET hnsw.iterative_scan = relaxed_order;
SET work_mem = '4MB';

\qecho ''
\qecho '=== สถานะ 3: ทางแก้ครบ -> NOT_DETECTED ==='
\i /sql/score.sql
\set note 'iterative_scan + work_mem 4MB'
\i /sql/states_capture.sql

\set expect 'CANNOT_CHECK,DETECTED,NOT_DETECTED'
\i /sql/states_assert.sql

\qecho ''
\qecho '=== เก็บกวาด ==='
RESET hnsw.iterative_scan;
RESET work_mem;
DROP INDEX IF EXISTS qf_q03_idx;
DROP TABLE IF EXISTS qf_q03;
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
