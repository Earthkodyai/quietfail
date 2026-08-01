-- เก็บกวาดของทดสอบ quietfail-check ให้หมด รวมค่าที่ตั้งไว้ระดับฐานข้อมูล
\set ON_ERROR_STOP on
DROP TABLE IF EXISTS qfcheck_demo CASCADE;
ALTER DATABASE faultlab RESET ivfflat.probes;
ALTER DATABASE faultlab RESET hnsw.ef_search;
ALTER DATABASE faultlab RESET maintenance_work_mem;
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat');
-- ⭐ เรียกนิยามกลาง ห้ามเขียนสูตรเอง (E40) — ไฟล์นี้เคยเขียนสูตรซ้ำ
SELECT count(*) AS corpus_rows FROM qf_corpus;
SELECT qf_fingerprint('qf_corpus') AS corpus_fingerprint;

-- 🔴 ต้องล้างประวัติ query ด้วย ไม่งั้นเก็บกวาดไม่ครบจริง
--
--    qfcheck_states.sql กับ qfcheck_fix.sql ยิง query ทดสอบไว้หลายรูปแบบ
--    ถ้าไม่ล้าง ตัวตรวจ I01 · Q02 ของ score.sql จะยังเห็นประวัตินั้นอยู่
--    แล้วให้ verdict ต่างจากสภาพสะอาดที่บันทึกไว้ (3 · 3 · 9)
--
--    เกิดขึ้นจริงสองครั้งระหว่างทวนเมื่อ 2026-08-02 — Q02 ขยับเป็น
--    NOT_DETECTED ทั้งที่ยังไม่ได้ฉีดอะไร แล้วต้องไล่หาสาเหตุทั้งสองรอบ
--    (CLAUDE.md เตือนไว้ว่า Q02 ขยับตามประวัติ แต่ teardown ไม่เคยล้างให้)
SELECT pg_stat_statements_reset() IS NOT NULL AS ล้างประวัติ_query_แล้ว;
