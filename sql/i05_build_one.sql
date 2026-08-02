-- ============================================================
-- I05 — build HNSW หนึ่งรอบที่ค่า maintenance_work_mem ที่กำหนด
--
-- รัน:  psql ... -v mwm=64MB -f /sql/i05_build_one.sql
--
-- ไฟล์นี้ทำงานเดียว: build หนึ่งครั้ง แล้วบันทึกผลลง qf_i05_results
-- ตัวที่วนค่า mwm อยู่ใน faults/i05_maintenance_work_mem.sh
--
-- ⚠️ ทำไมต้องแยกเป็นไฟล์ .sql
--    NOTICE ของ pgvector ออกทาง stderr ต้องให้ shell เป็นคนจับ
--    แต่ SQL ต้องอยู่ในไฟล์ ไม่ฝังใน bash -c (บทเรียนจาก E19 และ E26)
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';

\if :{?mwm}
\else
\echo 'ต้องระบุ -v mwm=<ค่า> เช่น 64MB'
\quit 1
\endif

SET max_parallel_workers_per_gather = 0;
SET maintenance_work_mem = :'mwm';
SET temp_file_limit = '2GB';

CREATE TABLE IF NOT EXISTS qf_i05_results (
    mwm          text,
    mwm_kb       bigint,
    corpus_rows  bigint,
    build_ms     numeric,
    index_size   text,
    recorded_at  timestamptz DEFAULT now()
);

\o /dev/null
SELECT set_config('qf.t0', clock_timestamp()::text, false);
\o

-- เก็บกวาดของค้างจากรอบที่อาจตายกลางคัน
-- ถ้าไม่ทำ รอบถัดไปจะตายด้วย "relation already exists" ซึ่งชี้ไปคนละเรื่องกับต้นเหตุ
-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** — ตารางที่ล็อกไว้แน่นที่สุด
--    (fingerprint ของมันผูกกับผลทุกตัวในเล่ม) · index ไม่เปลี่ยนข้อมูลจึงไม่เสีย
--    **แต่ถ้าถูกตัดกลางคันจะทิ้ง index ค้าง** ทำให้ score.sql · audit.py
--    และ quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_i05_idx;
--    ตัวเรียก faults/i05_maintenance_work_mem.sh มี trap เก็บกวาดให้แล้ว
DROP INDEX IF EXISTS qf_i05_idx;

CREATE INDEX qf_i05_idx ON qf_corpus USING hnsw (embedding vector_cosine_ops);

INSERT INTO qf_i05_results (mwm, mwm_kb, corpus_rows, build_ms, index_size)
SELECT :'mwm',
       -- ⚠️ current_setting() คืนค่าตามหน่วยที่เราสั่ง SET ('64MB' '1GB')
       -- ไม่ได้ normalize เป็น kB แบบที่ pg_settings.setting ให้
       -- ใช้ pg_size_bytes() แปลงจึงจะเทียบข้ามหน่วยได้
       (pg_size_bytes(current_setting('maintenance_work_mem')) / 1024)::bigint,
       (SELECT count(*) FROM qf_corpus),
       round(extract(epoch FROM clock_timestamp() - current_setting('qf.t0')::timestamptz) * 1000, 1),
       pg_size_pretty(pg_relation_size('qf_i05_idx'));

DROP INDEX qf_i05_idx;
RESET temp_file_limit;
