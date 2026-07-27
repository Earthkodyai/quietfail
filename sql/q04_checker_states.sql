-- ============================================================
-- Q04 — พิสูจน์ว่าตัวตรวจ static พลิกได้ครบ 3 สถานะ
--
-- รัน:  psql ... -v fault=q04 -f /sql/q04_checker_states.sql
--
-- อ่าน lists จาก reloptions ของ index จริง แล้วเทียบกับ ivfflat.probes
-- ⚠️ ต้องเป็นไฟล์ .sql ตามกฎข้อ 2 ของ CLAUDE.md
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP INDEX IF EXISTS qf_q04_state;

\qecho '--- สถานะ 1: ไม่มี ivfflat index -> ต้องได้ CANNOT_CHECK ---'
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 2: มี index lists=100 · probes=1 (ค่าเริ่มต้น) -> ต้องได้ DETECTED ---'
CREATE INDEX qf_q04_state ON qf_corpus USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
SET ivfflat.probes = 1;
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 3: ตั้ง probes = 10 ตามสูตร -> ต้องพลิกเป็น NOT_DETECTED ---'
SET ivfflat.probes = 10;
\i /sql/score.sql

DROP INDEX qf_q04_state;
RESET ivfflat.probes;
