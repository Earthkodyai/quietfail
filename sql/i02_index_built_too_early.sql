-- ============================================================
-- I02 — สร้าง IVFFlat index ตอนตารางยังเล็ก แล้วข้อมูลโตทีหลัง
--
-- รัน:  psql ... -f /sql/i02_index_built_too_early.sql
--
-- เอกสาร pgvector ระบุเองว่ากุญแจข้อ 1 ของ recall ที่ดีใน IVFFlat
-- คือสร้าง index **หลัง**ตารางมีข้อมูลแล้ว (EVIDENCE.md)
-- และ 0.4.2 เพิ่ม NOTICE เตือนตอนสร้างด้วยข้อมูลน้อย (D11)
--
-- ⭐ แต่ probe พบว่า NOTICE ออกเฉพาะเมื่อ rows < lists เท่านั้น
--    ตั้ง lists=100 แล้ว build ตอนมี 1,000 แถว = **ไม่มีคำเตือนใดๆ**
--    ซึ่งคือกรณีที่เกิดจริงในทีม (ไม่มีใคร build index บน 50 แถวแล้วขึ้น production)
--
-- 3 เงื่อนไข · ข้อมูลปลายทางเหมือนกันเป๊ะ 100,000 แถว · เปลี่ยนแค่ "ตอนที่ build"
--   A  build ตอนมี     50 แถว  (rows < lists -> **มี NOTICE**)  แล้วโตเป็น 100,000
--   B  build ตอนมี  1,000 แถว  (rows > lists -> **เงียบสนิท**)  แล้วโตเป็น 100,000
--   C  build ตอนมี 100,000 แถว (วิธีที่เอกสารบอกให้ทำ)          <- กลุ่มควบคุม
--   D  build ตอนมี  1,000 แถว **จาก 5 กลุ่มเท่านั้น** แล้วโตเป็น 100,000 ครบ 50 กลุ่ม
--
-- ⭐ ทำไมต้องมี D — รอบแรกทำแค่ A/B/C แล้วได้ผลกลับด้าน (A ได้ recall 1.0000)
--    สาเหตุคือ corpus เรียง id แบบสลับกลุ่ม **50 แถวแรกจึงมีครบ 50 กลุ่มพอดีกลุ่มละ 1**
--    = ตัวอย่างที่เป็นตัวแทนสมบูรณ์แบบ ซึ่งไม่ใช่สิ่งที่เกิดในงานจริง
--    A/B จึงวัด "build เร็วบนตัวอย่างที่เป็นตัวแทน" ไม่ใช่ "build เร็วบนข้อมูลที่ยังไม่ใช่ตัวแทน"
--    D คือความหมายจริงของความผิดพลาดนี้: ข้อมูลชุดแรกหน้าตาไม่เหมือนข้อมูลสุดท้าย
--
-- ⚠️ **I04 บังคับให้ต้องทำ 5 รอบ** — I04 พิสูจน์แล้วว่าสร้าง IVFFlat ใหม่บนข้อมูล
--    เดิมเป๊ะ ได้ recall แกว่ง 0.7415–0.8145 (ช่วง 0.073) เทียบ A vs C ครั้งเดียว
--    จึงแยกไม่ออกว่าต่างเพราะเงื่อนไข หรือเพราะ build ไม่ reproducible
--
-- ⚠️ ไม่แตะ qf_corpus — ใช้ตารางแยก qf_i02 และตรวจ fingerprint ก่อน/หลัง
-- ============================================================

\set ON_ERROR_STOP on
\timing off
LOAD 'vector';

-- กับดักข้อ 4 — รอบที่ตายกลางคันทิ้ง state ค้าง
DROP INDEX IF EXISTS qf_i02_idx;
DROP TABLE IF EXISTS qf_i02;
DROP TABLE IF EXISTS qf_i02_obs;
DROP TABLE IF EXISTS qf_i02_meta;
DROP TABLE IF EXISTS qf_i02_guard;

CREATE TABLE qf_i02_guard AS
SELECT count(*) AS rows_before,
       md5(string_agg(embedding::text, '|' ORDER BY id)) AS fp_before
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;

CREATE TABLE qf_i02 (id int PRIMARY KEY, cluster_id int, embedding vector(384));

CREATE TABLE qf_i02_obs (
    round int, cond text, rows_at_build int, query_id int, recall numeric
);
CREATE TABLE qf_i02_meta (
    round int, cond text, rows_at_build int, rows_final bigint,
    notice_expected boolean, build_ms numeric, index_size text,
    buffers_avg numeric, table_fp text
);

\qecho '=== สภาพแวดล้อม ==='
SELECT current_setting('maintenance_work_mem') AS mwm,
       (SELECT count(*) FROM qf_corpus)        AS corpus_rows,
       100                                     AS lists_ที่ใช้;

-- ============================================================
-- ตัววัด
-- ============================================================
CREATE OR REPLACE FUNCTION qf_i02_measure(
    p_round int, p_cond text, p_rows_at_build int, p_build_ms numeric
) RETURNS void AS $$
DECLARE
    sz    text;
    buf   numeric;
    j     json;
    n_fin bigint;
    fp    text;
BEGIN
    -- กฎเหล็กข้อ 8 — อุ่น cache ก่อนวัด
    PERFORM count(*) FROM (
        SELECT c.id FROM qf_i02 c
        ORDER BY c.embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1)
        LIMIT 10) w;

    SELECT pg_size_pretty(pg_relation_size('qf_i02_idx')) INTO sz;
    SELECT count(*) INTO n_fin FROM qf_i02;

    -- ยืนยันว่าข้อมูลปลายทางเหมือนกันทุกเงื่อนไข ไม่ใช่แค่จำนวนแถวเท่ากัน
    SELECT md5(string_agg(embedding::text, '|' ORDER BY id)) INTO fp
    FROM (SELECT id, embedding FROM qf_i02 ORDER BY id LIMIT 5000) s;

    -- กฎเหล็กข้อ 6ก — buffers ต้องรวม hit + read
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
            'SELECT id FROM qf_i02 ORDER BY embedding <=> '
            '(SELECT embedding FROM qf_queries WHERE id = 1) LIMIT 10' INTO j;
    buf := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
         + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

    INSERT INTO qf_i02_meta VALUES (
        p_round, p_cond, p_rows_at_build, n_fin,
        p_rows_at_build < 100,          -- NOTICE ออกเมื่อ rows < lists (probe 3)
        round(p_build_ms, 1), sz, buf, fp);

    -- recall ราย query — I04 สอนว่าค่าเฉลี่ยซ่อนความจริงได้
    INSERT INTO qf_i02_obs (round, cond, rows_at_build, query_id, recall)
    SELECT p_round, p_cond, p_rows_at_build, t.query_id,
           (SELECT count(*) FROM unnest(t.ids) AS tid
             WHERE tid = ANY (SELECT c.id FROM qf_i02 c
                              ORDER BY c.embedding <=> q.embedding LIMIT 10)
           )::numeric / 10
    FROM qf_truth t JOIN qf_queries q ON q.id = t.query_id
    WHERE t.k = 10;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_i02_load_build_grow(p_rows_at_build int)
RETURNS numeric AS $$
DECLARE t0 timestamptz; ms numeric;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02_idx';
    TRUNCATE qf_i02;
    PERFORM set_config('temp_file_limit', '2GB', true);

    INSERT INTO qf_i02 SELECT id, cluster_id, embedding FROM qf_corpus
    ORDER BY id LIMIT p_rows_at_build;

    t0 := clock_timestamp();
    EXECUTE 'CREATE INDEX qf_i02_idx ON qf_i02 '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    -- ข้อมูลโตขึ้นทีหลัง โดยไม่มีใครสร้าง index ใหม่ — คือความผิดพลาดที่จำลอง
    INSERT INTO qf_i02 SELECT c.id, c.cluster_id, c.embedding FROM qf_corpus c
    WHERE NOT EXISTS (SELECT 1 FROM qf_i02 x WHERE x.id = c.id);

    ANALYZE qf_i02;
    RETURN ms;
END $$ LANGUAGE plpgsql;

-- เงื่อนไข D — ข้อมูลชุดแรกเอียง มาจาก 5 กลุ่มจาก 50 เท่านั้น
-- นี่คือรูปแบบที่เกิดจริง: ลูกค้ากลุ่มแรก · ภูมิภาคแรก · หมวดสินค้าแรก
CREATE OR REPLACE FUNCTION qf_i02_load_skewed_build_grow(p_rows int, p_clusters int)
RETURNS numeric AS $$
DECLARE t0 timestamptz; ms numeric;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02_idx';
    TRUNCATE qf_i02;
    PERFORM set_config('temp_file_limit', '2GB', true);

    INSERT INTO qf_i02
    SELECT id, cluster_id, embedding FROM qf_corpus
    WHERE cluster_id < p_clusters ORDER BY id LIMIT p_rows;

    t0 := clock_timestamp();
    EXECUTE 'CREATE INDEX qf_i02_idx ON qf_i02 '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;

    INSERT INTO qf_i02 SELECT c.id, c.cluster_id, c.embedding FROM qf_corpus c
    WHERE NOT EXISTS (SELECT 1 FROM qf_i02 x WHERE x.id = c.id);

    ANALYZE qf_i02;
    RETURN ms;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qf_i02_rebuild_full() RETURNS numeric AS $$
DECLARE t0 timestamptz;
BEGIN
    EXECUTE 'DROP INDEX IF EXISTS qf_i02_idx';
    PERFORM set_config('temp_file_limit', '2GB', true);
    t0 := clock_timestamp();
    EXECUTE 'CREATE INDEX qf_i02_idx ON qf_i02 '
            'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    RETURN extract(epoch FROM clock_timestamp() - t0) * 1000;
END $$ LANGUAGE plpgsql;

SET ivfflat.probes = 1;

-- ============================================================
-- 5 รอบ · แต่ละรอบทำครบทั้ง 3 เงื่อนไขบนข้อมูลชุดเดียวกัน
--
-- **NOTICE ของ pgvector จะโผล่ตรงนี้เฉพาะเงื่อนไข A** — เก็บไว้เป็นหลักฐาน
-- (I05 สอนแล้วว่า ground truth บางข้ออยู่ใน stderr ห้ามกลบ · กับดักข้อ 1)
-- ============================================================
\qecho ''
\qecho '=== รอบ 1 ==='
SELECT qf_i02_measure(1, 'A_build_at_50',    50,    qf_i02_load_build_grow(50));
SELECT qf_i02_measure(1, 'C_build_at_full',  100000, qf_i02_rebuild_full());
SELECT qf_i02_measure(1, 'B_build_at_1000',  1000,  qf_i02_load_build_grow(1000));
SELECT qf_i02_measure(1, 'D_skewed_5of50',   1000,  qf_i02_load_skewed_build_grow(1000, 5));

\qecho ''
\qecho '=== รอบ 2 ==='
SELECT qf_i02_measure(2, 'A_build_at_50',    50,    qf_i02_load_build_grow(50));
SELECT qf_i02_measure(2, 'C_build_at_full',  100000, qf_i02_rebuild_full());
SELECT qf_i02_measure(2, 'B_build_at_1000',  1000,  qf_i02_load_build_grow(1000));
SELECT qf_i02_measure(2, 'D_skewed_5of50',   1000,  qf_i02_load_skewed_build_grow(1000, 5));

\qecho ''
\qecho '=== รอบ 3 ==='
SELECT qf_i02_measure(3, 'A_build_at_50',    50,    qf_i02_load_build_grow(50));
SELECT qf_i02_measure(3, 'C_build_at_full',  100000, qf_i02_rebuild_full());
SELECT qf_i02_measure(3, 'B_build_at_1000',  1000,  qf_i02_load_build_grow(1000));
SELECT qf_i02_measure(3, 'D_skewed_5of50',   1000,  qf_i02_load_skewed_build_grow(1000, 5));

\qecho ''
\qecho '=== รอบ 4 ==='
SELECT qf_i02_measure(4, 'A_build_at_50',    50,    qf_i02_load_build_grow(50));
SELECT qf_i02_measure(4, 'C_build_at_full',  100000, qf_i02_rebuild_full());
SELECT qf_i02_measure(4, 'B_build_at_1000',  1000,  qf_i02_load_build_grow(1000));
SELECT qf_i02_measure(4, 'D_skewed_5of50',   1000,  qf_i02_load_skewed_build_grow(1000, 5));

\qecho ''
\qecho '=== รอบ 5 ==='
SELECT qf_i02_measure(5, 'A_build_at_50',    50,    qf_i02_load_build_grow(50));
SELECT qf_i02_measure(5, 'C_build_at_full',  100000, qf_i02_rebuild_full());
SELECT qf_i02_measure(5, 'B_build_at_1000',  1000,  qf_i02_load_build_grow(1000));
SELECT qf_i02_measure(5, 'D_skewed_5of50',   1000,  qf_i02_load_skewed_build_grow(1000, 5));

-- ============================================================
-- ผล
-- ============================================================
\qecho ''
\qecho '=== ข้อมูลปลายทางเหมือนกันทุกเงื่อนไขจริงไหม (ต้องเหมือน ไม่งั้นเทียบไม่ได้) ==='
SELECT count(DISTINCT rows_final) AS จำนวนแถวที่ต่างกัน,
       count(DISTINCT table_fp)   AS fingerprint_ที่ต่างกัน,
       min(rows_final)            AS แถว
FROM qf_i02_meta;

\qecho ''
\qecho '=== recall ต่อเงื่อนไข ข้าม 5 รอบ ==='
SELECT cond,
       min(rows_at_build)                         AS แถวตอน_build,
       bool_or(notice_expected)                   AS pgvector_เตือน,
       round(avg(m), 4)                           AS recall_เฉลี่ย,
       round(min(m), 4)                           AS ต่ำสุด,
       round(max(m), 4)                           AS สูงสุด,
       round(max(m) - min(m), 4)                  AS ช่วงแกว่ง
FROM (
    SELECT o.cond, o.round, avg(o.recall) AS m,
           bool_or(mt.notice_expected) AS notice_expected,
           min(o.rows_at_build) AS rows_at_build
    FROM qf_i02_obs o
    JOIN qf_i02_meta mt ON mt.round = o.round AND mt.cond = o.cond
    GROUP BY o.cond, o.round
) s GROUP BY cond ORDER BY cond;

\qecho ''
\qecho '=== เทียบเป็นคู่ในรอบเดียวกัน (ตัดผลของ build randomness ออก) ==='
\qecho '    บวก = เงื่อนไขนั้นดีกว่า C ในรอบเดียวกัน'
SELECT round AS รอบ,
       round(max(m) FILTER (WHERE cond = 'A_build_at_50')   - max(m) FILTER (WHERE cond = 'C_build_at_full'), 4) AS A_ลบ_C,
       round(max(m) FILTER (WHERE cond = 'B_build_at_1000') - max(m) FILTER (WHERE cond = 'C_build_at_full'), 4) AS B_ลบ_C,
       round(max(m) FILTER (WHERE cond = 'D_skewed_5of50')  - max(m) FILTER (WHERE cond = 'C_build_at_full'), 4) AS D_ลบ_C
FROM (SELECT cond, round, avg(recall) AS m FROM qf_i02_obs GROUP BY cond, round) s
GROUP BY round ORDER BY round;

\qecho ''
\qecho '=== buffers · เวลา build · ขนาด index ==='
SELECT cond,
       round(avg(buffers_avg), 0) AS buffers_เฉลี่ย,
       round(avg(build_ms), 1)    AS build_ms_เฉลี่ย,
       max(index_size)            AS ขนาด_index
FROM qf_i02_meta GROUP BY cond ORDER BY cond;

\qecho ''
\qecho '=== ราย query — เงื่อนไขไหนให้คำตอบต่างจาก C บ้าง (รอบ 1) ==='
SELECT a.cond,
       count(*) FILTER (WHERE a.recall IS DISTINCT FROM c.recall) AS query_ที่ต่างจาก_C,
       count(*) AS query_ทั้งหมด
FROM qf_i02_obs a
JOIN qf_i02_obs c ON c.round = a.round AND c.query_id = a.query_id
                 AND c.cond = 'C_build_at_full'
WHERE a.round = 1 AND a.cond <> 'C_build_at_full'
GROUP BY a.cond ORDER BY a.cond;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
\qecho ''
\qecho '=== assertion ==='
DO $$
DECLARE
    n_fp      int;
    n_rows    int;
    n_cond    int;
    a_mean    numeric; b_mean numeric; c_mean numeric;
    a_diff    int;     b_diff int;  d_diff int;  n_worse int;  d_mean numeric;
    rows_now  bigint;  fp_now text;  g record;
    n_notice  int;
BEGIN
    -- 1) ข้อมูลปลายทางต้องเหมือนกันทุกเงื่อนไข ไม่งั้นเทียบไม่ได้เลย
    SELECT count(DISTINCT table_fp), count(DISTINCT rows_final)
      INTO n_fp, n_rows FROM qf_i02_meta;
    IF n_fp <> 1 OR n_rows <> 1 THEN
        RAISE EXCEPTION 'ข้อมูลปลายทางไม่เหมือนกัน (fingerprint % แบบ · จำนวนแถว % แบบ) '
                        '— การเทียบไม่ยุติธรรม', n_fp, n_rows;
    END IF;
    RAISE NOTICE '[1/6] OK ข้อมูลปลายทางเหมือนกันทุกเงื่อนไข — fingerprint เดียว 100,000 แถว';

    -- 2) ต้องได้ครบ 3 เงื่อนไข x 5 รอบ
    SELECT count(*) INTO n_cond FROM (
        SELECT cond, round FROM qf_i02_obs GROUP BY cond, round) s;
    IF n_cond <> 20 THEN
        RAISE EXCEPTION 'ได้ % ชุด จากที่ต้องได้ 20 (4 เงื่อนไข x 5 รอบ)', n_cond;
    END IF;
    RAISE NOTICE '[2/6] OK ครบ 4 เงื่อนไข x 5 รอบ';

    -- 3) เงื่อนไข A ต้องเป็นกรณีที่ pgvector เตือน · B ต้องเงียบ
    SELECT count(*) INTO n_notice FROM qf_i02_meta
     WHERE cond = 'A_build_at_50' AND notice_expected;
    IF n_notice <> 5 THEN
        RAISE EXCEPTION 'เงื่อนไข A ควรเข้าเกณฑ์ NOTICE ทั้ง 5 รอบ แต่ได้ %', n_notice;
    END IF;
    SELECT count(*) INTO n_notice FROM qf_i02_meta
     WHERE cond = 'B_build_at_1000' AND notice_expected;
    IF n_notice <> 0 THEN
        RAISE EXCEPTION 'เงื่อนไข B ไม่ควรเข้าเกณฑ์ NOTICE เลย แต่ได้ % รอบ', n_notice;
    END IF;
    RAISE NOTICE '[3/6] OK A เข้าเกณฑ์เตือนครบ 5 รอบ · B ไม่เข้าเกณฑ์เลย (เงียบสนิท)';

    -- 4) index ที่ build ตอนข้อมูลน้อย ต้องให้คำตอบ **ต่าง** จาก build ครบ
    --    ไม่งั้นแปลว่า fault ไม่เกิด (ทิศทางไม่ assert — วัดแล้วรายงาน)
    SELECT count(*) INTO a_diff FROM qf_i02_obs a
      JOIN qf_i02_obs c ON c.round = a.round AND c.query_id = a.query_id
                       AND c.cond = 'C_build_at_full'
     WHERE a.cond = 'A_build_at_50' AND a.recall IS DISTINCT FROM c.recall;
    SELECT count(*) INTO b_diff FROM qf_i02_obs b
      JOIN qf_i02_obs c ON c.round = b.round AND c.query_id = b.query_id
                       AND c.cond = 'C_build_at_full'
     WHERE b.cond = 'B_build_at_1000' AND b.recall IS DISTINCT FROM c.recall;
    SELECT count(*) INTO d_diff FROM qf_i02_obs d
      JOIN qf_i02_obs c ON c.round = d.round AND c.query_id = d.query_id
                       AND c.cond = 'C_build_at_full'
     WHERE d.cond = 'D_skewed_5of50' AND d.recall IS DISTINCT FROM c.recall;
    IF a_diff = 0 AND b_diff = 0 AND d_diff = 0 THEN
        RAISE EXCEPTION 'ไม่มี query ไหนได้คำตอบต่างเลย — ตอน build ไม่มีผลอะไร fault ไม่เกิด';
    END IF;
    RAISE NOTICE '[4/6] OK คำตอบต่างจริง — A ต่างจาก C % · B ต่างจาก C % · D ต่างจาก C % (จาก 1,000 คู่)',
                 a_diff, b_diff, d_diff;

    -- 5) **นี่คือ fault ตัวจริง** — ตัวอย่างตอน build ที่ไม่เป็นตัวแทน ต้องทำ recall พัง
    --    ต้องแย่กว่า C ทุกรอบ ไม่ใช่แค่เฉลี่ยแย่กว่า (I04 สอนว่าค่าเฉลี่ยหลอกได้)
    SELECT count(*) INTO n_worse FROM (
        SELECT d.round FROM
            (SELECT round, avg(recall) m FROM qf_i02_obs WHERE cond='D_skewed_5of50' GROUP BY round) d
        JOIN (SELECT round, avg(recall) m FROM qf_i02_obs WHERE cond='C_build_at_full' GROUP BY round) c
          ON c.round = d.round
        WHERE d.m < c.m) s;
    IF n_worse <> 5 THEN
        RAISE EXCEPTION 'เงื่อนไข D ควรแย่กว่า C ทุกรอบ แต่แย่กว่าแค่ % จาก 5 รอบ '
                        '— fault ไม่เกิดตามที่ตั้งใจ', n_worse;
    END IF;
    RAISE NOTICE '[5/6] OK D (ตัวอย่างเอียง 5 จาก 50 กลุ่ม) แย่กว่า C ครบทั้ง 5 รอบ';

    -- 5) qf_corpus ต้องไม่ถูกแตะ
    SELECT count(*), md5(string_agg(embedding::text, '|' ORDER BY id))
      INTO rows_now, fp_now
      FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s;
    SELECT * INTO g FROM qf_i02_guard;
    IF rows_now <> g.rows_before OR fp_now <> g.fp_before THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยน! แถว %->% fingerprint %->%',
                        g.rows_before, rows_now, g.fp_before, fp_now;
    END IF;
    RAISE NOTICE '[6/6] OK qf_corpus ไม่ถูกแตะ';

    -- รายงานทิศทาง (ข้อมูล ไม่ใช่ assertion — ห้ามตั้งเกณฑ์ให้ผลออกมาเข้าข้างตัวเอง)
    SELECT avg(m) INTO a_mean FROM (SELECT avg(recall) AS m FROM qf_i02_obs
        WHERE cond='A_build_at_50' GROUP BY round) s;
    SELECT avg(m) INTO b_mean FROM (SELECT avg(recall) AS m FROM qf_i02_obs
        WHERE cond='B_build_at_1000' GROUP BY round) s;
    SELECT avg(m) INTO c_mean FROM (SELECT avg(recall) AS m FROM qf_i02_obs
        WHERE cond='C_build_at_full' GROUP BY round) s;
    RAISE NOTICE '';
    SELECT avg(m) INTO d_mean FROM (SELECT avg(recall) AS m FROM qf_i02_obs
        WHERE cond='D_skewed_5of50' GROUP BY round) s;
    RAISE NOTICE 'recall เฉลี่ยข้าม 5 รอบ: A(50)=%  B(1000)=%  C(ครบ)=%  D(เอียง)=%',
                 round(a_mean,4), round(b_mean,4), round(c_mean,4), round(d_mean,4);
    RAISE NOTICE 'pgvector เตือนเฉพาะ A ซึ่งได้ recall % · และเงียบสนิทกับ D ซึ่งได้ %',
                 round(a_mean,4), round(d_mean,4);
    IF a_mean < c_mean AND b_mean < c_mean THEN
        RAISE NOTICE '-> ตรงกับที่ HINT ของ pgvector บอก: build ตอนข้อมูลน้อยแล้ว recall แย่ลง';
    ELSIF a_mean > c_mean AND b_mean > c_mean THEN
        RAISE NOTICE '-> ⭐ กลับด้านจาก HINT ของ pgvector ที่เขียนว่า This will cause low recall';
    ELSE
        RAISE NOTICE '-> ผลไม่ไปทางเดียวกันทั้งสองเงื่อนไข ต้องดูตารางเทียบเป็นคู่';
    END IF;
END $$;

\qecho ''
\qecho '=== เก็บกวาด: ทิ้ง index กับตารางทดสอบ เก็บตารางผลไว้ให้ตัวตรวจอ่าน ==='
DROP INDEX IF EXISTS qf_i02_idx;
DROP TABLE IF EXISTS qf_i02_guard;
DROP FUNCTION IF EXISTS qf_i02_measure(int, text, int, numeric);
DROP FUNCTION IF EXISTS qf_i02_load_build_grow(int);
DROP FUNCTION IF EXISTS qf_i02_load_skewed_build_grow(int, int);
DROP FUNCTION IF EXISTS qf_i02_rebuild_full();
RESET ivfflat.probes;

SELECT count(*) AS vector_index_ค้าง
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw', 'ivfflat');
