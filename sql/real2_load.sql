-- ============================================================
-- โหลด corpus จาก embedding จริง **โมเดลที่สอง** (all-mpnet-base-v2 · 768 มิติ)
-- ทดสอบว่าเส้นแบ่งกลไก/ปริมาณยังอยู่ไหมเมื่อเปลี่ยนทั้งโมเดลและมิติ (เล่ม 6.5 ข้อ 2)
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real_load.sql
--
-- ต้องรัน scripts/real_embed_build.py ก่อน เพื่อสร้าง
--   sql/_real2_corpus.tsv · sql/_real2_queries.tsv
--
-- ⚠️ ไม่แตะ qf_corpus — มีการตรวจจำนวนแถวและ fingerprint ก่อน/หลัง
--    ตามกฎที่ CLAUDE.md ตั้งไว้ว่าห้ามเปลี่ยน corpus หลักเด็ดขาด
-- ============================================================
\timing on
\set ON_ERROR_STOP on

-- ------------------------------------------------------------
-- 0. จดสภาพของ qf_corpus ไว้ก่อน เพื่อพิสูจน์ตอนจบว่าไม่ได้แตะ
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_real2_guard;
-- ⚠️ ตัวคั่นต้องเป็น '|' ให้ตรงกับ scripts/audit.py ซึ่งเป็นนิยามอ้างอิง
--    เคยใช้ ',' แล้วได้คนละค่า → guard ยิงทั้งที่ corpus ไม่ได้เปลี่ยน (ดู E40)
CREATE TEMP TABLE qf_real2_guard AS
SELECT count(*) AS rows,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS fp
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;

DO $$
DECLARE g record;
BEGIN
    SELECT * INTO g FROM qf_real2_guard;
    IF g.rows <> 5000 THEN
        RAISE EXCEPTION 'จุดเริ่มต้นผิด: qf_corpus 5,000 แถวแรกอ่านได้ % แถว', g.rows;
    END IF;
    IF g.fp <> '5a32cba54ea2be4ed022fe8bfedae9b0' THEN
        RAISE EXCEPTION
            'จุดเริ่มต้นผิด: fingerprint ของ qf_corpus = % ไม่ตรงกับที่ล็อกไว้', g.fp;
    END IF;
    RAISE NOTICE 'qf_corpus สภาพถูกต้อง — เริ่มโหลดชุด embedding จริงได้';
END $$;

-- ------------------------------------------------------------
-- 1. ตาราง — โครงเหมือน qf_corpus/qf_queries/qf_truth เป๊ะ
--    ต่างแค่เก็บ text ไว้ด้วย และ **ไม่มี cluster_id**
--    เพราะ embedding จริงไม่มีกลุ่มที่เราออกแบบไว้ — ซึ่งคือประเด็นของการทดลองนี้
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_real2_truth;
DROP TABLE IF EXISTS qf_real2_q;
DROP TABLE IF EXISTS qf_real2;

CREATE TABLE qf_real2 (
    id        bigint PRIMARY KEY,
    body      text   NOT NULL,
    embedding vector(768)
);

CREATE TABLE qf_real2_q (
    id        int PRIMARY KEY,
    body      text NOT NULL,
    embedding vector(768)
);

CREATE TABLE qf_real2_truth (
    query_id int,
    k        int,
    ids      bigint[],
    PRIMARY KEY (query_id, k)
);

-- ⚠️ ใช้ FORMAT csv ไม่ใช่ text — เพราะ text format ตีความ backslash เป็น escape
--    ข้อความจริงจากอินเทอร์เน็ตมี backslash ได้ แล้วจะพังหรือเพี้ยนเงียบๆ
--    ตั้ง QUOTE เป็นอักขระที่ไม่มีทางปรากฏ เพื่อปิดกลไก quote ทั้งหมด
\copy qf_real2   (id, body, embedding) FROM '/sql/_real2_corpus.tsv'  WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\x01')
\copy qf_real2_q (id, body, embedding) FROM '/sql/_real2_queries.tsv' WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\x01')

ANALYZE qf_real2;
ANALYZE qf_real2_q;

-- ------------------------------------------------------------
-- 2. assertion — ต้องได้ขนาดเท่า qf_corpus เป๊ะ ไม่งั้นเทียบกันไม่ได้
-- ------------------------------------------------------------
DO $$
DECLARE
    n_c bigint; n_q bigint; d_c int; d_q int; n_null bigint;
BEGIN
    SELECT count(*) INTO n_c FROM qf_real2;
    SELECT count(*) INTO n_q FROM qf_real2_q;
    IF n_c <> 100000 THEN
        RAISE EXCEPTION 'corpus จริงมี % แถว (ต้อง 100,000 เท่ากับ qf_corpus)', n_c;
    END IF;
    IF n_q <> 200 THEN
        RAISE EXCEPTION 'query จริงมี % แถว (ต้อง 200 เท่ากับ qf_queries)', n_q;
    END IF;

    SELECT vector_dims(embedding) INTO d_c FROM qf_real2 LIMIT 1;
    SELECT vector_dims(embedding) INTO d_q FROM qf_real2_q LIMIT 1;
    IF d_c <> 768 OR d_q <> 768 THEN
        RAISE EXCEPTION 'มิติไม่ตรง: corpus % · query % (ต้อง 768)', d_c, d_q;
    END IF;

    -- V07 สอนไว้แล้วว่า NULL/zero vector ทำให้แถวหายเงียบๆ ต้องกันตั้งแต่ต้น
    SELECT count(*) INTO n_null FROM qf_real2
     WHERE embedding IS NULL OR vector_norm(embedding) = 0;
    IF n_null <> 0 THEN
        RAISE EXCEPTION 'พบ NULL หรือ zero vector % แถว — ชุดข้อมูลใช้ไม่ได้ (ดู V07)', n_null;
    END IF;

    RAISE NOTICE 'โหลดแล้ว corpus % แถว · query % แถว · 768 มิติ · ไม่มี NULL/zero',
        n_c, n_q;
END $$;

-- ------------------------------------------------------------
-- 3. ⭐ ตรวจว่าข้อมูล "ยากพอจะมีความหมาย" ก่อนวัด recall
--
--    E12 เคยพลาดมาแล้ว: corpus ที่กลุ่มไม่มีอยู่จริง ทำให้ recall ไม่มีความหมาย
--    ชุดนี้ไม่มีกลุ่มที่ออกแบบไว้ จึงเทียบคนละแบบ — ดูการกระจายของระยะแทน
--    ถ้าเพื่อนบ้านที่ 1 กับที่ 100 ห่างกันน้อยมาก แปลว่าเวกเตอร์เกาะกันเป็นก้อนเดียว
--    แล้ว ANN จะสลับอันดับได้ง่ายจนตัวเลข recall สะท้อนแค่ noise
-- ------------------------------------------------------------
DROP TABLE IF EXISTS qf_real2_sanity;
CREATE TABLE qf_real2_sanity AS
WITH q AS (SELECT id, embedding FROM qf_real2_q ORDER BY id LIMIT 20),
nn AS (
    -- เหตุผลเดียวกับ H32 — ต้องให้ window เรียงเอง ไม่งั้น rn ไม่ตรงกับอันดับจริง
    SELECT q.id AS qid, rn, dist FROM q,
    LATERAL (
        SELECT row_number() OVER (ORDER BY d.dist) AS rn, d.dist
        FROM (SELECT c.embedding <=> q.embedding AS dist
              FROM qf_real2 c ORDER BY c.embedding <=> q.embedding LIMIT 100) d
    ) t
)
SELECT
    avg(dist) FILTER (WHERE rn = 1)   AS d_nn1,
    avg(dist) FILTER (WHERE rn = 10)  AS d_nn10,
    avg(dist) FILTER (WHERE rn = 100) AS d_nn100
FROM nn;

DO $$
DECLARE s record;
BEGIN
    SELECT * INTO s FROM qf_real2_sanity;
    -- ⚠️ <=> คืน double precision แต่ round(x,n) รับเฉพาะ numeric ต้อง cast ก่อน
    RAISE NOTICE 'ระยะเฉลี่ยถึงเพื่อนบ้านที่ 1 = % · ที่ 10 = % · ที่ 100 = %',
        round(s.d_nn1::numeric, 4), round(s.d_nn10::numeric, 4),
        round(s.d_nn100::numeric, 4);
    IF s.d_nn100 <= s.d_nn1 THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: ระยะไม่เพิ่มตามอันดับ (nn1 % · nn100 %) — การวัดพัง',
            s.d_nn1, s.d_nn100;
    END IF;
END $$;

-- ------------------------------------------------------------
-- 4. เฉลย — exact search ล้วน
--    วิธีเดียวกับ qf13 เป๊ะ รวมทั้งการพิสูจน์ว่าปิด index สำเร็จจริง
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_real2_build_truth(p_k int)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    n_done bigint := 0;
    q      record;
    plan   json;
    plan_s text;
BEGIN
    PERFORM set_config('enable_indexscan',     'off', true);
    PERFORM set_config('enable_indexonlyscan', 'off', true);
    PERFORM set_config('enable_bitmapscan',    'off', true);

    -- กฎเหล็กข้อ 10: ถ้าเผลอเอาผลจาก approximate search มาเป็นเฉลย
    -- recall จะออกมาสวยเสมอโดยไม่มีอะไรเตือน
    EXECUTE format(
        'EXPLAIN (FORMAT JSON) SELECT id FROM qf_real2 '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_real2_q WHERE id = 0) '
        'LIMIT %s', p_k
    ) INTO plan;
    plan_s := plan::text;
    IF plan_s ILIKE '%Index Scan%' OR plan_s ILIKE '%Index Only Scan%' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: ยังมี index scan ในแผน เฉลยใช้ไม่ได้ — %', plan_s;
    END IF;

    DELETE FROM qf_real2_truth WHERE k = p_k;

    FOR q IN SELECT id, embedding FROM qf_real2_q ORDER BY id LOOP
        INSERT INTO qf_real2_truth (query_id, k, ids)
        -- ⚠️ ห้ามใช้ row_number() OVER () — window function ทำงาน **ก่อน** ORDER BY/LIMIT
        --    เลขที่ได้จึงเป็นลำดับที่สแกนเจอ (≈ ลำดับ id) ไม่ใช่ลำดับความใกล้
        --    เซ็ตยังถูก (LIMIT ตัดหลัง ORDER BY) แต่ **ลำดับในอาเรย์ไม่มีความหมาย**
        --    เรียงด้วยระยะตรงๆ ไปเลย ไม่ต้องพึ่ง window function (ดู H32)
        SELECT q.id, p_k, array_agg(t.id ORDER BY t.dist)
        FROM (
            SELECT c.id, c.embedding <=> q.embedding AS dist
            FROM qf_real2 c
            ORDER BY c.embedding <=> q.embedding
            LIMIT p_k
        ) t;
        n_done := n_done + 1;
    END LOOP;
    RETURN n_done;
END $$;

CREATE OR REPLACE FUNCTION qf_real2_recall_at(p_k int)
RETURNS TABLE (
    k int, n_queries int, mean_recall numeric, min_recall numeric, n_perfect int
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM qf_real2_truth WHERE qf_real2_truth.k = p_k) THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: ยังไม่มีเฉลยสำหรับ k=%', p_k;
    END IF;

    RETURN QUERY
    WITH per_query AS (
        SELECT t.query_id,
            (SELECT count(*) FROM unnest(t.ids) AS truth_id
              WHERE truth_id = ANY (
                  SELECT c.id FROM qf_real2 c
                  ORDER BY c.embedding <=> q.embedding LIMIT p_k))::numeric / p_k
            AS recall
        FROM qf_real2_truth t
        JOIN qf_real2_q q ON q.id = t.query_id
        WHERE t.k = p_k
    )
    SELECT p_k,
           count(*)::int,
           round(avg(recall), 4),
           round(min(recall), 4),
           count(*) FILTER (WHERE recall >= 1.0)::int
    FROM per_query;
END $$;

SELECT qf_real2_build_truth(10)  AS "สร้างเฉลย k=10";
SELECT qf_real2_build_truth(100) AS "สร้างเฉลย k=100";

-- ------------------------------------------------------------
-- 5. เฉลยต้องให้ recall = 1.0 กับตัวเอง ไม่งั้นสูตรวัดพัง
-- ------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM qf_real2_recall_at(10);
    IF r.mean_recall IS DISTINCT FROM 1.0000 THEN
        RAISE EXCEPTION
            'สูตรวัดพัง: exact search ได้ recall@10 = % (ต้องเป็น 1.0 ตามนิยาม)',
            r.mean_recall;
    END IF;
    RAISE NOTICE 'เฉลยใช้ได้ — exact search ได้ recall@10 = 1.0000 ตามนิยาม';
END $$;

-- ------------------------------------------------------------
-- 6. พิสูจน์ว่า qf_corpus ไม่ถูกแตะเลย
-- ------------------------------------------------------------
DO $$
DECLARE g record; now_fp text; now_rows bigint;
BEGIN
    SELECT * INTO g FROM qf_real2_guard;
    SELECT count(*), md5(string_agg(embedding::text, '|' ORDER BY id))
      INTO now_rows, now_fp
      FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
    IF now_rows <> g.rows OR now_fp <> g.fp THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยนไป! ก่อน % / % · หลัง % / %',
            g.rows, g.fp, now_rows, now_fp;
    END IF;
    RAISE NOTICE 'ยืนยัน qf_corpus ไม่ถูกแตะ (fingerprint เดิม %)', now_fp;
END $$;

SELECT count(*) AS "corpus จริง", pg_size_pretty(pg_total_relation_size('qf_real2')) AS "ขนาด"
FROM qf_real2;
