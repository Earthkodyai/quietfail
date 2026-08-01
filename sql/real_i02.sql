-- ============================================================
-- I02 บน embedding จริง — ข้อสรุปรอดนอก corpus สังเคราะห์ไหม
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -v rounds=3 -f //sql/real_i02.sql
--
-- ต้องรัน real_load.sql ก่อน
--
-- เล่มวิทยานิพนธ์ 5.2 ข้อ 2 ระบุชื่อ I02 ไว้ตรงๆ ว่าผลผูกกับโครงสร้างของ
-- corpus สังเคราะห์ — ไฟล์นี้ทดสอบข้อนั้น
--
-- วิธีเดียวกับ i02_index_built_too_early.sql เป๊ะ:
--   ข้อมูลปลายทางเหมือนกันทุกเงื่อนไข 100,000 แถว · เปลี่ยนแค่ "ตอนที่ build"
--
--   A  build ตอนมี     50 แถว   (rows < lists -> pgvector ส่ง NOTICE)
--   B  build ตอนมี  1,000 แถว   (rows > lists -> เงียบสนิท)
--   C  build ตอนมี 100,000 แถว  (วิธีที่เอกสารบอก -> เงียบ)
--   D  build ตอนมี  1,000 แถว **ที่กระจุกอยู่ในบริเวณแคบ** -> เงียบ
--
-- ⚠️ เงื่อนไข D ต้องแปล เพราะ embedding จริงไม่มี cluster_id ที่เราออกแบบไว้
--    ของเดิมใช้ "1,000 แถวจาก 5 กลุ่มใน 50"
--    ที่นี่ใช้ **1,000 เพื่อนบ้านที่ใกล้จุดยึดที่สุด** = ลูกบอลแคบๆ ในปริภูมิ
--    ซึ่งเป็นความหมายเดียวกันคือ "ตัวอย่างตอน build ไม่ครอบคลุมการกระจายของข้อมูล"
--
-- ⚠️ ไม่แตะ qf_corpus และ qf_real — ทำงานบนสำเนา qf_i02r เท่านั้น
-- ============================================================
\timing on
\set ON_ERROR_STOP on

SET qf.rounds = :'rounds';

-- ⭐ guard ตารางต้นทาง — ไฟล์นี้อ่าน qf_real อย่างเดียว ห้ามเขียน (เพิ่ม 2026-08-02)
DROP TABLE IF EXISTS qf_i02r_guard;
CREATE TABLE qf_i02r_guard AS SELECT count(*) AS n FROM qf_real;

DROP TABLE IF EXISTS qf_i02r_obs;
DROP TABLE IF EXISTS qf_i02r_meta;
DROP TABLE IF EXISTS qf_i02r;

CREATE TABLE qf_i02r (id bigint PRIMARY KEY, embedding vector(384));

CREATE TABLE qf_i02r_meta (
    round        int,
    cond         text,
    rows_at_build bigint,
    notice_fired bool,
    build_ms     numeric,
    final_rows   bigint,
    final_fp     text
);

CREATE TABLE qf_i02r_obs (
    round int, cond text, query_id int, recall numeric
);

-- ------------------------------------------------------------
-- ตัววัด — เรียกหลัง build + เติมข้อมูลจนครบแล้ว
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_i02r_measure(
    p_round int, p_cond text, p_rows_at_build bigint, p_build_ms numeric
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    n_final bigint; fp text;
BEGIN
    -- กฎเหล็กข้อ 8: อุ่น cache
    PERFORM (SELECT count(*) FROM (
        SELECT c.id FROM qf_i02r c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_real_q WHERE id = 0)
        LIMIT 10) w);

    -- ⭐ ต้องยืนยันว่า **ข้อมูลปลายทางเหมือนกันทุกเงื่อนไข**
    --    ไม่งั้นความต่างของ recall อาจมาจากข้อมูล ไม่ใช่จากตอนที่ build
    SELECT count(*) INTO n_final FROM qf_i02r;
    SELECT md5(string_agg(embedding::text, '|' ORDER BY id)) INTO fp
      FROM (SELECT id, embedding FROM qf_i02r ORDER BY id LIMIT 5000) s;

    INSERT INTO qf_i02r_meta VALUES (
        p_round, p_cond, p_rows_at_build,
        p_rows_at_build < 100,        -- NOTICE ออกเมื่อ rows < lists (probe ของ I02)
        round(p_build_ms), n_final, fp);

    INSERT INTO qf_i02r_obs (round, cond, query_id, recall)
    SELECT p_round, p_cond, t.query_id,
           (SELECT count(*) FROM unnest(t.ids) AS tid
             WHERE tid = ANY (SELECT c.id FROM qf_i02r c
                               ORDER BY c.embedding <=> q.embedding LIMIT 10))::numeric / 10
    FROM qf_real_truth t JOIN qf_real_q q ON q.id = t.query_id
    WHERE t.k = 10;
END $$;

-- ------------------------------------------------------------
-- A · B · C — ตัวอย่างตอน build เป็นแถวแรกๆ ตาม id (กระจายทั่วชุดข้อมูล)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_i02r_run(p_round int, p_cond text, p_rows bigint)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; ms numeric;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02r_idx';
    TRUNCATE qf_i02r;

    INSERT INTO qf_i02r SELECT id, embedding FROM qf_real ORDER BY id LIMIT p_rows;

    t0 := clock_timestamp();
    EXECUTE 'CREATE INDEX qf_i02r_idx ON qf_i02r '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    -- เติมให้ครบ 100,000 — index ถูกสร้างไปแล้วจากตัวอย่างชุดแรกเท่านั้น
    INSERT INTO qf_i02r
    SELECT c.id, c.embedding FROM qf_real c
    WHERE NOT EXISTS (SELECT 1 FROM qf_i02r x WHERE x.id = c.id);

    PERFORM qf_i02r_measure(p_round, p_cond, p_rows, ms);
    EXECUTE 'DROP INDEX IF EXISTS qf_i02r_idx';
END $$;

-- ------------------------------------------------------------
-- D — ตัวอย่างตอน build กระจุกอยู่ในบริเวณแคบ
--     ใช้เพื่อนบ้านที่ใกล้ "จุดยึด" ที่สุด p_rows ตัว
--     = ลูกบอลแคบๆ ในปริภูมิ ไม่ครอบคลุมการกระจายของข้อมูล
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_i02r_run_narrow(p_round int, p_rows bigint)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; ms numeric; anchor vector(384);
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02r_idx';
    TRUNCATE qf_i02r;

    SELECT embedding INTO anchor FROM qf_real ORDER BY id LIMIT 1;

    INSERT INTO qf_i02r
    SELECT id, embedding FROM qf_real ORDER BY embedding <=> anchor LIMIT p_rows;

    t0 := clock_timestamp();
    EXECUTE 'CREATE INDEX qf_i02r_idx ON qf_i02r '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    INSERT INTO qf_i02r
    SELECT c.id, c.embedding FROM qf_real c
    WHERE NOT EXISTS (SELECT 1 FROM qf_i02r x WHERE x.id = c.id);

    PERFORM qf_i02r_measure(p_round, 'D แคบ', p_rows, ms);
    EXECUTE 'DROP INDEX IF EXISTS qf_i02r_idx';
END $$;

-- ------------------------------------------------------------
-- รันทุกเงื่อนไข ซ้ำหลายรอบ (I04 บังคับ — build ไม่ reproducible)
-- ------------------------------------------------------------
DO $$
DECLARE
    r int;
    n int := coalesce(current_setting('qf.rounds', true)::int, 3);
BEGIN
    LOAD 'vector';
    PERFORM set_config('temp_file_limit', '2GB', false);   -- กับดักข้อ 8

    FOR r IN 1..n LOOP
        RAISE NOTICE '=== รอบ %/% ===', r, n;
        PERFORM qf_i02r_run(r, 'A 50',      50);
        PERFORM qf_i02r_run(r, 'B 1000',    1000);
        PERFORM qf_i02r_run(r, 'C 100000',  100000);
        PERFORM qf_i02r_run_narrow(r,       1000);
    END LOOP;
END $$;

-- ------------------------------------------------------------
-- assertion
-- ------------------------------------------------------------
DO $$
DECLARE n_fp int; n_rows int; n_idx int;
BEGIN
    -- ⭐ ข้อสำคัญที่สุด: ข้อมูลปลายทางต้องเหมือนกันเป๊ะทุกเงื่อนไขทุกรอบ
    SELECT count(DISTINCT final_fp), count(DISTINCT final_rows)
      INTO n_fp, n_rows FROM qf_i02r_meta;
    IF n_fp <> 1 OR n_rows <> 1 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: ข้อมูลปลายทางไม่เหมือนกัน (fingerprint % แบบ · จำนวนแถว % แบบ) '
            '→ ความต่างของ recall อาจมาจากข้อมูล ไม่ใช่จากตอนที่ build', n_fp, n_rows;
    END IF;
    RAISE NOTICE '[1/2] OK ข้อมูลปลายทางเหมือนกันเป๊ะทุกเงื่อนไข';

    SELECT count(*) INTO n_idx
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE '[2/2] OK ไม่มี index ค้าง';
END $$;

-- ------------------------------------------------------------
-- ผล
-- ------------------------------------------------------------
SELECT m.cond                             AS "เงื่อนไข",
       max(m.rows_at_build)               AS "แถวตอน build",
       bool_or(m.notice_fired)            AS "pgvector เตือน",
       count(DISTINCT m.round)            AS "รอบ",
       round(avg(o.recall), 4)            AS "recall@10 เฉลี่ย",
       round(min(agg.r), 4)               AS "รอบที่ต่ำสุด",
       round(max(agg.r), 4)               AS "รอบที่สูงสุด",
       count(*) FILTER (WHERE o.recall = 0) AS "query ที่ได้ 0 อัน"
FROM qf_i02r_meta m
JOIN qf_i02r_obs o ON o.round = m.round AND o.cond = m.cond
JOIN LATERAL (SELECT avg(o2.recall) AS r FROM qf_i02r_obs o2
              WHERE o2.round = m.round AND o2.cond = m.cond) agg ON true
GROUP BY m.cond ORDER BY m.cond;


-- ============================================================================
-- เก็บกวาด + guard ปิดท้าย
-- ============================================================================
-- 🔴 ไฟล์นี้เดิม **ไม่มีการเก็บกวาดเลย** — จบด้วย SELECT รายงานผลแล้วหยุด
--    ตาราง qf_i02r เป็นสำเนา embedding ขนาดราว 400 MB จึงค้างสะสมทุกครั้งที่รัน
--    (กับดักข้อ 14ฐ · ไฟล์ที่ 8 ที่เจอรูปแบบนี้ และเป็นรายเดียวที่ไม่มี DROP
--     แม้แต่ตอนต้นไฟล์สำหรับตัวมันเอง) · ผลจริงอยู่ใน results/
DO $$
DECLARE n_before bigint; n_now bigint;
BEGIN
    SELECT n INTO n_before FROM qf_i02r_guard;
    SELECT count(*) INTO n_now FROM qf_real;
    IF n_before <> n_now THEN
        RAISE EXCEPTION 'ตารางต้นทางเปลี่ยนจำนวนแถว! ก่อน % หลัง % — ไฟล์นี้ต้องอ่านอย่างเดียว',
                        n_before, n_now;
    END IF;
    RAISE NOTICE 'ตารางต้นทางไม่ถูกแตะ (% แถวเท่าเดิม)', n_now;
END $$;

DROP TABLE IF EXISTS qf_i02r_guard;
DROP FUNCTION IF EXISTS qf_i02r_measure(int, text, bigint, numeric);
DROP TABLE IF EXISTS qf_i02r_obs  CASCADE;
DROP TABLE IF EXISTS qf_i02r_meta CASCADE;
DROP TABLE IF EXISTS qf_i02r      CASCADE;

\echo ''
\echo '✅ เก็บกวาดครบ — ตารางต้นทางไม่ถูกแตะ · ไม่มีสำเนา embedding ค้าง'
