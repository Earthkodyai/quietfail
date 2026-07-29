-- ============================================================
-- I02b ควบคุม — recall ที่สูงกว่า มาจากการ "อ่านมากกว่า" หรือเปล่า
--
-- รัน:  psql ... -f /sql/i02b_buffers_control.sql
--       (ต้องรัน i02b_harder_corpus.sql ก่อน)
--
-- ผลของ i02b: build ที่ 50 แถว (เห็นกลุ่มเดียว) ได้ recall 0.8727
--             build ครบ 100k (เห็น 50 กลุ่ม)  ได้ recall 0.8079
--
-- สมมติฐานที่ต้องตัดออกก่อนเชื่อ:
--   **H2** — build บนข้อมูลน้อยทำให้ centroid น้อย/ซ้ำ list จึงใหญ่ผิดปกติ
--            "สแกน 1 list" กลายเป็นสแกนเกือบทั้งตาราง
--            ถ้าใช่ recall สูงเพราะ **มันเลิกเป็น index ที่เร็ว** ไม่ใช่เพราะแม่นกว่า
--
-- วัดด้วย buffers ตามกฎเหล็กข้อ 7 (buffers นิ่งกว่าเวลา)
-- และกฎเหล็กข้อ 6ก — ต้องรวม Shared Hit + Shared Read
--
-- ⚠️ ไม่แตะ qf_corpus
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP TABLE IF EXISTS qf_i02b_buf;
CREATE TABLE qf_i02b_buf (cond text, buffers numeric, ms numeric,
                          idx_size text, recall numeric);

CREATE OR REPLACE FUNCTION qf_i02b_explain(p_qid int) RETURNS json AS $$
DECLARE j json;
BEGIN
    EXECUTE format(
      'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM qf_i02b '
      'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = %s) LIMIT 10',
      p_qid) INTO j;
    RETURN j;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_i02b_measure_buf(p_cond text, p_rows int)
RETURNS void AS $$
DECLARE
    j json; buf numeric; ms numeric; sz text; rc numeric;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02b_idx';
    CREATE TEMP TABLE _full AS SELECT * FROM qf_i02b;
    DELETE FROM qf_i02b WHERE id NOT IN (
        SELECT id FROM _full ORDER BY id LIMIT p_rows);

    PERFORM set_config('temp_file_limit', '2GB', true);
    EXECUTE 'CREATE INDEX qf_i02b_idx ON qf_i02b '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';

    INSERT INTO qf_i02b SELECT * FROM _full f
     WHERE NOT EXISTS (SELECT 1 FROM qf_i02b x WHERE x.id = f.id);
    DROP TABLE _full;
    ANALYZE qf_i02b;

    SELECT pg_size_pretty(pg_relation_size('qf_i02b_idx')) INTO sz;

    -- อุ่น cache (กฎเหล็กข้อ 8)
    PERFORM count(*) FROM (SELECT id FROM qf_i02b
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 10) w;

    -- buffers เฉลี่ยจาก 20 query แรก
    SELECT avg(b), avg(t) INTO buf, ms FROM (
        SELECT (x.j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint
             + (x.j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint AS b,
               (x.j -> 0 ->> 'Execution Time')::numeric AS t
        FROM (SELECT id FROM qf_queries ORDER BY id LIMIT 20) q,
        LATERAL (SELECT qf_i02b_explain(q.id) AS j) x) s;

    SELECT avg(r) INTO rc FROM (
        SELECT (SELECT count(*) FROM unnest(t.ids) AS tid
                 WHERE tid = ANY (SELECT c.id FROM qf_i02b c
                                  ORDER BY c.embedding <=> qq.embedding LIMIT 10)
               )::numeric / 10 AS r
        FROM qf_i02b_truth t JOIN qf_queries qq ON qq.id = t.query_id) z;

    INSERT INTO qf_i02b_buf VALUES (p_cond, round(buf,0), round(ms,2), sz, round(rc,4));
END $$ LANGUAGE plpgsql;

SET ivfflat.probes = 1;

\qecho '=== วัด buffers · เวลา · ขนาด index · recall ต่อเงื่อนไข ==='
SELECT qf_i02b_measure_buf('A_build_at_50',    50);
SELECT qf_i02b_measure_buf('C_build_at_full',  100000);

SELECT cond          AS เงื่อนไข,
       buffers       AS buffers_เฉลี่ย,
       ms            AS ms_เฉลี่ย,
       idx_size      AS ขนาด_index,
       recall        AS recall
FROM qf_i02b_buf ORDER BY cond;

\qecho ''
\qecho '=== ⭐ จำนวน list ที่ใช้จริง — ถ้า build บน 50 แถวได้ centroid น้อย list จะใหญ่ ==='
\qecho '    (อ่านจาก reloptions ได้แค่ค่าที่ขอ ไม่ใช่ค่าที่ได้จริง จึงดูที่ buffers เป็นหลัก)'
SELECT c.relname, array_to_string(c.reloptions, ',') AS reloptions,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
JOIN pg_class t ON t.oid = i.indrelid
WHERE t.relname = 'qf_i02b';

\qecho ''
\qecho '=== ข้อสรุป ==='
DO $$
DECLARE a_buf numeric; c_buf numeric; a_rc numeric; c_rc numeric; ratio numeric;
BEGIN
    SELECT buffers, recall INTO a_buf, a_rc FROM qf_i02b_buf WHERE cond='A_build_at_50';
    SELECT buffers, recall INTO c_buf, c_rc FROM qf_i02b_buf WHERE cond='C_build_at_full';
    ratio := round(a_buf / nullif(c_buf,0), 2);
    RAISE NOTICE 'A (build 50 แถว)  buffers=% recall=%', a_buf, a_rc;
    RAISE NOTICE 'C (build ครบ)     buffers=% recall=%', c_buf, c_rc;
    RAISE NOTICE 'A อ่านมากกว่า C % เท่า', ratio;
    RAISE NOTICE '';
    IF ratio >= 1.5 THEN
        RAISE NOTICE '-> **H2 ยืนยัน** recall ที่สูงกว่าแลกมาด้วยการอ่านมากกว่าอย่างมีนัย';
        RAISE NOTICE '   index ที่ build บนข้อมูลน้อย **เลิกเป็น index ที่เร็ว** ไม่ใช่แม่นกว่า';
    ELSIF ratio <= 1.15 THEN
        RAISE NOTICE '-> **H2 ตกไป** อ่านพอๆ กัน แต่ได้ recall ต่างกันจริง';
        RAISE NOTICE '   = ต้องหาคำอธิบายอื่น ยังสรุปกลไกไม่ได้';
    ELSE
        RAISE NOTICE '-> ก้ำกึ่ง (% เท่า) สรุปไม่ได้ด้วยข้อมูลชุดนี้', ratio;
    END IF;
END $$;

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_i02b_idx;
DROP FUNCTION IF EXISTS qf_i02b_measure_buf(text, int);
DROP FUNCTION IF EXISTS qf_i02b_explain(int);
RESET ivfflat.probes;
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat');
SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text,'|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
