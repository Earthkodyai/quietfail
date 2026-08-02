-- ============================================================
-- I05 — พิสูจน์ว่าตัวตรวจพลิกได้
--
-- รัน:  psql ... -f /sql/i05_checker_states.sql
--
-- ทำไมต้องมีไฟล์นี้ (เพิ่มย้อนหลัง 2026-07-27 จากการ audit ก่อนส่งงานต่อ):
--   ตอนทำ I05 ครั้งแรก วัด build 3 ค่าครบและ assertion ผ่าน 3/3
--   แต่ **ไม่เคยรัน score.sql เลยสักครั้ง** ตัวตรวจจึงไม่มีหลักฐานว่าตอบลบได้
--   ซึ่งขัดสูตรข้อ 6 ใน CLAUDE.md: "ตัวนับที่ไม่มีวันตอบลบ = ไม่ได้วัดอะไรเลย"
--
-- ข้อนี้ตรวจแบบ **ทำนายล่วงหน้า** — อ่าน maintenance_work_mem กับจำนวนแถว
-- แล้วบอกว่า build จะ spill ไหม โดย **ไม่ต้อง build จริง**
-- การพลิกสถานะจึงใช้เวลาไม่กี่วินาที ไม่ใช่ 72 วินาทีต่อรอบแบบตอนวัดจริง
--
-- ⚠️ ไม่มี CREATE INDEX ในไฟล์นี้ — ไม่แตะ /dev/shm จึงไม่ชน E28
-- ⚠️ ไม่แตะ qf_corpus เลย อ่านอย่างเดียว
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';

\i /sql/states_lib.sql

\qecho '=== I05 checker states — ค่าความจุที่ตัวตรวจใช้: 443 tuples/MB ที่ 384 มิติ ==='
\qecho ''
\qecho '🔴 อ่านก่อนตีความเลขในไฟล์นี้ (เติม 2026-08-02)'
\qecho '   443 tuples/MB เป็นค่าที่ score.sql **จงใจใช้ให้ต่ำกว่าความจุจริง**'
\qecho '   เพื่อเตือนเร็วกว่าจริงเล็กน้อย — ไม่ใช่ความจุที่วัดได้'
\qecho '   ความจุจริงมีสูตรจากซอร์สแล้ว (674 + MAXALIGN(8+4*dim)) และงบจริง'
\qecho '   คือ mwm - 4MiB บนเส้นทาง parallel · results/i05_capacity_model.txt'
\qecho '   ที่ 225MB สูตรให้ราว 104,000 tuples ซึ่ง **ไม่ spill** แต่ตัวตรวจตอบ'
\qecho '   DETECTED — นั่นคืออคติเชิงระวังที่ตั้งใจ ไม่ใช่ความคลาด'
\qecho '   scripts/quietfail_check.py เลิกใช้ค่านี้แล้วเพราะเป็นของส่งมอบ'
\qecho '   ที่เตือนผิดไม่ได้ · เจตนาต่างกัน ดูคอมเมนต์ใน sql/score.sql'
\qecho ''
\qecho '   เลข 225/226MB ข้างล่างจึงเป็น **ขอบของตัวตรวจ** ไม่ใช่ขอบทางกายภาพ'
\qecho ''

SELECT count(*)                        AS corpus_rows,
       max(vector_dims(embedding))     AS dim,
       current_setting('maintenance_work_mem') AS mwm_now
FROM qf_corpus;

\qecho ''
\qecho '--- สถานะ 1: maintenance_work_mem = 64MB (ค่าของโปรไฟล์ fragile) -> DETECTED ---'
\qecho '    ความจุ 64 x 443 = 28,352 tuples < 100,000 แถว -> ทำนายว่า spill'
SET maintenance_work_mem = '64MB';
\i /sql/score.sql
\set note 'mwm 64MB (โปรไฟล์ fragile)'
\i /sql/states_capture.sql

\qecho ''
\qecho '--- สถานะ 2: maintenance_work_mem = 256MB -> NOT_DETECTED ---'
\qecho '    ความจุ 256 x 443 = 113,408 tuples > 100,000 แถว -> ทำนายว่าไม่ spill'
\qecho '    ตรงกับที่วัดจริง: 256MB คือค่าเดียวใน 3 ค่าที่ไม่มี NOTICE'
SET maintenance_work_mem = '256MB';
\i /sql/score.sql
\set note 'mwm 256MB'
\i /sql/states_capture.sql

\qecho ''
\qecho '--- สถานะ 3: 225MB — ตรงขอบที่ตัวตรวจพลิก ---'
\qecho '    ความจุ 225 x 443 = 99,675 < 100,000 -> ยังต้อง DETECTED'
SET maintenance_work_mem = '225MB';
\i /sql/score.sql
\set note 'mwm 225MB — ใต้ขอบของตัวตรวจ'
\i /sql/states_capture.sql

\qecho ''
\qecho '--- สถานะ 4: 226MB — อีก 1MB เดียว ---'
\qecho '    ความจุ 226 x 443 = 100,118 > 100,000 -> ต้องพลิกเป็น NOT_DETECTED'
SET maintenance_work_mem = '226MB';
\i /sql/score.sql
\set note 'mwm 226MB — เหนือขอบของตัวตรวจ 1MB'
\i /sql/states_capture.sql

\set expect 'DETECTED,NOT_DETECTED,DETECTED,NOT_DETECTED'
\i /sql/states_assert.sql

\qecho ''
\qecho '=== คืนค่าเดิมของโปรไฟล์ fragile ==='
RESET maintenance_work_mem;

DO $$
DECLARE m text; v text;
BEGIN
    m := current_setting('maintenance_work_mem');
    IF pg_size_bytes(m) <> pg_size_bytes('64MB') THEN
        RAISE EXCEPTION 'ไม่ได้คืนค่าเดิม — maintenance_work_mem = % ควรเป็น 64MB', m;
    END IF;
    RAISE NOTICE 'คืนค่าเดิมครบ — maintenance_work_mem = %', m;
END $$;

\i /sql/score.sql

DO $$
DECLARE v text;
BEGIN
    SELECT verdict INTO v FROM score_result WHERE fault_id = 'I05';
    IF v IS DISTINCT FROM 'DETECTED' THEN
        RAISE EXCEPTION 'I05 ได้ ''%'' ที่ mwm 64MB ควรเป็น DETECTED ตามสภาพสะอาด', v;
    END IF;
END $$;

\qecho '✅ คืนสภาพครบ'

\qecho ''
\qecho '=== ข้อจำกัดที่ต้องพูดตรงๆ (กฎเหล็กข้อ 10) ==='
\qecho 'ตัวตรวจนี้มีทางไป CANNOT_CHECK อีก 2 ทาง ที่ไฟล์นี้ **ไม่ได้พิสูจน์**:'
\qecho '  ก) ไม่มีตาราง qf_corpus  — พิสูจน์ไม่ได้เพราะต้อง DROP corpus ที่ล็อกไว้'
\qecho '  ข) มิติไม่ใช่ 384        — พิสูจน์ไม่ได้เพราะต้อง ALTER คอลัมน์ของ corpus ที่ล็อกไว้'
\qecho 'ทั้งสองทางอ่านได้จากโค้ด score.sql บรรทัด 314 และ 325 แต่ยังไม่มีหลักฐานการรัน'
\qecho 'สูตรข้อ 6 ต้องการ "สถานะที่เจอและไม่เจอ" ซึ่งไฟล์นี้ให้ครบแล้ว'
