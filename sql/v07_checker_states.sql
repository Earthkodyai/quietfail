-- ============================================================
-- V07 — พิสูจน์ว่าตัวตรวจ static พลิกได้ครบ 3 สถานะ
--
-- รัน:  psql ... -v fault=v07 -f /sql/v07_checker_states.sql
--
-- ⚠️ ต้องเป็นไฟล์ .sql ไม่ใช่ -c ใน bash
--    วันนี้เหยียบกฎข้อ 2 ของ CLAUDE.md ไปสามครั้ง — quote พังทุกครั้ง
--    และพังแบบเงียบ คือคำสั่งไม่ทำงานแต่ script เดินต่อ
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';

\qecho '--- สถานะ 1: มีแถวเสีย -> ต้องได้ DETECTED ---'
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 2: ลบแถวเสียออก -> ต้องพลิกเป็น NOT_DETECTED ---'
DELETE FROM qf_v07 WHERE kind <> 'good';
\i /sql/score.sql

\qecho
\qecho '--- สถานะ 3: ไม่มีตารางเลย -> ต้องได้ CANNOT_CHECK ---'
DROP TABLE IF EXISTS qf_v07;
\i /sql/score.sql

\qecho
\qecho '--- corpus ที่ล็อกไว้ต้องไม่ถูกแตะ ---'
SELECT count(*) AS qf_corpus_rows FROM qf_corpus;
SELECT value AS corpus_fingerprint FROM qf_manifest WHERE item = 'corpus_fingerprint_first5k';
