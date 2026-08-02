-- ============================================================
-- I01 — พิสูจน์ว่าตัวตรวจ static แยกได้ครบ 3 สถานะ
--
-- รัน:  psql ... -v index_type=ivfflat -f /sql/i01_checker_states.sql
--
-- แยกออกมาเป็นไฟล์ SQL เพราะเคยเขียนฝังใน bash แล้ว quoting พัง
-- CREATE INDEX ล้มเหลวเงียบ ตัวตรวจเลยขึ้น CANNOT_CHECK ทั้ง 12 ครั้ง
-- โดยไม่มีอะไรบอก เพราะ stderr ถูกกลบ (ดู E26)
--
-- ⚠️ ห้ามใส่ 2>/dev/null รอบคำสั่งสร้าง index เด็ดขาด
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_i01_state;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';

\if :{?index_type}
\else
\set index_type ivfflat
\endif

-- IVFFlat k-means ใช้ temp เกิน 64kB ของโปรไฟล์ fragile
SET temp_file_limit = '2GB';

-- เก็บกวาดของค้างจากรอบก่อนที่อาจตายกลางคัน
-- ถ้าไม่ทำ สถานะ 1 จะเริ่มจากสภาพที่มี index อยู่แล้ว แล้วรายงานผิด
\i /sql/states_lib.sql

DROP INDEX IF EXISTS qf_i01_state;

\qecho '--- สถานะ 1: ไม่มี vector index เลย -> ต้องได้ CANNOT_CHECK ---'
\i /sql/score.sql
\set note 'ไม่มี vector index เลย'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 2: opclass ผิด -> ต้องได้ DETECTED ---'
CREATE INDEX qf_i01_state ON qf_corpus USING :index_type (embedding vector_l2_ops);
\i /sql/score.sql
\set note 'opclass เป็น l2 แต่ query ใช้ cosine'
\i /sql/states_capture.sql
DROP INDEX qf_i01_state;

\qecho
\qecho '--- สถานะ 3: opclass ถูก -> ต้องได้ NOT_DETECTED ---'
CREATE INDEX qf_i01_state ON qf_corpus USING :index_type (embedding vector_cosine_ops);
\i /sql/score.sql
\set note 'opclass ตรงกับ operator ที่ใช้'
\i /sql/states_capture.sql
DROP INDEX qf_i01_state;

\set expect 'CANNOT_CHECK,DETECTED,NOT_DETECTED'
\i /sql/states_assert.sql

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

