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
DROP INDEX IF EXISTS qf_i01_state;

\qecho '--- สถานะ 1: ไม่มี vector index เลย -> ต้องได้ CANNOT_CHECK ---'
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 2: opclass ผิด -> ต้องได้ DETECTED ---'
CREATE INDEX qf_i01_state ON qf_corpus USING :index_type (embedding vector_l2_ops);
\i /sql/score.sql
DROP INDEX qf_i01_state;

\qecho
\qecho '--- สถานะ 3: opclass ถูก -> ต้องได้ NOT_DETECTED ---'
CREATE INDEX qf_i01_state ON qf_corpus USING :index_type (embedding vector_cosine_ops);
\i /sql/score.sql
DROP INDEX qf_i01_state;

RESET temp_file_limit;
