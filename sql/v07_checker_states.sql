-- ============================================================
-- V07 — พิสูจน์ว่าตัวตรวจ static พลิกได้ครบ 3 สถานะ
--
-- รัน:  psql ... -v fault=v07 -f /sql/v07_checker_states.sql
--
-- ⚠️ ต้องเป็นไฟล์ .sql ไม่ใช่ -c ใน bash
--    วันนี้เหยียบกฎข้อ 2 ของ CLAUDE.md ไปสามครั้ง — quote พังทุกครั้ง
--    และพังแบบเงียบ คือคำสั่งไม่ทำงานแต่ script เดินต่อ
--
-- 🔴🔴 แก้สองเรื่องตอนทวน 2026-08-02
--
-- 1) **ไม่มี assertion เลย** — ไฟล์นี้มีไว้พิสูจน์การพลิก แต่เดิมแค่ยิง
--    score.sql สามรอบแล้วพิมพ์ผล · ถ้าทั้งสามรอบตอบเหมือนกันก็ยัง exit 0
--    แล้วผลถูก commit เป็นหลักฐาน · ตอนนี้ใช้ states_lib/capture/assert
--
-- 2) **ทำลาย qf_v07 แล้วไม่คืน** — CLAUDE.md ระบุไว้เองว่า
--    "qf_v07 · qf_v07r — ถ้าลบ verdict ของ V07 จะเปลี่ยน ไม่ตรงกับสภาพสะอาด"
--    ไฟล์นี้ DELETE แถวเสียแล้ว DROP TABLE ทิ้ง **โดยไม่มีอะไรสร้างคืน**
--    ผลคือรันครั้งเดียวแล้วสภาพฐานที่บันทึกไว้ (DETECTED 3 · NOT_DETECTED 3 ·
--    CANNOT_CHECK 9) เพี้ยนถาวรจนกว่าจะมีคนสังเกต — รูปแบบเดียวกับที่
--    qfcheck_states/_teardown เคยพลาดเรื่อง pg_stat_statements
--    ตอนนี้สร้างคืนด้วยตัวฉีดตัวจริงท้ายไฟล์ แล้วยืนยันว่า verdict กลับมา
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';

\i /sql/states_lib.sql

\qecho '--- สถานะ 1: มีแถวเสีย -> ต้องได้ DETECTED ---'
\i /sql/score.sql
\set note 'มีแถว NULL/zero อยู่ในตาราง'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 2: ลบแถวเสียออก -> ต้องพลิกเป็น NOT_DETECTED ---'
DELETE FROM qf_v07 WHERE kind <> 'good';
\i /sql/score.sql
\set note 'ลบแถวเสียออกหมดแล้ว'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 3: ไม่มีตารางเลย -> ต้องได้ CANNOT_CHECK ---'
DROP TABLE IF EXISTS qf_v07;
\i /sql/score.sql
\set note 'ไม่มีตารางให้ตรวจ'
\i /sql/states_capture.sql

\set expect 'DETECTED,NOT_DETECTED,CANNOT_CHECK'
\i /sql/states_assert.sql

\qecho
\qecho '--- corpus ที่ล็อกไว้ต้องไม่ถูกแตะ ---'
SELECT count(*) AS qf_corpus_rows FROM qf_corpus;
SELECT qf_fingerprint('qf_corpus') AS corpus_fingerprint;
SELECT value AS fingerprint_baseline FROM qf_manifest WHERE item = 'corpus_fingerprint_first5k';

-- ============================================================
-- คืนสภาพ — บังคับ ไม่ใช่ทางเลือก
--
-- qf_v07 ถูก DROP ไปในสถานะ 3 ซึ่งเป็นส่วนหนึ่งของการพิสูจน์
-- แต่สภาพฐานที่บันทึกไว้ต้องมีตารางนี้ ไม่งั้น V07 ค้างที่ CANNOT_CHECK
-- สร้างคืนด้วย **ตัวฉีดตัวจริง** ไม่ใช่เขียนสูตรซ้ำที่นี่ (บทเรียน E40)
-- ============================================================
\qecho
\qecho '=== คืนสภาพ: สร้าง qf_v07 กลับด้วยตัวฉีดตัวจริง ==='
\i /sql/v07_null_zero_vectors.sql

\qecho
\qecho '=== ยืนยันว่า verdict กลับมาเป็น DETECTED ตามสภาพสะอาดที่บันทึกไว้ ==='
\i /sql/score.sql

DO $$
DECLARE v text;
BEGIN
    SELECT verdict INTO v FROM score_result WHERE fault_id = 'V07';
    IF v IS DISTINCT FROM 'DETECTED' THEN
        RAISE EXCEPTION E'คืนสภาพไม่สำเร็จ — V07 ได้ ''%'' ควรเป็น DETECTED\n  สภาพฐานที่บันทึกไว้คือ DETECTED 3 · NOT_DETECTED 3 · CANNOT_CHECK 9', v;
    END IF;
    RAISE NOTICE 'คืนสภาพครบ — V07 = DETECTED';
END $$;

\qecho '✅ คืนสภาพครบ'
