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

\o /dev/null
SELECT pg_stat_statements_reset();
\o

\qecho '--- สถานะ 1: ยังไม่มี query ที่ใช้ vector operator -> CANNOT_CHECK ---'
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 2: รันเฉพาะรูปแบบที่ถูกต้อง -> NOT_DETECTED ---'
\o /dev/null
SELECT id FROM qf_corpus
ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) LIMIT 10;
\o
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 3: รันรูปแบบที่เขียนผิดเพิ่ม -> DETECTED ---'
\o /dev/null
SELECT id FROM qf_corpus
WHERE embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) < 0.5;
\o
\i /sql/score.sql
