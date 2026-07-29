-- ============================================================
-- I02 ควบคุมย้อนหลัง — เงื่อนไข A ของ I02 จ่ายอะไรไปบ้าง
--
-- รัน:  psql ... -f /sql/i02_cost_control.sql
--
-- ⭐ ทำไมต้องมีการวัดนี้
--    I02 บน corpus ชุดหลักรายงานว่า build ที่ 50 แถว ได้ recall 1.0000
--    ส่วน build ครบ 100k ได้ 0.7682 — แล้วสรุปว่า "ความเป็นตัวแทนสำคัญกว่าจำนวนแถว"
--
--    **แต่ไม่เคยวัดต้นทุนของเงื่อนไข A เลย** วัดแค่ recall
--    การทดลอง I02b บน corpus ที่ยากขึ้นเพิ่งพบว่า index ที่ build บน 50 แถว
--    อ่าน buffers มากกว่า 1.72 เท่า · ช้ากว่า 2.4 เท่า · ใหญ่กว่า 2 เท่า
--    ถ้าเกิดแบบเดียวกันบน corpus ชุดหลัก **ข้อสรุปของ I02 ต้องแก้**
--
--    (probe เดิมวัด buffers ไว้ที่เงื่อนไข 1,000 แถว ได้ 357 เทียบ 350 = พอๆ กัน
--     แต่ **ไม่เคยวัดที่ 50 แถว** ซึ่งเป็นเงื่อนไขที่ให้ recall 1.0000)
--
-- ⚠️ ไม่แตะ qf_corpus — คัดลอกไปตารางแยก
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';
SET temp_file_limit = '2GB';

DROP INDEX IF EXISTS qf_i02c_idx;
DROP TABLE IF EXISTS qf_i02c;
DROP TABLE IF EXISTS qf_i02c_cost;

CREATE TABLE qf_i02c (id int PRIMARY KEY, cluster_id int, embedding vector(384));
CREATE TABLE qf_i02c_cost (cond text, rows_at_build int, buffers numeric,
                           ms numeric, idx_size text, recall numeric);

CREATE OR REPLACE FUNCTION qf_i02c_explain(p_qid int) RETURNS json AS $$
DECLARE j json;
BEGIN
    EXECUTE format(
      'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM qf_i02c '
      'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = %s) LIMIT 10',
      p_qid) INTO j;
    RETURN j;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_i02c_run(p_cond text, p_rows int) RETURNS void AS $$
DECLARE buf numeric; ms numeric; sz text; rc numeric;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02c_idx';
    TRUNCATE qf_i02c;
    PERFORM set_config('temp_file_limit', '2GB', true);

    INSERT INTO qf_i02c SELECT id, cluster_id, embedding
      FROM qf_corpus ORDER BY id LIMIT p_rows;

    EXECUTE 'CREATE INDEX qf_i02c_idx ON qf_i02c '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';

    -- ข้อมูลโตขึ้นทีหลัง โดยไม่สร้าง index ใหม่ (ความผิดพลาดที่ I02 จำลอง)
    INSERT INTO qf_i02c SELECT c.id, c.cluster_id, c.embedding FROM qf_corpus c
     WHERE NOT EXISTS (SELECT 1 FROM qf_i02c x WHERE x.id = c.id);
    ANALYZE qf_i02c;

    SELECT pg_size_pretty(pg_relation_size('qf_i02c_idx')) INTO sz;

    -- กฎเหล็กข้อ 8 — อุ่น cache
    PERFORM count(*) FROM (SELECT id FROM qf_i02c
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 10) w;

    -- กฎเหล็กข้อ 6ก — buffers ต้องรวม hit + read
    SELECT avg(b), avg(t) INTO buf, ms FROM (
        SELECT (x.j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint
             + (x.j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint AS b,
               (x.j -> 0 ->> 'Execution Time')::numeric AS t
        FROM (SELECT id FROM qf_queries ORDER BY id LIMIT 20) q,
        LATERAL (SELECT qf_i02c_explain(q.id) AS j) x) s;

    SELECT avg(r) INTO rc FROM (
        SELECT (SELECT count(*) FROM unnest(t.ids) AS tid
                 WHERE tid = ANY (SELECT c.id FROM qf_i02c c
                                  ORDER BY c.embedding <=> qq.embedding LIMIT 10)
               )::numeric / 10 AS r
        FROM qf_truth t JOIN qf_queries qq ON qq.id = t.query_id
        WHERE t.k = 10) z;

    INSERT INTO qf_i02c_cost VALUES (p_cond, p_rows, round(buf,0), round(ms,2), sz, round(rc,4));
END $$ LANGUAGE plpgsql;

SET ivfflat.probes = 1;

\qecho '=== วัดต้นทุนของทุกเงื่อนไข บน corpus ชุดหลัก ==='
SELECT qf_i02c_run('A_build_at_50',   50);
SELECT qf_i02c_run('B_build_at_1000', 1000);
SELECT qf_i02c_run('C_build_at_full', 100000);

SELECT cond AS เงื่อนไข, rows_at_build AS แถวตอน_build,
       recall, buffers AS buffers_เฉลี่ย, ms AS ms_เฉลี่ย, idx_size AS ขนาด_index
FROM qf_i02c_cost ORDER BY cond;

\qecho ''
\qecho '=== ข้อสรุป ==='
DO $$
DECLARE a record; c record; r_buf numeric; r_sz numeric;
BEGIN
    SELECT * INTO a FROM qf_i02c_cost WHERE cond='A_build_at_50';
    SELECT * INTO c FROM qf_i02c_cost WHERE cond='C_build_at_full';
    r_buf := round(a.buffers / nullif(c.buffers,0), 2);
    r_sz  := round(pg_size_bytes(a.idx_size)::numeric / nullif(pg_size_bytes(c.idx_size),0), 2);
    RAISE NOTICE 'A: recall=% buffers=% index=%', a.recall, a.buffers, a.idx_size;
    RAISE NOTICE 'C: recall=% buffers=% index=%', c.recall, c.buffers, c.idx_size;
    RAISE NOTICE 'A อ่านมากกว่า C % เท่า · index ใหญ่กว่า % เท่า', r_buf, r_sz;
    RAISE NOTICE '';
    IF a.recall > c.recall AND r_buf >= 1.3 THEN
        RAISE NOTICE '-> ⭐ recall ที่สูงกว่าของ A **แลกมาด้วยต้นทุน** ไม่ใช่ของฟรี';
        RAISE NOTICE '   ข้อสรุปเดิมของ I02 ที่เทียบแต่ recall จึงไม่ครบ ต้องแก้';
    ELSIF a.recall > c.recall AND r_buf <= 1.15 THEN
        RAISE NOTICE '-> A ได้ recall สูงกว่าโดยอ่านพอๆ กัน — ข้อสรุปเดิมยังยืน';
    ELSE
        RAISE NOTICE '-> ผลไม่เข้าทั้งสองรูปแบบ ต้องดูตารางเอง';
    END IF;
END $$;

\qecho ''
\qecho '=== เก็บกวาด ==='
DROP INDEX IF EXISTS qf_i02c_idx;
DROP TABLE IF EXISTS qf_i02c;
DROP FUNCTION IF EXISTS qf_i02c_run(text, int);
DROP FUNCTION IF EXISTS qf_i02c_explain(int);
RESET ivfflat.probes;
SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat');
SELECT count(*) AS corpus_rows,
       md5(string_agg(embedding::text,'|' ORDER BY id)) AS corpus_fingerprint
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
