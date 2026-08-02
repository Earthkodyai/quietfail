-- ============================================================
-- Q04 — พิสูจน์ว่าตัวตรวจ static พลิกได้ครบ 3 สถานะ
--
-- รัน:  psql ... -v fault=q04 -f /sql/q04_checker_states.sql
--
-- อ่าน lists จาก reloptions ของ index จริง แล้วเทียบกับ ivfflat.probes
-- ⚠️ ต้องเป็นไฟล์ .sql ตามกฎข้อ 2 ของ CLAUDE.md
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_q04_state;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

\i /sql/states_lib.sql

DROP INDEX IF EXISTS qf_q04_state;

\qecho '--- สถานะ 1: ไม่มี ivfflat index -> ต้องได้ CANNOT_CHECK ---'
\i /sql/score.sql
\set note 'ไม่มี ivfflat index'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 2: มี index lists=100 · probes=1 (ค่าเริ่มต้น) -> ต้องได้ DETECTED ---'
CREATE INDEX qf_q04_state ON qf_corpus USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
SET ivfflat.probes = 1;
\i /sql/score.sql
\set note 'lists=100 · probes=1 (ค่าเริ่มต้น)'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 3: ตั้ง probes = 10 ตามสูตร -> ต้องพลิกเป็น NOT_DETECTED ---'
SET ivfflat.probes = 10;
\i /sql/score.sql
\set note 'probes=10 ตามสูตร sqrt(lists)'
\i /sql/states_capture.sql

\set expect 'CANNOT_CHECK,DETECTED,NOT_DETECTED'
\i /sql/states_assert.sql

DROP INDEX qf_q04_state;
RESET ivfflat.probes;

-- ยืนยันว่าไม่ทิ้ง index ค้างบนตารางที่ล็อกไว้ (กับดักข้อ 4 · 14ธ)
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM pg_class c JOIN pg_am a ON a.oid = c.relam
    WHERE a.amname IN ('hnsw','ivfflat');
    IF n > 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว — ต้องไม่เหลือเลยหลังไฟล์นี้จบ', n;
    END IF;
    RAISE NOTICE 'ไม่มี vector index ค้าง';
END $$;

\qecho '✅ เก็บกวาดครบ'
