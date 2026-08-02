-- ============================================================
-- บังคับว่า "ตัวนับคะแนนพลิกได้จริง" — ตอบ 2 คำถามแยกกัน
--
--   1. ลำดับ verdict ตรงกับที่ตั้งใจไหม            (:expect)
--   2. มันตอบไม่เหมือนกันอย่างน้อยสองแบบไหม        (สูตรข้อ 6)
--
-- ข้อ 2 จำเป็นแม้ข้อ 1 ผ่าน เพราะถ้าใครเขียน :expect เป็นค่าเดียวซ้ำๆ
-- ข้อ 1 จะผ่านแบบว่างเปล่า — ตัวนับที่ไม่มีวันตอบต่างกัน = ไม่ได้วัดอะไรเลย
-- ============================================================
\qecho
\qecho '=== ตรวจว่าตัวนับคะแนนพลิกได้จริง (สูตรข้อ 6) ==='

SELECT step, verdict, note FROM qf_states_log ORDER BY step;

-- 🔴 psql **ไม่แทนค่า** :'var' ข้างใน dollar-quote ของ plpgsql
--    ต้องส่งผ่าน set_config ก่อน แล้วอ่านด้วย current_setting()
--    (เคยพลาดมาแล้วในไฟล์อื่นของโปรเจคนี้)
SELECT set_config('quietfail.expect', :'expect', false);

DO $$
DECLARE
    got   text;
    want  text := current_setting('quietfail.expect');
    kinds int;
BEGIN
    SELECT string_agg(verdict, ',' ORDER BY step) INTO got FROM qf_states_log;

    IF got IS DISTINCT FROM want THEN
        RAISE EXCEPTION E'ลำดับ verdict ไม่ตรงกับที่ตั้งใจ\n  ได้   : %\n  ต้องได้: %', got, want;
    END IF;

    SELECT count(DISTINCT verdict) INTO kinds FROM qf_states_log;
    IF kinds < 2 THEN
        RAISE EXCEPTION E'ตัวนับคะแนนตอบ ''%'' เหมือนกันทุกสถานะ = ไม่ได้วัดอะไรเลย\n  (สูตรข้อ 6 — ห้ามถือว่าไฟล์นี้เป็นหลักฐานการพลิก)',
            (SELECT DISTINCT verdict FROM qf_states_log);
    END IF;

    RAISE NOTICE 'ผ่าน — พลิกได้จริง % สถานะ (%)', kinds, got;
END $$;

\qecho '✅ ตัวนับคะแนนพลิกได้จริง'
