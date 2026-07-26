-- ============================================================
-- EXP01 — index selectivity
--
-- คำถาม: index ตัวเดียวกัน บน query โครงสร้างเดียวกัน
--        ช่วยเท่ากันทุกกรณีหรือไม่
--
-- รัน:
--   docker compose exec db psql -U lab -d faultlab -f /sql/exp01_index_selectivity.sql
--
-- ผลจะถูกเขียนลง /results/exp01_index_selectivity.txt (= .\results\ บน Windows)
--
-- สคริปต์นี้ทำความสะอาดหลังตัวเอง: DROP INDEX ตอนจบ
-- schema ต้องกลับไปมีข้อบกพร่องตามเดิม ไม่งั้น fault ข้ออื่นจะเพี้ยน
-- ============================================================

\o /results/exp01_index_selectivity.txt

\qecho ============================================================
\qecho EXP01 - index selectivity
\qecho ============================================================
\qecho

-- ---------- บันทึกสภาพแวดล้อม (ต้องมีในทุกไฟล์ผล) ----------
\qecho --- environment ---
SELECT version();
SELECT extname || ' ' || extversion AS extension
FROM pg_extension ORDER BY 1;
SELECT now() AS run_at;
SELECT name, setting FROM pg_settings
WHERE name IN ('max_connections','work_mem','shared_buffers',
               'max_parallel_workers_per_gather','random_page_cost')
ORDER BY name;

\qecho
\qecho --- dataset ---
SELECT count(*) AS total_orders FROM orders;
SELECT pg_size_pretty(pg_total_relation_size('orders')) AS orders_size;

-- จำนวนแถวจริงของสองค่าที่จะทดสอบ = ตัวแปรต้นของการทดลอง
SELECT 1 AS merchant_id, count(*) AS actual_rows FROM orders WHERE merchant_id = 1
UNION ALL
SELECT 4999, count(*) FROM orders WHERE merchant_id = 4999;

\qecho
\qecho --- indexes ที่มีอยู่ก่อนเริ่ม ---
SELECT indexname FROM pg_indexes WHERE tablename = 'orders' ORDER BY 1;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE A - ก่อนมี index บน merchant_id
\qecho ============================================================

\qecho
\qecho --- A1: merchant_id = 1 (แถวเยอะ) ---
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- A2: merchant_id = 4999 (แถวน้อย) ---
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders WHERE merchant_id = 4999;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE B - หลังสร้าง index
\qecho ============================================================

CREATE INDEX orders_merchant_id_idx ON orders (merchant_id);
ANALYZE orders;

\qecho
\qecho --- ขนาด index ---
SELECT pg_size_pretty(pg_relation_size('orders_merchant_id_idx')) AS index_size;

\qecho
\qecho --- B1: merchant_id = 1 (แถวเยอะ) ---
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- B2: merchant_id = 4999 (แถวน้อย) ---
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders WHERE merchant_id = 4999;

-- ============================================================
\qecho
\qecho ============================================================
\qecho PHASE C - ปิด parallel worker เพื่อตัดตัวแปรกวน
\qecho ============================================================
\qecho (รอบก่อนพบว่า plan หนึ่งใช้ worker อีก plan ไม่ใช้
\qecho  ทำให้เทียบ buffers ตรงๆ ยาก รอบนี้ปิดให้เท่ากันทั้งคู่)

SET max_parallel_workers_per_gather = 0;

\qecho
\qecho --- C1: merchant_id = 1 ---
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders WHERE merchant_id = 1;

\qecho
\qecho --- C2: merchant_id = 4999 ---
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders WHERE merchant_id = 4999;

RESET max_parallel_workers_per_gather;

-- ============================================================
\qecho
\qecho ============================================================
\qecho CLEANUP - คืน schema ให้กลับไปมีข้อบกพร่องตามเดิม
\qecho ============================================================

DROP INDEX orders_merchant_id_idx;

\qecho
\qecho --- ยืนยันว่าลบแล้ว ---
SELECT indexname FROM pg_indexes WHERE tablename = 'orders' ORDER BY 1;

\qecho
\qecho ============================================================
\qecho จบการทดลอง
\qecho
\qecho สิ่งที่ต้องอ่านจากผลข้างบน:
\qecho   1. เทียบ Buffers ของ A2 กับ B2  -> index ช่วยกรณีแถวน้อยไหม
\qecho   2. เทียบ Buffers ของ A1 กับ B1  -> index ช่วยกรณีแถวเยอะไหม
\qecho   3. ดูว่า B1 ยังเป็น Seq Scan อยู่หรือเปล่า
\qecho   4. เทียบ rows= กับ actual rows= ทุก plan
\qecho ============================================================

\o
