-- รันอัตโนมัติครั้งเดียวตอนสร้าง container ครั้งแรก

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- ground truth ของ query ที่ช้า
CREATE EXTENSION IF NOT EXISTS pg_trgm;             -- ใช้ทำ index ให้ LIKE '%คำไทย%' (F11)
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS vector;              -- pgvector สำหรับส่วน AI/clustering

-- role ของแอป: ต้องไม่ใช่ superuser
-- เพราะ superuser_reserved_connections ทำให้ superuser ยังต่อได้เสมอ
-- ถ้าใช้ superuser ยิงโหลด fault F01 จะไม่มีวันเกิด
CREATE ROLE app LOGIN PASSWORD 'apppass';

-- role สำหรับสังเกตการณ์อย่างเดียว (จะได้ไม่เผลอแก้อะไร)
CREATE ROLE observer LOGIN PASSWORD 'obspass';
GRANT pg_monitor TO observer;
