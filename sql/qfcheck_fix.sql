-- แก้ทุกข้อที่ qfcheck_states.sql จงใจทำให้เสีย
-- ตัวตรวจต้องพลิกจาก "พบปัญหา" เป็น "ไม่พบ" หลังรันไฟล์นี้
--
-- ⭐ ต้องใช้ ALTER DATABASE ไม่ใช่ SET เฉยๆ
--    SET ธรรมดามีผลแค่ session ที่รัน — connection ใหม่ได้ค่าเดิม
--    ตัวตรวจเปิด connection ของตัวเอง จึงมองไม่เห็น SET ของ session อื่น
--    **และนั่นถูกต้องแล้ว** เพราะ SET ระดับ session ก็ไม่ได้ปกป้อง production เช่นกัน
--    ทางแก้ที่นับว่าแก้จริงคือระดับฐานข้อมูลขึ้นไป
\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

-- I01: เปลี่ยน opclass ให้ตรงกับ operator ที่โค้ดใช้ (<=> = cosine)
DROP INDEX IF EXISTS qfcheck_l2;
CREATE INDEX qfcheck_cos ON qfcheck_demo USING hnsw (embedding vector_cosine_ops);

-- V07: เอาแถวที่ embedding ใช้งานไม่ได้ออก
DELETE FROM qfcheck_demo WHERE embedding IS NULL OR vector_norm(embedding) = 0;
ANALYZE qfcheck_demo;

-- Q04 · Q06 · I05: แก้ระดับฐานข้อมูล เพื่อให้ connection ใหม่ได้ค่านี้ด้วย
ALTER DATABASE faultlab SET ivfflat.probes = 10;
ALTER DATABASE faultlab SET hnsw.ef_search = 100;
ALTER DATABASE faultlab SET maintenance_work_mem = '256MB';

SELECT pg_stat_statements_reset();

-- Q02 · Q06: ยิงเฉพาะรูปแบบที่ถูกต้อง — ORDER BY + LIMIT เรียงจากน้อยไปมาก
SET hnsw.ef_search = 100;
\o /dev/null
SELECT id FROM qfcheck_demo
 ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) LIMIT 100;
\o

\qecho '=== แก้แล้ว (ค่าที่ connection ใหม่จะได้) ==='
-- 🔴 คำสั่งเดิมอ้างคอลัมน์ `setting` ซึ่ง pg_db_role_setting ไม่มี
--    (มีแค่ setdatabase · setrole · setconfig) จึง ERROR ทุกครั้งที่รัน
--    **ERROR นั้นปรากฏอยู่ใน results/qfcheck_states.txt ที่ commit ไว้ตั้งแต่ต้น
--    และไม่มีใครสังเกตเลย** — ตัวไฟล์หลักฐานเองมีข้อผิดพลาดโชว์อยู่
--    ไม่กระทบผลการพิสูจน์ เพราะเป็นบรรทัดรายงานท้ายไฟล์ ไม่ใช่ตัวแก้
--    (แก้ 2026-08-02)
SELECT (SELECT count(*) FROM qfcheck_demo) AS rows_now,
       coalesce((SELECT 'hnsw.ef_search=100' = ANY(s.setconfig)
                   FROM pg_db_role_setting s
                   JOIN pg_database d ON d.oid = s.setdatabase
                  WHERE d.datname = 'faultlab'), false) AS ef_ตั้งระดับ_db;
