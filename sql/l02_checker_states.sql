-- ============================================================
-- L02 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ (สูตรข้อ 6)
--
-- รัน:  psql ... -f /sql/l02_checker_states.sql
--
-- ตัวตรวจของ L02 ถาม k แถว **โดยไม่มี WHERE เลย** แล้วเทียบกับจำนวนแถวที่ยังอยู่
-- นี่คือจุดที่แยกจาก Q03 — Q03 ตัวกรองเห็นได้ในโค้ด ส่วน L02 มองไม่เห็น
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

\i /sql/states_lib.sql

DROP INDEX IF EXISTS qf_l02_idx;
DROP TABLE IF EXISTS qf_l02;

\qecho '=== สถานะ 1: ยังไม่มีตาราง -> CANNOT_CHECK ==='
\i /sql/score.sql
\set note 'ยังไม่มีตาราง'
\i /sql/states_capture.sql

\qecho ''
\qecho '=== สร้างตาราง + hnsw index แล้วลบ 90% โดยไม่ vacuum ==='
CREATE TABLE qf_l02 (id int PRIMARY KEY, embedding vector(384));
INSERT INTO qf_l02 SELECT id, embedding FROM qf_corpus;
ANALYZE qf_l02;
CREATE INDEX qf_l02_idx ON qf_l02 USING hnsw (embedding vector_cosine_ops);
ALTER TABLE qf_l02 SET (autovacuum_enabled = false);

DELETE FROM qf_l02 WHERE id % 10 <> 0;
SELECT count(*) AS แถวที่ยังอยู่ FROM qf_l02;

\qecho ''
\qecho '=== สถานะ 2: ลบแล้วยังไม่ vacuum -> DETECTED ==='
\qecho '    ตารางมี 10,000 แถวที่ยังอยู่ แต่ขอ 10 จะได้ไม่ครบ'
\i /sql/score.sql
\set note 'ลบ 90% แล้วยังไม่ VACUUM'
\i /sql/states_capture.sql

\qecho ''
\qecho '=== VACUUM — ทางแก้ที่วัดแล้วว่าได้ผล ==='
VACUUM qf_l02;

\qecho ''
\qecho '=== สถานะ 3: หลัง VACUUM -> NOT_DETECTED ==='
\i /sql/score.sql
\set note 'หลัง VACUUM'
\i /sql/states_capture.sql

\set expect 'CANNOT_CHECK,DETECTED,NOT_DETECTED'
\i /sql/states_assert.sql

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_l02_idx;
DROP TABLE IF EXISTS qf_l02;
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
