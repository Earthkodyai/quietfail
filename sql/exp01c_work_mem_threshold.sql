-- ============================================================
-- EXP01c — lossy bitmap เกิดที่ work_mem เท่าไหร่
--
-- ที่มา: E08 พบว่าบนโปรไฟล์ fragile (work_mem=64kB) การเพิ่ม index
--        ทำให้ query ช้าลง 27% เพราะ bitmap ถูกลดชั้นเป็น lossy
--        คำถามที่ค้างไว้: บนโปรไฟล์ realistic (work_mem=4MB) อาการหายไหม
--
--        ถ้าหาย = E08 เป็น "ปัญหาที่ config กลบไว้"
--        ซึ่งอันตรายกว่าปัญหาถาวร เพราะจะโผล่ตอนโหลดหนักที่ work_mem ไม่พอ
--
-- การทดลองนี้แยกตัวแปรให้เหลือ work_mem ตัวเดียว:
--   container เดียว · shared_buffers เดียว · ข้อมูลชุดเดียว · ปิด parallel
--
-- รัน:
--   docker compose exec db psql -U lab -d faultlab -f /sql/exp01c_work_mem_threshold.sql
-- ============================================================

\set ON_ERROR_STOP on

\if :{?out}
\else
\set out /results/exp01c_work_mem_threshold.txt
\endif

\o :out

\qecho ============================================================
\qecho EXP01c - work_mem threshold for lossy bitmap
\qecho ============================================================
\qecho

SELECT version();
SELECT now() AS run_at;
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers','work_mem','max_parallel_workers_per_gather')
ORDER BY name;
SELECT count(*) AS orders_rows FROM orders;

SET max_parallel_workers_per_gather = 0;

CREATE INDEX orders_merchant_id_idx ON orders (merchant_id);
ANALYZE orders;

-- กฎเหล็กข้อ 8: อุ่น cache ก่อนวัดเสมอ
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho ------------------------------------------------------------
\qecho ตัวชี้วัดที่ต้องอ่านคือบรรทัด "Heap Blocks"
\qecho   lossy = N   -> จำแค่ว่าหน้านี้มีของ ต้องอ่านทั้งหน้าแล้วคัดใหม่
\qecho   ไม่มี lossy -> bitmap เก็บระดับแถวได้ครบ
\qecho ------------------------------------------------------------

\qecho
\qecho --- work_mem = 64kB (โปรไฟล์ fragile) ---
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- work_mem = 96kB ---
SET work_mem = '96kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- work_mem = 128kB ---
SET work_mem = '128kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- work_mem = 160kB ---
SET work_mem = '160kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- work_mem = 256kB ---
SET work_mem = '256kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- work_mem = 4MB (โปรไฟล์ realistic) ---
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho ============================================================
\qecho CLEANUP
\qecho ============================================================
DROP INDEX orders_merchant_id_idx;
RESET work_mem;
RESET max_parallel_workers_per_gather;

\qecho
\qecho ============================================================
\qecho สิ่งที่ต้องอ่าน:
\qecho   1. lossy หายไปที่ work_mem เท่าไหร่
\qecho   2. buffers เปลี่ยนไหมระหว่างค่าที่ lossy กับไม่ lossy
\qecho      -- ถ้าไม่เปลี่ยน แปลว่าตัวชี้วัดหลักของโปรเจค (กฎข้อ 7)
\qecho         มองไม่เห็น fault ชนิดนี้เลย
\qecho   3. เวลาแกว่งแค่ไหนระหว่างรอบที่โครงสร้าง plan เหมือนกัน
\qecho ============================================================

\o
