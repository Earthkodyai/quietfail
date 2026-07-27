-- ============================================================
-- V07 — vector ที่เป็น NULL หรือ zero ไม่ถูก index → แถวหายถาวร
--
-- รัน:  psql ... -f /sql/v07_null_zero_vectors.sql
--
-- อาการ  : บางแถวไม่เคยโผล่ในผลค้นหาเลย ตลอดกาล · ไม่มี error
-- ต้นเหตุ: NULL vector ไม่ถูก index · zero vector ไม่ถูก index เมื่อใช้ cosine
--          เพราะ cosine distance ของ zero vector คือ NaN
--
-- ⭐ ต่างจากทุกข้อก่อนหน้าตรงที่เป็น **ปัญหาคุณภาพข้อมูล ไม่ใช่การตั้งค่า**
--    ทีมที่จูน ef_search / probes / m เก่งแค่ไหนก็ไม่มีทางเจอ
--    เพราะไม่มีพารามิเตอร์ตัวไหนเกี่ยวข้องเลย
--
-- ⚠️ ใช้ตารางแยก qf_v07 ห้ามแตะ qf_corpus ที่ล็อกไว้
--    (fingerprint + จำนวนแถวเป็นฐานของเฉลยทั้งโปรเจค)
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';                       -- กฎเหล็กข้อ 9
SET max_parallel_workers_per_gather = 0;

\set good_rows 500
\set n_bad 5

-- ============================================================
-- เตรียมตารางทดลอง — คัดลอกจาก qf_corpus แบบอ่านอย่างเดียว
-- ============================================================
DROP TABLE IF EXISTS qf_v07;
CREATE TABLE qf_v07 (
    id        bigint PRIMARY KEY,
    kind      text NOT NULL,          -- good / null_vec / zero_vec
    embedding vector(384)
);

INSERT INTO qf_v07 (id, kind, embedding)
SELECT id, 'good', embedding FROM qf_corpus ORDER BY id LIMIT :good_rows;

-- แถวที่ embedding เป็น NULL — เกิดจริงเมื่อ pipeline ยังไม่ได้ embed
INSERT INTO qf_v07 (id, kind, embedding)
SELECT 900000000 + g, 'null_vec', NULL FROM generate_series(1, :n_bad) g;

-- แถวที่ embedding เป็นศูนย์ทั้งหมด
-- เกิดจริงเมื่อ embedding ล้มเหลวแล้วโค้ดใส่ศูนย์แทนการโยน error
INSERT INTO qf_v07 (id, kind, embedding)
SELECT 950000000 + g, 'zero_vec', array_fill(0::real, ARRAY[384])::vector
FROM generate_series(1, :n_bad) g;

ANALYZE qf_v07;

DROP TABLE IF EXISTS qf_v07_results;
CREATE TABLE qf_v07_results (
    phase        text,
    path         text,      -- exact / index
    rows_asked   int,
    rows_got     int,
    good_found   int,
    null_found   int,
    zero_found   int
);

\qecho
\qecho '=== ตารางทดลอง: 500 แถวปกติ + 5 NULL + 5 zero = 510 แถว ==='
SELECT kind, count(*) AS rows FROM qf_v07 GROUP BY kind ORDER BY kind;

\qecho
\qecho '--- ตรวจว่าข้อมูลเสียจริง: cosine distance ของแต่ละชนิด ---'
SELECT kind,
       count(*) AS rows,
       count(*) FILTER (WHERE embedding IS NULL)          AS is_null,
       count(*) FILTER (WHERE vector_norm(embedding) = 0) AS norm_zero
FROM qf_v07 GROUP BY kind ORDER BY kind;

-- ============================================================
-- ตัววัด — ยิง query เดียว ขอเกินจำนวนแถวทั้งตาราง
-- แล้วนับว่าแต่ละชนิดโผล่มากี่แถว
--
-- ตั้ง ef_search สูงเพื่อ **แยก V07 ออกจาก Q06** ให้ชัด
-- ถ้าปล่อยไว้ที่ 40 จะแยกไม่ออกว่าแถวหายเพราะไม่ถูก index (V07)
-- หรือเพราะ candidate list เล็กเกิน (Q06)
-- ============================================================
CREATE OR REPLACE FUNCTION qf_v07_probe(p_phase text, p_use_index boolean, p_k int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    qvec vector; g int; n int; z int; tot int;
BEGIN
    SELECT embedding INTO qvec FROM qf_queries WHERE id = 1;

    IF p_use_index THEN
        PERFORM set_config('enable_indexscan',     'on',  true);
        PERFORM set_config('enable_seqscan',       'off', true);
        PERFORM set_config('hnsw.ef_search',       '1000', true);
    ELSE
        -- วิธีบังคับ exact search ที่เอกสารแนะนำเอง (ดู EVIDENCE.md)
        PERFORM set_config('enable_indexscan',     'off', true);
        PERFORM set_config('enable_indexonlyscan', 'off', true);
        PERFORM set_config('enable_seqscan',       'on',  true);
    END IF;

    WITH hit AS (
        SELECT v.id, v.kind
        FROM qf_v07 v
        ORDER BY v.embedding <=> qvec
        LIMIT p_k
    )
    SELECT count(*),
           count(*) FILTER (WHERE kind = 'good'),
           count(*) FILTER (WHERE kind = 'null_vec'),
           count(*) FILTER (WHERE kind = 'zero_vec')
      INTO tot, g, n, z
    FROM hit;

    INSERT INTO qf_v07_results VALUES (p_phase, CASE WHEN p_use_index THEN 'index' ELSE 'exact' END,
                                       p_k, tot, g, n, z);
END $$;

-- ============================================================
-- A) ยังไม่มี index — exact search เห็นทุกแถวไหม
-- ============================================================
\qecho
\qecho '=== A) ไม่มี index (exact search) · ขอ 510 แถว ==='
SELECT qf_v07_probe('A no index', false, 510);

-- ============================================================
-- B) มี HNSW cosine index  ← นี่คือ fault
-- ============================================================
\qecho
\qecho '=== B) มี HNSW (vector_cosine_ops) · ขอ 510 แถว ==='
SET temp_file_limit = '2GB';
CREATE INDEX qf_v07_idx ON qf_v07 USING hnsw (embedding vector_cosine_ops);
RESET temp_file_limit;

SELECT qf_v07_probe('B with index', true, 510);

-- เทียบ: exact search บนตารางเดียวกันที่มี index อยู่ (ปิด index scan)
SELECT qf_v07_probe('B exact fallback', false, 510);

DROP INDEX qf_v07_idx;

\qecho
\qecho '=== ผล: แถวชนิดไหนโผล่บ้าง ==='
SELECT phase, path, rows_asked AS "ขอ", rows_got AS "ได้",
       good_found AS "ปกติ", null_found AS "NULL", zero_found AS "zero"
FROM qf_v07_results ORDER BY phase, path;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    a qf_v07_results%ROWTYPE;
    b qf_v07_results%ROWTYPE;
    n_bad_total int;
BEGIN
    SELECT * INTO a FROM qf_v07_results WHERE phase = 'A no index';
    SELECT * INTO b FROM qf_v07_results WHERE phase = 'B with index';

    SELECT count(*) INTO n_bad_total FROM qf_v07 WHERE kind <> 'good';

    -- ข้อ 1: exact search ต้องเห็นครบทุกแถว รวมแถวเสีย
    IF a.rows_got <> 510 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: exact search ได้ % แถว (ต้อง 510)', a.rows_got;
    END IF;
    RAISE NOTICE '[1/4] OK exact search เห็นครบ 510 แถว (ปกติ % · NULL % · zero %)',
        a.good_found, a.null_found, a.zero_found;

    -- ข้อ 2: index ต้อง **ไม่คืน** แถว NULL และ zero เลย
    IF b.null_found > 0 OR b.zero_found > 0 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: index ยังคืนแถวเสีย (NULL % · zero %) — fault ไม่เกิด',
            b.null_found, b.zero_found;
    END IF;
    RAISE NOTICE '[2/4] OK index ไม่คืนแถว NULL และ zero เลยสักแถว';

    -- ข้อ 3: index ต้องคืนแถวปกติครบ — พิสูจน์ว่าหายเฉพาะแถวเสีย ไม่ใช่หายทั่วไป
    IF b.good_found < a.good_found THEN
        RAISE EXCEPTION
            'ข้อ 3 ตก: index คืนแถวปกติแค่ % จาก % — หายมากกว่าที่ควร แยก V07 จาก Q06 ไม่ได้',
            b.good_found, a.good_found;
    END IF;
    RAISE NOTICE '[3/4] OK index คืนแถวปกติครบ % แถว → หายเฉพาะแถวเสียจริง', b.good_found;

    -- ข้อ 4: จำนวนที่หายต้องเท่ากับจำนวนแถวเสียพอดี
    IF (a.rows_got - b.rows_got) <> n_bad_total THEN
        RAISE EXCEPTION
            'ข้อ 4 ตก: หายไป % แถว แต่มีแถวเสีย % แถว — ไม่ตรงกัน',
            a.rows_got - b.rows_got, n_bad_total;
    END IF;
    RAISE NOTICE '[4/4] OK หายไป % แถว = จำนวนแถวเสียพอดี (NULL % + zero %)',
        a.rows_got - b.rows_got,
        (SELECT count(*) FROM qf_v07 WHERE kind = 'null_vec'),
        (SELECT count(*) FROM qf_v07 WHERE kind = 'zero_vec');

    RAISE NOTICE 'assertion ผ่านครบ 4 ข้อ';
END $$;

\qecho
\qecho '=== แถวเสียหายไปจากผลค้นหาอย่างถาวร โดยไม่มี error ==='
\qecho '=== zero vector: cosine distance = NaN · NULL vector: distance = NULL ==='
\qecho '=== ทั้งคู่ไม่เข้า index → ไม่มีวันโผล่ในผลที่ใช้ index ==='
\qecho '=== และไม่มีพารามิเตอร์ตัวไหนแก้ได้ เพราะเป็นปัญหาคุณภาพข้อมูล ==='
