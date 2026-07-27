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

\qecho '=== I05 checker states — ค่าความจุที่ calibrate ไว้: 443 tuples/MB ที่ 384 มิติ ==='
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

\qecho ''
\qecho '--- สถานะ 2: maintenance_work_mem = 256MB -> NOT_DETECTED ---'
\qecho '    ความจุ 256 x 443 = 113,408 tuples > 100,000 แถว -> ทำนายว่าไม่ spill'
\qecho '    ตรงกับที่วัดจริง: 256MB คือค่าเดียวใน 3 ค่าที่ไม่มี NOTICE'
SET maintenance_work_mem = '256MB';
\i /sql/score.sql

\qecho ''
\qecho '--- สถานะ 3: 225MB — ตรงขอบที่ตัวตรวจพลิก ---'
\qecho '    ความจุ 225 x 443 = 99,675 < 100,000 -> ยังต้อง DETECTED'
SET maintenance_work_mem = '225MB';
\i /sql/score.sql

\qecho ''
\qecho '--- สถานะ 4: 226MB — อีก 1MB เดียว ---'
\qecho '    ความจุ 226 x 443 = 100,118 > 100,000 -> ต้องพลิกเป็น NOT_DETECTED'
SET maintenance_work_mem = '226MB';
\i /sql/score.sql

\qecho ''
\qecho '=== คืนค่าเดิมของโปรไฟล์ fragile ==='
RESET maintenance_work_mem;
SELECT current_setting('maintenance_work_mem') AS mwm_restored;

\qecho ''
\qecho '=== ข้อจำกัดที่ต้องพูดตรงๆ (กฎเหล็กข้อ 10) ==='
\qecho 'ตัวตรวจนี้มีทางไป CANNOT_CHECK อีก 2 ทาง ที่ไฟล์นี้ **ไม่ได้พิสูจน์**:'
\qecho '  ก) ไม่มีตาราง qf_corpus  — พิสูจน์ไม่ได้เพราะต้อง DROP corpus ที่ล็อกไว้'
\qecho '  ข) มิติไม่ใช่ 384        — พิสูจน์ไม่ได้เพราะต้อง ALTER คอลัมน์ของ corpus ที่ล็อกไว้'
\qecho 'ทั้งสองทางอ่านได้จากโค้ด score.sql บรรทัด 314 และ 325 แต่ยังไม่มีหลักฐานการรัน'
\qecho 'สูตรข้อ 6 ต้องการ "สถานะที่เจอและไม่เจอ" ซึ่งไฟล์นี้ให้ครบแล้ว'
