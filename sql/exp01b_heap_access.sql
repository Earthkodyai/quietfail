-- ============================================================
-- EXP01b — index selectivity เมื่อบังคับให้ต้องแตะ heap
--
-- ที่มา: EXP01 ทำนายว่า merchant_id=1 (12% ของตาราง) จะยังใช้ Seq Scan
--        ผลจริงคือกลายเป็น Index Only Scan ทั้งคู่ -> ทำนายผิด
--
--        สาเหตุ: count(*) + เงื่อนไขบนคอลัมน์เดียว = index ตอบได้เอง
--        Heap Fetches: 0 จึงไม่มีค่าใช้จ่ายของการสุ่มอ่าน heap
--        ซึ่งเป็นตัวแปรที่ทำให้ index ไม่คุ้มเมื่อแถวเยอะ
--
-- การทดลองนี้ตัดตัวแปรนั้นออก โดยใช้ sum() บนคอลัมน์ที่ไม่ได้อยู่ใน index
-- -> บังคับให้ต้องอ่าน heap จริง
--
-- สมมติฐาน (ยังไม่พิสูจน์):
--   merchant_id = 4999 (18 แถว)    -> Index Scan
--   merchant_id = 1    (23,724 แถว) -> Seq Scan หรือ Bitmap Heap Scan
--
-- รัน:
--   docker compose exec db psql -U lab -d faultlab -f /sql/exp01b_heap_access.sql
-- ============================================================

-- ชื่อไฟล์ผลลัพธ์เปลี่ยนได้ เพื่อรันเทียบสองโปรไฟล์โดยไม่ทับหลักฐานเดิม
--   -v out=/results/exp01b_realistic.txt
\if :{?out}
\else
\set out /results/exp01b_heap_access.txt
\endif

\o :out

\qecho ============================================================
\qecho EXP01b - index selectivity with heap access required
\qecho ============================================================
\qecho

SELECT version();
SELECT extversion FROM pg_extension WHERE extname = 'vector';
SELECT now() AS run_at;
SELECT pg_size_pretty(pg_total_relation_size('orders')) AS orders_size,
       pg_size_pretty(
         (SELECT setting::bigint * 8192 FROM pg_settings WHERE name='shared_buffers')
       ) AS shared_buffers;

-- ปิด parallel ทั้งการทดลอง เพื่อให้เทียบ buffers ได้ตรงๆ
SET max_parallel_workers_per_gather = 0;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE A - ไม่มี index บน merchant_id
\qecho ============================================================

-- อุ่น cache ก่อน แล้วค่อยวัดรอบสอง
-- (EXP01 พบว่ารอบแรกหลังสร้าง index มี read= เพราะ page ยังไม่เข้า cache)
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;
SELECT sum(total_satang) FROM orders WHERE merchant_id = 4999;

\qecho
\qecho --- A1: merchant_id = 1 (23,724 แถว) ---
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- A2: merchant_id = 4999 (18 แถว) ---
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(total_satang) FROM orders WHERE merchant_id = 4999;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE B - มี index บน merchant_id
\qecho ============================================================

CREATE INDEX orders_merchant_id_idx ON orders (merchant_id);
ANALYZE orders;

SELECT pg_size_pretty(pg_relation_size('orders_merchant_id_idx')) AS index_size;

-- อุ่น cache รอบหนึ่งก่อนวัด
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;
SELECT sum(total_satang) FROM orders WHERE merchant_id = 4999;

\qecho
\qecho --- B1: merchant_id = 1 (23,724 แถว) ---
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- B2: merchant_id = 4999 (18 แถว) ---
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(total_satang) FROM orders WHERE merchant_id = 4999;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE C - บังคับใช้ index กับกรณีแถวเยอะ
\qecho ============================================================
\qecho (ถ้า B1 เลือก Seq Scan เอง ลองบังคับดูว่า planner ตัดสินใจถูกไหม
\qecho  ถ้าบังคับแล้วช้ากว่า = planner เลือกถูกแล้ว)

SET enable_seqscan = off;

\qecho
\qecho --- C1: merchant_id = 1 บังคับใช้ index ---
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(total_satang) FROM orders WHERE merchant_id = 1;

RESET enable_seqscan;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE D - ความแม่นของสถิติ แยกตามความถี่ของค่า
\qecho ============================================================
\qecho (EXP01 พบว่า planner เดาค่าที่พบบ่อยแม่นกว่าค่าที่พบน้อยมาก
\qecho  ตรวจว่าเป็นเพราะ most-common-values list หรือไม่)

SELECT
    array_length(most_common_vals::text::text[], 1) AS n_mcv_tracked,
    n_distinct
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'merchant_id';

-- ค่า 1 อยู่ในรายการค่าที่พบบ่อยหรือเปล่า
SELECT
    1 = ANY(most_common_vals::text::bigint[]) AS merchant_1_in_mcv,
    4999 = ANY(most_common_vals::text::bigint[]) AS merchant_4999_in_mcv
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'merchant_id';

-- ============================================================
\qecho
\qecho ============================================================
\qecho CLEANUP
\qecho ============================================================

DROP INDEX orders_merchant_id_idx;
SELECT indexname FROM pg_indexes WHERE tablename = 'orders' ORDER BY 1;

RESET max_parallel_workers_per_gather;

\qecho
\qecho ============================================================
\qecho สิ่งที่ต้องอ่าน:
\qecho   1. B1 ใช้ plan แบบไหน (Seq / Bitmap Heap / Index Scan)
\qecho   2. B1 มี Heap Fetches หรือ Rows Removed by Filter เท่าไหร่
\qecho   3. เทียบ buffers A1 vs B1 vs C1
\qecho   4. ถ้า C1 แพงกว่า B1 = planner ตัดสินใจถูก
\qecho   5. merchant_1_in_mcv เป็น true หรือไม่
\qecho ============================================================

\o
