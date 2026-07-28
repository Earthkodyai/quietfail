-- ============================================================
-- L02 — แถวที่ถูกลบแต่ยังไม่ vacuum ทำให้ index คืนผลไม่ครบ
--
-- รัน:  psql ... -f /sql/l02_dead_tuples.sql
--
-- FAQ ของ pgvector ระบุว่าผลลัพธ์อาจน้อยลงได้เพราะ dead tuples
-- และ vacuum ของ HNSW ใช้เวลานาน — วัดเองทั้งสองเรื่อง
--
-- ⭐ กลไกเดียวกับ Q03 แต่ **ตัวกรองมองไม่เห็น**
--    Q03: index คืน candidate ตาม ef_search แล้ว WHERE คัดออกทีหลัง
--    L02: index คืน candidate ตาม ef_search แล้ว **MVCC** คัดออกทีหลัง
--    ต่างกันตรงที่ Q03 เห็น WHERE ในโค้ด ส่วน L02 ไม่มีอะไรในคำสั่งบอกเลย
--
-- ⚠️ ชื่อในทะเบียนเดิมคือ "dead tuple สะสม → index บวม recall ตก"
--    ควบคุมด้วย UPDATE พบว่า **บวมกับ recall ตกเป็นคนละเรื่อง** — ดูส่วนที่ 5
--
-- ⚠️ n_dead_tup จาก pg_stat_user_tables มาช้า เชื่อไม่ได้ระหว่างสคริปต์เดียว
--    (probe 1 รายงาน 0 ตอนลบ แล้วโผล่ 99,900 หลัง vacuum · ตระกูลเดียวกับ E19)
--    → ใช้ "จำนวนแถวที่ลบจริง" เป็นตัวเลขหลัก ไม่ใช่ตัวนับของ stats collector
--
-- ⚠️ ไม่แตะ qf_corpus — ใช้ตารางแยก qf_l02
-- ============================================================

\set ON_ERROR_STOP on
\timing off
LOAD 'vector';

-- กับดักข้อ 4
DROP INDEX IF EXISTS qf_l02_idx;
DROP TABLE IF EXISTS qf_l02;
DROP TABLE IF EXISTS qf_l02_obs;
DROP TABLE IF EXISTS qf_l02_ctl;
DROP TABLE IF EXISTS qf_l02_guard;

CREATE TABLE qf_l02_guard AS
SELECT count(*) AS rows_before,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS fp_before
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;

SET temp_file_limit = '2GB';

CREATE TABLE qf_l02_obs (
    stage text, dead_pct numeric, live bigint, asked int,
    got_index bigint, got_exact bigint, idx_size text
);
CREATE TABLE qf_l02_ctl (
    stage text, live bigint, idx_size text, asked int, got bigint, recall numeric
);

-- ============================================================
CREATE OR REPLACE FUNCTION qf_l02_ask(p_limit int) RETURNS bigint AS $$
DECLARE n bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM (SELECT id FROM qf_l02 '
                   'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) '
                   'LIMIT %s) s', p_limit) INTO n;
    RETURN n;
END $$ LANGUAGE plpgsql;

-- เฉลย: ปิด index scan ตามวิธีที่เอกสาร pgvector แนะนำ (ห้ามใช้ DROP INDEX)
CREATE OR REPLACE FUNCTION qf_l02_ask_exact(p_limit int) RETURNS bigint AS $$
DECLARE n bigint;
BEGIN
    PERFORM set_config('enable_indexscan', 'off', true);
    PERFORM set_config('enable_bitmapscan', 'off', true);
    EXECUTE format('SELECT count(*) FROM (SELECT id FROM qf_l02 '
                   'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) '
                   'LIMIT %s) s', p_limit) INTO n;
    PERFORM set_config('enable_indexscan', 'on', true);
    PERFORM set_config('enable_bitmapscan', 'on', true);
    RETURN n;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_l02_recall() RETURNS numeric AS $$
DECLARE r numeric;
BEGIN
    SELECT round(avg(x), 4) INTO r FROM (
        SELECT (SELECT count(*) FROM unnest(t.ids) AS tid
                 WHERE tid = ANY (SELECT l.id FROM qf_l02 l
                                  ORDER BY l.embedding <=> q.embedding LIMIT 10)
               )::numeric / 10 AS x
        FROM qf_truth t JOIN qf_queries q ON q.id = t.query_id WHERE t.k = 10) s;
    RETURN r;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_l02_note(p_stage text, p_dead numeric) RETURNS void AS $$
BEGIN
    INSERT INTO qf_l02_obs
    SELECT p_stage, p_dead, count(*), 10, qf_l02_ask(10), qf_l02_ask_exact(10),
           pg_size_pretty(pg_relation_size('qf_l02_idx'))
    FROM qf_l02;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_l02_fresh() RETURNS void AS $$
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_l02_idx';
    EXECUTE 'DROP TABLE IF EXISTS qf_l02';
    EXECUTE 'CREATE TABLE qf_l02 (id int PRIMARY KEY, embedding vector(384))';
    EXECUTE 'INSERT INTO qf_l02 SELECT id, embedding FROM qf_corpus';
    EXECUTE 'ANALYZE qf_l02';
    EXECUTE 'CREATE INDEX qf_l02_idx ON qf_l02 USING hnsw (embedding vector_cosine_ops)';
    -- ปิด autovacuum เฉพาะตารางนี้ ไม่งั้นมันเก็บกวาดเองระหว่างวัด
    EXECUTE 'ALTER TABLE qf_l02 SET (autovacuum_enabled = false)';
    -- กฎเหล็กข้อ 8 — อุ่น cache
    PERFORM count(*) FROM (SELECT id FROM qf_l02
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 10) w;
END $$ LANGUAGE plpgsql;

\qecho '=== ค่าที่ใช้ ==='
SELECT current_setting('hnsw.ef_search')  AS ef_search,
       current_setting('autovacuum')      AS autovacuum_global;

-- ============================================================
\qecho ''
\qecho '=== ส่วนที่ 1-3: ลบทีละขั้นบน index ตัวเดียว ไม่ vacuum เลย ==='
\qecho '    เฉลย (ปิด index scan) ต้องได้ 10 ทุกขั้น เพราะแถวที่เหลือยังมีเกิน 10 เสมอ'
SELECT qf_l02_fresh();
SELECT qf_l02_note('0_ฐาน', 0);

DELETE FROM qf_l02 WHERE id % 10 = 0;
SELECT qf_l02_note('1_ตาย 10%', 10);

DELETE FROM qf_l02 WHERE id % 10 = 1;
SELECT qf_l02_note('2_ตาย 20%', 20);

DELETE FROM qf_l02 WHERE id % 10 = 2;
SELECT qf_l02_note('3_ตาย 30%', 30);

DELETE FROM qf_l02 WHERE id % 10 = 3;
SELECT qf_l02_note('4_ตาย 40%', 40);

DELETE FROM qf_l02 WHERE id % 10 = 4;
SELECT qf_l02_note('5_ตาย 50%', 50);

DELETE FROM qf_l02 WHERE id % 10 IN (5,6);
SELECT qf_l02_note('6_ตาย 70%', 70);

DELETE FROM qf_l02 WHERE id % 10 IN (7,8);
SELECT qf_l02_note('7_ตาย 90%', 90);

SELECT stage AS "ขั้น", dead_pct AS "ตายไป %", live AS "แถวที่ยังอยู่",
       asked AS "ขอ", got_index AS "ได้จาก index", got_exact AS "เฉลย",
       idx_size AS "ขนาด index"
FROM qf_l02_obs ORDER BY stage;

\qecho ''
\qecho '=== ส่วนที่ 4: ขอเยอะขึ้นช่วยไหม (ที่ตาย 90%) ==='
SELECT 10 AS ขอ, qf_l02_ask(10) AS ได้
UNION ALL SELECT 40, qf_l02_ask(40)
UNION ALL SELECT 100, qf_l02_ask(100)
UNION ALL SELECT 1000, qf_l02_ask(1000);

\qecho ''
\qecho '=== VACUUM แล้ววัดใหม่ · จับเวลา (FAQ บอกว่า HNSW vacuum ช้า) ==='
DROP TABLE IF EXISTS qf_l02_vac;
CREATE TABLE qf_l02_vac (ms numeric, size_before text, size_after text);
DO $$
DECLARE t0 timestamptz; sz_b text; sz_a text;
BEGIN
    SELECT pg_size_pretty(pg_relation_size('qf_l02_idx')) INTO sz_b;
    t0 := clock_timestamp();
    -- VACUUM รันใน DO block ไม่ได้ จึงจดขนาดไว้ก่อน แล้ว VACUUM ข้างล่าง
    INSERT INTO qf_l02_vac VALUES (NULL, sz_b, NULL);
END $$;

\timing on
VACUUM qf_l02;
\timing off

UPDATE qf_l02_vac SET size_after = pg_size_pretty(pg_relation_size('qf_l02_idx'));
SELECT qf_l02_note('8_หลัง VACUUM', 0);

SELECT size_before AS "ขนาด index ก่อน", size_after AS "หลัง VACUUM" FROM qf_l02_vac;
SELECT stage AS "ขั้น", live AS "แถวที่ยังอยู่", asked AS "ขอ",
       got_index AS "ได้จาก index", got_exact AS "เฉลย"
FROM qf_l02_obs WHERE stage LIKE '8%';

-- ============================================================
\qecho ''
\qecho '=== ส่วนที่ 5: กลุ่มควบคุม — UPDATE ทำให้เกิดแบบเดียวกันไหม ==='
\qecho '    แถวยังอยู่ครบ 100,000 แต่เวอร์ชันเก่าตายค้าง · ทะเบียนเดิมบอกว่า index บวม -> recall ตก'
SELECT qf_l02_fresh();

INSERT INTO qf_l02_ctl
SELECT 'ฐาน', count(*), pg_size_pretty(pg_relation_size('qf_l02_idx')),
       10, qf_l02_ask(10), qf_l02_recall() FROM qf_l02;

-- แก้ค่าเดิมทับตัวเอง ข้อมูลไม่เปลี่ยนเลย แต่เกิดเวอร์ชันเก่าตายค้าง
UPDATE qf_l02 SET embedding = embedding WHERE id % 2 = 0;
INSERT INTO qf_l02_ctl
SELECT 'UPDATE 50%', count(*), pg_size_pretty(pg_relation_size('qf_l02_idx')),
       10, qf_l02_ask(10), qf_l02_recall() FROM qf_l02;

UPDATE qf_l02 SET embedding = embedding;
INSERT INTO qf_l02_ctl
SELECT 'UPDATE ทั้งตาราง', count(*), pg_size_pretty(pg_relation_size('qf_l02_idx')),
       10, qf_l02_ask(10), qf_l02_recall() FROM qf_l02;

SELECT stage AS "ขั้น", live AS "แถวที่ยังอยู่", idx_size AS "ขนาด index",
       asked AS "ขอ", got AS "ได้", recall FROM qf_l02_ctl;

-- ============================================================
\qecho ''
\qecho '=== assertion ==='
DO $$
DECLARE
    base_got   bigint;
    n_exact_ok int;
    n_broken   int;
    cliff      record;
    after_vac  bigint;
    ctl_min    bigint;
    ctl_rows   int;
    rows_now bigint; fp_now text; g record;
BEGIN
    -- 1) ฐานต้องได้ครบ ไม่งั้นวัดอะไรไม่ได้เลย
    SELECT got_index INTO base_got FROM qf_l02_obs WHERE stage = '0_ฐาน';
    IF base_got <> 10 THEN
        RAISE EXCEPTION 'ฐานได้ % จาก 10 — ตั้งต้นก็ผิดแล้ว', base_got;
    END IF;
    RAISE NOTICE '[1/6] OK ฐานได้ครบ 10 แถว';

    -- 2) เฉลยต้องได้ครบทุกขั้น — แถวยังอยู่จริง ไม่ได้หายจากตาราง
    SELECT count(*) INTO n_exact_ok FROM qf_l02_obs WHERE got_exact <> 10;
    IF n_exact_ok > 0 THEN
        RAISE EXCEPTION 'เฉลยไม่ครบ % ขั้น — แถวหายจากตารางจริง ไม่ใช่ปัญหาของ index', n_exact_ok;
    END IF;
    RAISE NOTICE '[2/6] OK เฉลยได้ครบ 10 ทุกขั้น — แถวยังอยู่ในตาราง เส้นทาง index ต่างหากที่ทำหาย';

    -- 3) ต้องมีขั้นที่ index คืนไม่ครบ ไม่งั้น fault ไม่เกิด
    SELECT count(*) INTO n_broken FROM qf_l02_obs
     WHERE stage NOT LIKE '8%' AND got_index < asked;
    IF n_broken = 0 THEN
        RAISE EXCEPTION 'ไม่มีขั้นไหนที่ index คืนไม่ครบ — fault ไม่เกิดตามที่ตั้งใจ';
    END IF;
    SELECT * INTO cliff FROM qf_l02_obs
     WHERE stage NOT LIKE '8%' AND got_index < asked ORDER BY dead_pct ASC LIMIT 1;
    RAISE NOTICE '[3/6] OK มี % ขั้นที่คืนไม่ครบ · หน้าผาเริ่มที่ตาย %%% (ได้ % จาก %)',
                 n_broken, cliff.dead_pct, cliff.got_index, cliff.asked;

    -- 4) VACUUM ต้องแก้ได้
    SELECT got_index INTO after_vac FROM qf_l02_obs WHERE stage LIKE '8%';
    IF after_vac <> 10 THEN
        RAISE EXCEPTION 'หลัง VACUUM ยังได้ % จาก 10 — ทางแก้ไม่ทำงาน', after_vac;
    END IF;
    RAISE NOTICE '[4/6] OK VACUUM แก้ได้หมด — กลับมาครบ 10 แถว';

    -- 5) กลุ่มควบคุม UPDATE — ต้องรายงานตรงๆ ว่าเกิดหรือไม่เกิด
    SELECT min(got), count(*) INTO ctl_min, ctl_rows FROM qf_l02_ctl;
    IF ctl_rows < 3 THEN
        RAISE EXCEPTION 'กลุ่มควบคุม UPDATE ไม่ครบ 3 ขั้น (ได้ %)', ctl_rows;
    END IF;
    RAISE NOTICE '[5/6] OK กลุ่มควบคุม UPDATE ครบ 3 ขั้น · น้อยสุดที่ได้คืนมา = % จาก 10', ctl_min;

    -- 6) qf_corpus ต้องไม่ถูกแตะ
    SELECT count(*), md5(string_agg(embedding::text, '|' ORDER BY id))
      INTO rows_now, fp_now
      FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
    SELECT * INTO g FROM qf_l02_guard;
    IF rows_now <> g.rows_before OR fp_now <> g.fp_before THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยน!';
    END IF;
    RAISE NOTICE '[6/6] OK qf_corpus ไม่ถูกแตะ';

    RAISE NOTICE '';
    IF ctl_min = 10 THEN
        RAISE NOTICE '⭐ UPDATE **ไม่ทำให้เกิด** — index บวมจริงแต่ผลยังครบ';
        RAISE NOTICE '   ชื่อในทะเบียน "dead tuple สะสม -> index บวม recall ตก" จึงกว้างเกินไป';
        RAISE NOTICE '   ต้นเหตุคือแถวที่ถูก **ลบแล้วไม่มีตัวแทน** ไม่ใช่ dead tuple ทุกชนิด';
    ELSE
        RAISE NOTICE 'UPDATE ก็ทำให้เกิดเหมือนกัน (น้อยสุด % จาก 10) — ชื่อในทะเบียนถูกแล้ว', ctl_min;
    END IF;
END $$;

\qecho ''
\qecho '=== เก็บกวาด: ทิ้ง index กับตารางข้อมูล เก็บตารางผลไว้ ==='
DROP INDEX IF EXISTS qf_l02_idx;
DROP TABLE IF EXISTS qf_l02_guard;
DROP TABLE IF EXISTS qf_l02_vac;
DROP FUNCTION IF EXISTS qf_l02_ask(int);
DROP FUNCTION IF EXISTS qf_l02_ask_exact(int);
DROP FUNCTION IF EXISTS qf_l02_recall();
DROP FUNCTION IF EXISTS qf_l02_note(text, numeric);
DROP FUNCTION IF EXISTS qf_l02_fresh();

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');
