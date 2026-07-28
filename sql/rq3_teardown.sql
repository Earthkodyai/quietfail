-- ============================================================
-- RQ3 — เก็บกวาดหลังใช้งาน
--
-- รัน:  psql ... -f /sql/rq3_teardown.sql
--
-- ต้องเก็บกวาดเพราะสภาพสะอาดที่ทั้งโปรเจคใช้อ้างอิงคือ **ไม่มี vector index ค้าง**
-- ถ้าปล่อย index ของ RQ3 ไว้ `scripts/audit.py` จะรายงานว่ามี index ค้างทุกครั้ง
-- แล้วคนอ่านจะแยกไม่ออกว่าเป็นของ RQ3 หรือเป็นรอบทดลองที่ตายกลางคัน (กับดักข้อ 4)
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS search_queries CASCADE;

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');

SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
