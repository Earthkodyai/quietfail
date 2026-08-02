-- ============================================================
-- Q02 — เขียน query ผิดรูป → index ไม่ถูกใช้ ทั้งที่มี index อยู่
--
-- รัน:  psql ... -f /sql/q02_wrong_query_shape.sql
--
-- อาการ  : ช้าเหมือนไม่มี index ทั้งที่ \di เห็น index อยู่
-- ต้นเหตุ: เอกสารกำหนดรูปแบบ query ไว้ 3 อย่าง ผิดข้อใดข้อหนึ่งก็ใช้ index ไม่ได้
--            1. ต้องมี ORDER BY **และ** LIMIT
--            2. ORDER BY ต้องเป็นผลของ distance operator **โดยตรง**
--            3. ต้องเรียงจากน้อยไปมาก (ASC)
--
-- ⭐ ต่างจาก I01 ตรงที่ I01 ผิดที่ **ตอนสร้าง index** (opclass)
--    ส่วน Q02 ผิดที่ **ตอนเขียน query** — index ถูกต้องทุกอย่าง
--    อาการเหมือนกันเป๊ะ แต่แก้คนละที่
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_q02_idx;
--    แล้วยืนยันด้วย    python scripts/audit.py
\set ON_ERROR_STOP on
LOAD 'vector';
SET max_parallel_workers_per_gather = 0;

DO $$
DECLARE fp text; n int;
BEGIN
    SELECT value INTO fp FROM qf_manifest WHERE item = 'query_set_fingerprint';
    IF fp IS DISTINCT FROM '607babfb6344eab74d3e76496b04fa9f' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: fingerprint ชุด query ไม่ตรง (ได้ %)', fp;
    END IF;
    SELECT count(*) INTO n
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n <> 0 THEN
        RAISE EXCEPTION 'จุดเริ่มต้นไม่สะอาด: มี vector index ค้าง % ตัว', n;
    END IF;
    RAISE NOTICE 'ด่านตรวจผ่าน';
END $$;

DROP TABLE IF EXISTS qf_q02_results;
CREATE TABLE qf_q02_results (
    variant     text,
    shape       text,
    index_used  boolean,
    plan_node   text,
    rows_got    bigint,
    ms          numeric,
    buffers     bigint,
    got_error   boolean,
    -- 🔴 เพิ่ม 2026-08-02 — เดิมจับ error แล้วทิ้งข้อความทิ้ง
    --    assertion ข้อ 5 มีไว้จับ "ต้องไม่มี error เลย" โดยเฉพาะ
    --    แต่ตอนมันฟ้อง ผู้รันไม่มีทางรู้ว่า error อะไร = รูปแบบเดียวกับกับดักข้อ 1
    err_msg     text
);

SET temp_file_limit = '2GB';
SET maintenance_work_mem = '256MB';
CREATE INDEX qf_q02_idx ON qf_corpus USING hnsw (embedding vector_cosine_ops);
RESET temp_file_limit;

-- ============================================================
-- ตัววัด — รับ SQL มาทั้งก้อน แล้วอ่าน plan node ที่สแกน qf_corpus
--
-- ⚠️ อ่าน node ที่ระบุชื่อตาราง ไม่ใช่ค้นคำ "Index Scan" ทั้ง plan
--    เคยพลาดเพราะ subquery ของตารางอื่นใช้ pkey (E25)
-- ============================================================
CREATE OR REPLACE FUNCTION qf_q02_probe(p_variant text, p_shape text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    plan_txt text := ''; line text; node text; used boolean;
    t0 timestamptz; ms numeric; n bigint; buf bigint; err boolean := false; j json;
    emsg text;
BEGIN
    BEGIN
        -- อุ่น cache (กฎเหล็กข้อ 8)
        EXECUTE format('SELECT count(*) FROM (%s) z', p_sql) INTO n;

        t0 := clock_timestamp();
        EXECUTE format('SELECT count(*) FROM (%s) z', p_sql) INTO n;
        ms := round((extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric, 1);

        FOR line IN EXECUTE format('EXPLAIN (ANALYZE, BUFFERS) %s', p_sql) LOOP
            plan_txt := plan_txt || line || E'\n';
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        err  := true;
        emsg := SQLSTATE || ': ' || SQLERRM;
    END;

    IF err THEN
        INSERT INTO qf_q02_results
        VALUES (p_variant, p_shape, NULL, 'ERROR', NULL, NULL, NULL, true, emsg);
        RETURN;
    END IF;

    node := (regexp_match(plan_txt, '([A-Z][A-Za-z ]*Scan)[^\n]* on qf_corpus'))[1];
    IF node IS NULL THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: หา node ที่สแกน qf_corpus ไม่เจอ · แผน:%', E'\n' || plan_txt;
    END IF;
    used := node ILIKE '%Index%';

    -- ⚠️ ต้องรวม hit + read ไม่ใช่นับแค่ hit
    --
    -- Seq Scan บนตารางที่ vector ถูก TOAST ไว้ จะได้ hit น้อยมากแต่ read เยอะมาก
    -- นับแค่ hit จะได้ 12 ทั้งที่ความจริงอ่าน 20,007 block
    -- แล้วสรุปกลับหัวว่า "ไม่ใช้ index อ่านน้อยกว่า" ซึ่งผิดสิ้นเชิง
    --
    -- ใช้ JSON แทน regex เพราะ q01/i01 ใช้วิธีนี้อยู่แล้วและถูกต้อง
    EXECUTE format('EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s', p_sql) INTO j;
    buf := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
         + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

    INSERT INTO qf_q02_results
    VALUES (p_variant, p_shape, used, node, n, ms, buf, false, NULL);
END $$;

-- ============================================================
-- ไล่ทดสอบทุกรูปแบบ
-- ตัวแปร :qv คือ vector ของ query ที่ 1 ใส่เป็นค่าคงที่ ไม่ใช่ subquery
-- (subquery ทำให้ plan มี index scan ของตารางอื่นปน — E25)
-- ============================================================
\qecho
\qecho '=== ไล่ทดสอบรูปแบบ query ==='

SELECT set_config('qf.qv', (SELECT embedding::text FROM qf_queries WHERE id = 1), false) \gset

DO $$
DECLARE q text := current_setting('qf.qv');
BEGIN
    -- A: รูปแบบที่เอกสารกำหนด
    PERFORM qf_q02_probe('A ถูกต้อง', 'ORDER BY <=> ASC + LIMIT',
        format('SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> %L::vector LIMIT 10', q));

    -- B: WHERE threshold อย่างเดียว ไม่มี ORDER BY / LIMIT  ← fault หลัก
    PERFORM qf_q02_probe('B WHERE อย่างเดียว', 'WHERE <=> < 0.5',
        format('SELECT c.id FROM qf_corpus c WHERE c.embedding <=> %L::vector < 0.5', q));

    -- C: WHERE threshold + ORDER BY + LIMIT
    PERFORM qf_q02_probe('C WHERE + ORDER BY', 'WHERE <=> < 0.5 + ORDER BY + LIMIT',
        format('SELECT c.id FROM qf_corpus c WHERE c.embedding <=> %L::vector < 0.5 '
               'ORDER BY c.embedding <=> %L::vector LIMIT 10', q, q));

    -- D: เรียงจากมากไปน้อย
    PERFORM qf_q02_probe('D เรียง DESC', 'ORDER BY <=> DESC + LIMIT',
        format('SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> %L::vector DESC LIMIT 10', q));

    -- E: ORDER BY ที่ไม่ใช่ผลของ operator โดยตรง
    PERFORM qf_q02_probe('E ห่อด้วยนิพจน์', 'ORDER BY (<=> ) + 0',
        format('SELECT c.id FROM qf_corpus c ORDER BY (c.embedding <=> %L::vector) + 0 LIMIT 10', q));

    -- F: มี ORDER BY แต่ไม่มี LIMIT
    PERFORM qf_q02_probe('F ไม่มี LIMIT', 'ORDER BY <=> ASC ไม่มี LIMIT',
        format('SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> %L::vector', q));
END $$;

\qecho
\qecho '=== ผล: รูปแบบไหนใช้ index ได้บ้าง ==='
SELECT variant AS "รูปแบบ", shape AS "เขียนแบบ",
       CASE WHEN index_used THEN 'ใช้' ELSE 'ไม่ใช้' END AS "index",
       plan_node AS "plan node", rows_got AS "ได้กี่แถว",
       ms AS "ms", buffers, got_error AS "error"
FROM qf_q02_results ORDER BY variant;

DROP INDEX qf_q02_idx;

-- เก็บกวาดฟังก์ชันตัววัด — เดิมค้างอยู่ในฐานหลังไฟล์จบ
-- วางไว้ **ก่อน** assertion เพราะถ้า assertion ตก บรรทัดหลังจากนั้นจะไม่ถูกรัน
DROP FUNCTION IF EXISTS qf_q02_probe(text, text, text);

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    a qf_q02_results%ROWTYPE;
    b qf_q02_results%ROWTYPE;
    d qf_q02_results%ROWTYPE;
    n_err int; n_bad int;
BEGIN
    SELECT * INTO a FROM qf_q02_results WHERE variant LIKE 'A%';
    SELECT * INTO b FROM qf_q02_results WHERE variant LIKE 'B%';
    SELECT * INTO d FROM qf_q02_results WHERE variant LIKE 'D%';

    -- ข้อ 1: รูปแบบที่ถูกต้องต้องใช้ index (กลุ่มควบคุม)
    IF NOT a.index_used THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: รูปแบบที่ถูกต้องยังไม่ใช้ index (%) → สภาพแวดล้อมมีปัญหา ข้ออื่นไม่พิสูจน์อะไร',
            a.plan_node;
    END IF;
    RAISE NOTICE '[1/5] OK รูปแบบที่เอกสารกำหนด ใช้ index จริง (%)', a.plan_node;

    -- ข้อ 2: WHERE threshold อย่างเดียว ต้องไม่ใช้ index
    IF b.index_used THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: WHERE threshold ยังใช้ index (%) — fault ไม่เกิด', b.plan_node;
    END IF;
    RAISE NOTICE '[2/5] OK WHERE threshold อย่างเดียว ไม่ใช้ index (%)', b.plan_node;

    -- ข้อ 3: ต้องมีอย่างน้อย 2 รูปแบบที่เขียนผิดแล้วไม่ใช้ index
    SELECT count(*) INTO n_bad FROM qf_q02_results
    WHERE variant NOT LIKE 'A%' AND index_used IS NOT TRUE;
    IF n_bad < 2 THEN
        RAISE EXCEPTION 'ข้อ 3 ตก: มีรูปแบบผิดที่ไม่ใช้ index แค่ % แบบ (ต้อง >= 2)', n_bad;
    END IF;
    RAISE NOTICE '[3/5] OK มี % รูปแบบที่เขียนผิดแล้ว index ใช้ไม่ได้', n_bad;

    -- ข้อ 4: อ่าน buffers ได้ และรูปแบบที่ไม่ใช้ index ต้องอ่านมากกว่ามาก
    IF b.buffers IS NULL OR a.buffers IS NULL THEN
        RAISE EXCEPTION 'ข้อ 4 ตรวจไม่ได้: อ่าน buffers จากแผนไม่ได้';
    END IF;
    IF b.buffers <= a.buffers * 5 THEN
        RAISE EXCEPTION 'ข้อ 4 ตก: buffers ต่างกันน้อยเกิน (ถูก % · ผิด %)', a.buffers, b.buffers;
    END IF;
    RAISE NOTICE '[4/5] OK buffers ต่างกัน % เท่า (ถูก % · ผิด %)',
        round(b.buffers::numeric / a.buffers, 1), a.buffers, b.buffers;

    -- ข้อ 5: ต้องไม่มี error เลย — เขียนผิดแล้วยังทำงานได้ คือหัวใจของความเงียบ
    SELECT count(*) INTO n_err FROM qf_q02_results WHERE got_error;
    IF n_err > 0 THEN
        RAISE EXCEPTION E'ข้อ 5 ตก: มี error % กรณี — ถ้ามี error แปลว่าไม่เงียบ
%',
            n_err,
            (SELECT string_agg('  ' || variant || ' -> ' || coalesce(err_msg, '(ไม่ทราบ)'),
                               E'
' ORDER BY variant)
             FROM qf_q02_results WHERE got_error);
    END IF;
    RAISE NOTICE '[5/5] OK ไม่มี error เลยสักรูปแบบ → ทุกแบบ "ทำงานได้" เหมือนกันหมด';

    RAISE NOTICE 'assertion ผ่านครบ 5 ข้อ';
END $$;

\qecho
\qecho '=== index ถูกต้องทุกอย่าง · ผิดที่วิธีเขียน query เท่านั้น ==='
\qecho '=== ทุกรูปแบบคืนผลลัพธ์ได้ ไม่มี error — ต่างกันแค่เร็วช้าและถูกผิด ==='
\qecho '=== I01 แก้ที่ index · Q02 แก้ที่ query — อาการเหมือนกันเป๊ะ ==='
