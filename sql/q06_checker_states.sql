-- ============================================================
-- Q06 — พิสูจน์ว่าตัวตรวจ static พลิกได้ตามค่า ef_search
--
-- รัน:  psql ... -v fault=q06 -f /sql/q06_checker_states.sql
--
-- ⚠️ ต้องเป็นไฟล์ .sql ไม่ใช่ -c ใน bash
--    ลำดับสำคัญ: LOAD 'vector' ก่อน แล้วค่อย SET hnsw.ef_search
--    ถ้า SET มาก่อน LOAD จะได้ unrecognized configuration parameter
--    และการยัด LOAD 'vector' ผ่าน bash -c ทำให้ quote พังมาแล้ว (กฎข้อ 2 · E26)
--
-- 🔴🔴 แก้ตอนทวน 2026-08-02 — ไฟล์นี้เดิม **ไม่ได้พิสูจน์การพลิกเลย**
--
--    เดิมรับ -v ef=<ค่า> แล้วยิง score.sql **รอบเดียว** จบ
--    การพลิกจึงขึ้นกับว่าผู้รันจะนึกรันซ้ำด้วยค่าที่สองหรือไม่
--    ไม่มีอะไรบังคับ · ไม่มีอะไรเทียบสองรอบเข้าด้วยกัน · ไม่มี assertion
--    รันครั้งเดียวแล้วเก็บผล จะได้ไฟล์ที่มี verdict เดียว แต่ถูกนับเป็น
--    "หลักฐานการพลิก" ตามสูตรข้อ 6 ทั้งที่ยังไม่ได้พิสูจน์อะไร
--
--    ตอนนี้ไล่ทั้งสองฝั่งของเส้นแบ่งในรอบเดียว แล้วบังคับด้วย assertion
--
-- เส้นแบ่งมาจากตัวตรวจเอง (score.sql):  ef_search < declared_max_limit -> DETECTED
-- groundtruth ประกาศ declared_max_limit = 100 จึงเลือก 40 (ค่าปริยาย) กับ 200
-- ============================================================

\set ON_ERROR_STOP on

LOAD 'vector';

\i /sql/states_lib.sql

\qecho '--- สถานะ 1: hnsw.ef_search = 40 (ค่าปริยาย) < LIMIT 100 -> ต้องได้ DETECTED ---'
SET hnsw.ef_search = 40;
\i /sql/score.sql
\set note 'ef_search = 40 (ค่าปริยาย) ต่ำกว่า LIMIT ที่ประกาศไว้'
\i /sql/states_capture.sql

\qecho
\qecho '--- สถานะ 2: hnsw.ef_search = 200 >= LIMIT 100 -> ต้องพลิกเป็น NOT_DETECTED ---'
SET hnsw.ef_search = 200;
\i /sql/score.sql
\set note 'ef_search = 200 ครอบคลุม LIMIT ที่ประกาศไว้'
\i /sql/states_capture.sql

\set expect 'DETECTED,NOT_DETECTED'
\i /sql/states_assert.sql

-- ============================================================
-- คืนสภาพ — ef_search ต้องกลับเป็นค่าปริยาย
--
-- SET ระดับ session หายไปเองเมื่อปิด connection อยู่แล้ว แต่ RESET ให้ชัด
-- เพราะไฟล์นี้ถูก \i จากไฟล์อื่นได้ และสภาพสะอาดที่บันทึกไว้ระบุว่า
-- Q06 = DETECTED ซึ่งเป็นจริงที่ค่าปริยาย 40 เท่านั้น
-- ============================================================
RESET hnsw.ef_search;

\qecho
\qecho '=== ยืนยันว่ากลับสู่ค่าปริยาย แล้ว Q06 = DETECTED ตามสภาพสะอาด ==='
\i /sql/score.sql

DO $$
DECLARE v text; ef text;
BEGIN
    SELECT verdict INTO v FROM score_result WHERE fault_id = 'Q06';
    ef := current_setting('hnsw.ef_search');
    IF ef <> '40' THEN
        RAISE EXCEPTION 'ไม่ได้กลับสู่ค่าปริยาย — hnsw.ef_search = %', ef;
    END IF;
    IF v IS DISTINCT FROM 'DETECTED' THEN
        RAISE EXCEPTION 'Q06 ได้ ''%'' ที่ค่าปริยาย ควรเป็น DETECTED', v;
    END IF;
    RAISE NOTICE 'คืนสภาพครบ — ef_search = 40 · Q06 = DETECTED';
END $$;

\qecho '✅ คืนสภาพครบ'
