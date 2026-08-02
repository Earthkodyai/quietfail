-- ============================================================
-- Q02 — พิสูจน์ว่าตัวตรวจพลิกได้ครบ 3 สถานะ
--
-- รัน:  psql ... -v fault=q02 -f /sql/q02_checker_states.sql
--
-- หลักฐานของข้อนี้เป็น **query ที่ระบบเคยรัน** (pg_stat_statements)
-- ซึ่งเป็นชนิดที่สามที่โปรเจคนี้ใช้ ต่อจาก "สถานะสด" กับ "catalog"
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';

\i /sql/states_lib.sql

\o /dev/null
SELECT pg_stat_statements_reset();
\o

\qecho '--- สถานะ 1: ยังไม่มี query ที่ใช้ vector operator -> CANNOT_CHECK ---'
\i /sql/score.sql
\set note 'ยังไม่มี query ที่ใช้ vector operator'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 2: รันเฉพาะรูปแบบที่ถูกต้อง -> NOT_DETECTED ---'
\o /dev/null
SELECT id FROM qf_corpus
ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) LIMIT 10;
\o
\i /sql/score.sql
\set note 'รันเฉพาะรูปแบบที่ถูกต้อง'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 3: รันรูปแบบที่เขียนผิดเพิ่ม -> DETECTED ---'
\o /dev/null
SELECT id FROM qf_corpus
WHERE embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) < 0.5;
\o
\i /sql/score.sql
\set note 'รันรูปแบบที่เขียนผิดเพิ่ม'
\i /sql/states_capture.sql

\set expect 'CANNOT_CHECK,NOT_DETECTED,DETECTED'
\i /sql/states_assert.sql

-- ============================================================
-- คืนสภาพ — บังคับ
--
-- 🔴 เดิมไฟล์นี้ reset pg_stat_statements **ตอนต้นอย่างเดียว** แล้วจบเลย
--    ทิ้ง query ทดสอบทั้งสามรูปแบบค้างไว้ · CLAUDE.md เตือนเรื่องนี้ไว้เอง
--    ว่า Q02 อ่าน pg_stat_statements จึงเปลี่ยน verdict ตามประวัติการรัน
--    ผลคือหลังรันไฟล์นี้ Q02 จะค้างที่ DETECTED ไม่ตรงกับสภาพสะอาดที่บันทึกไว้
--    รูปแบบเดียวกับที่ qfcheck_states/_teardown เคยพลาด (แก้ 2026-08-02)
-- ============================================================
\qecho
\qecho '=== คืนสภาพ: ล้าง pg_stat_statements ที่ไฟล์นี้ทำให้สกปรก ==='
\o /dev/null
SELECT pg_stat_statements_reset();
\o
\i /sql/score.sql

DO $$
DECLARE v text;
BEGIN
    SELECT verdict INTO v FROM score_result WHERE fault_id = 'Q02';
    IF v IS DISTINCT FROM 'CANNOT_CHECK' THEN
        RAISE EXCEPTION 'คืนสภาพไม่สำเร็จ — Q02 ได้ ''%'' ควรกลับเป็น CANNOT_CHECK หลังล้างสถิติ', v;
    END IF;
    RAISE NOTICE 'คืนสภาพครบ — Q02 = CANNOT_CHECK (สถิติว่างเปล่า)';
END $$;

\qecho '✅ คืนสภาพครบ'
