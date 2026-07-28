-- เก็บกวาดของทดสอบ quietfail-check ให้หมด รวมค่าที่ตั้งไว้ระดับฐานข้อมูล
\set ON_ERROR_STOP on
DROP TABLE IF EXISTS qfcheck_demo CASCADE;
ALTER DATABASE faultlab RESET ivfflat.probes;
ALTER DATABASE faultlab RESET hnsw.ef_search;
ALTER DATABASE faultlab RESET maintenance_work_mem;
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat');
SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text,'|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
