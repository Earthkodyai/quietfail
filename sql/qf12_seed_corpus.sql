-- =============================================================
-- QuietFail — ข้อมูลหลักที่จะถูกค้น  (ไฟล์ที่ 3 จาก 4)
--
-- รัน:  psql ... -v rows=100000 -f /sql/qf12_seed_corpus.sql
--
-- ขนาดที่ PROJECT.md ข้อ 7 กำหนดไว้: 100k / 500k / 2M / 5M
-- เริ่มที่ 100k เสมอ ขนาดใหญ่ค่อยตามมา
--
-- เนื้อที่โดยประมาณ: 384 มิติ × 4 ไบต์ ≈ 1.5 kB ต่อแถว (ยังไม่รวม index)
--   100k ≈ 150 MB · 2M ≈ 3 GB   ← ดูพื้นที่ว่างก่อนรันขนาดใหญ่
-- =============================================================

\set ON_ERROR_STOP on

\if :{?rows}
\else
\set rows 100000
\endif

\set dim 384
\set clusters 50
-- ต้องเท่ากับ noise ใน qf11 เสมอ — query กับ corpus ต้องมาจากการกระจายตัวเดียวกัน
-- ที่มาของค่า 0.04 และตารางที่วัดเทียบทฤษฎี อยู่ใน qf11_query_set.sql (ดู E12)
\set spread 0.04

\timing on

-- =============================================================
-- ทำไมต้องปิด parallel ตรงนี้
--
-- corpus ใช้ setseed() + random() เพราะวิธี hash ล้วนแบบที่ qf11 ใช้
-- ช้าเกินไปที่ระดับล้านแถว
--
-- แต่ random() ให้ลำดับเดิมเฉพาะเมื่อลำดับการเรียกเหมือนเดิม
-- ถ้า planner แตกงานเป็นหลาย worker ลำดับเปลี่ยน → ได้ข้อมูลคนละชุด
-- **โดยไม่มี error ใดๆ**
--
-- นี่คือข้อแลกเปลี่ยนที่รู้ตัว: corpus ทำซ้ำได้เมื่อ PostgreSQL เวอร์ชันเดิม
-- และปิด parallel เท่านั้น ต่างจากชุด query ใน qf11 ที่ทำซ้ำได้ทุกกรณี
-- ตัวจับว่าเพี้ยนคือ corpus_fingerprint ตอนท้าย
-- =============================================================
SET max_parallel_workers_per_gather = 0;
SELECT setseed(0.42);

TRUNCATE qf_truth, qf_corpus;

-- =============================================================
-- ทำไมต้องแบ่งเป็นก้อน
--
-- ทำทีเดียวทั้งตารางจะได้ cross join ขนาด rows × 384 แถว
-- แล้ว sort ของ array_agg(... ORDER BY d) ล้น temp_file_limit (64 MB
-- ในโปรไฟล์ fragile) → ERROR กลางคัน
--
-- เลือกแบ่งก้อน ไม่ใช่ปลดล็อก temp_file_limit เพราะ
--   1. โปรไฟล์ fragile ต้องเปราะไว้ตามเดิม มันคือกลุ่มทดลอง
--   2. ที่ 2M / 5M แถวยังไงก็ต้องแบ่งอยู่ดี ปลดล็อกได้แค่เลื่อนปัญหา
--
-- ⚠️ chunk มีผลต่อลำดับการเรียก random() → เปลี่ยน chunk = ได้ corpus คนละชุด
--    ค่านี้จึงถูกล็อกเหมือน seed ห้ามแก้หลังเริ่มเก็บผล
-- =============================================================
\set chunk 2000

SELECT set_config('qf.rows',   :'rows',   false);
SELECT set_config('qf.chunk',  :'chunk',  false);
SELECT set_config('qf.dim',    :'dim',    false);
SELECT set_config('qf.spread', :'spread', false);
SELECT set_config('qf.clusters', :'clusters', false);

DO $$
DECLARE
    v_rows   bigint := current_setting('qf.rows')::bigint;
    v_chunk  bigint := current_setting('qf.chunk')::bigint;
    v_dim    int    := current_setting('qf.dim')::int;
    v_spread real   := current_setting('qf.spread')::real;
    v_clu    int    := current_setting('qf.clusters')::int;
    lo       bigint := 1;
BEGIN
    WHILE lo <= v_rows LOOP
        -- ⚠️ noise ต้องคำนวณ "ต่อหนึ่งคู่ (แถว, มิติ)" ตรงนี้เท่านั้น
        --
        -- ห้ามย้ายไปเป็น subquery ที่ไม่อ้างถึง g.id เด็ดขาด
        -- เพราะ subquery ที่ไม่ correlated จะถูกยกไปคำนวณเป็น InitPlan
        -- **ครั้งเดียว** แล้วใช้ค่าเดิมซ้ำทุกแถว
        -- → ทุกจุดในกลุ่มเดียวกันกลายเป็นจุดเดียวกันเป๊ะ
        -- โดยจำนวนแถว มิติ และจำนวนกลุ่มยังถูกต้องหมด (ดู E11)
        INSERT INTO qf_corpus (id, cluster_id, embedding)
        SELECT
            g.id,
            g.cluster_id,
            l2_normalize(
                array_agg(
                    (
                        (cent.embedding::real[])[d]
                        + v_spread * ( sqrt(-2.0 * ln(greatest(random(), 1e-12)))
                                       * cos(2.0 * pi() * random()) )
                    )::real
                    ORDER BY d
                )::vector
            )
        FROM (
            SELECT i AS id, 1 + (i % v_clu) AS cluster_id
            FROM generate_series(lo, least(lo + v_chunk - 1, v_rows)) AS i
        ) AS g
        JOIN qf_centroids cent ON cent.id = g.cluster_id,
             generate_series(1, v_dim) AS d
        GROUP BY g.id, g.cluster_id;

        lo := lo + v_chunk;

        IF (lo - 1) % 20000 = 0 THEN
            RAISE NOTICE 'ใส่แล้ว % / % แถว', lo - 1, v_rows;
        END IF;
    END LOOP;
END $$;

ANALYZE qf_corpus;

-- =============================================================
-- assertion — กฎเหล็กข้อ 3
-- =============================================================
-- psql ไม่แทนค่า :'var' ข้างใน dollar-quoted block (บทเรียนเดียวกับ qf10)
-- จึงต้องส่งค่าผ่าน GUC ชั่วคราวแทน
SELECT set_config('qf.expected_rows', :'rows', false);

DO $$
DECLARE
    n          bigint;
    expected   bigint := current_setting('qf.expected_rows')::bigint;
    bad_dim    bigint;
    zero_vecs  bigint;
    n_groups   int;
    min_grp    bigint;
    n_distinct bigint;
BEGIN
    SELECT count(*) INTO n FROM qf_corpus;
    SELECT count(*) INTO bad_dim   FROM qf_corpus WHERE vector_dims(embedding) <> 384;
    -- vector_norm() ไม่ใช่ l2_norm() — ดู E10
    SELECT count(*) INTO zero_vecs FROM qf_corpus WHERE vector_norm(embedding) = 0;
    SELECT count(DISTINCT cluster_id) INTO n_groups FROM qf_corpus;
    SELECT min(c) INTO min_grp FROM (
        SELECT count(*) AS c FROM qf_corpus GROUP BY cluster_id
    ) s;

    IF n <> expected THEN
        RAISE EXCEPTION 'ต้องได้ % แถว แต่ได้ %', expected, n;
    END IF;
    IF bad_dim > 0 THEN
        RAISE EXCEPTION 'มี % แถวที่มิติไม่ใช่ 384', bad_dim;
    END IF;
    IF zero_vecs > 0 THEN
        -- V07: zero vector ไม่ถูก index เมื่อใช้ cosine → แถวหายเงียบ
        -- ต้องไม่มีในชุดพื้นฐาน จะฉีดตอนทดสอบ V07 ต่างหาก
        RAISE EXCEPTION 'มี zero vector % แถวในชุดพื้นฐาน — ดู V07', zero_vecs;
    END IF;
    IF n_groups <> 50 THEN
        RAISE EXCEPTION 'ต้องครบ 50 กลุ่ม แต่ได้ %', n_groups;
    END IF;

    -- =========================================================
    -- assertion ที่สำคัญที่สุดในไฟล์นี้ — เพิ่มหลังโดนบั๊กจริง (E11)
    --
    -- ถ้า noise ถูกยกไปคำนวณครั้งเดียว ทุกจุดในกลุ่มเดียวกันจะเหมือนกันเป๊ะ
    -- แล้ว assertion ทุกข้อข้างบน (จำนวนแถว มิติ zero vector จำนวนกลุ่ม)
    -- **ผ่านหมด** โดยข้อมูลใช้วัด recall ไม่ได้เลย
    --
    -- ดูแค่ตัวอย่าง 2,000 แถวแรกก็พอ เพราะอาการนี้เกิดกับทั้งตาราง
    -- =========================================================
    SELECT count(DISTINCT md5(embedding::text)) INTO n_distinct
    FROM (SELECT embedding FROM qf_corpus ORDER BY id LIMIT 2000) s;

    IF n_distinct < least(2000, n) THEN
        RAISE EXCEPTION
            'vector ซ้ำกัน: ตัวอย่าง % แถว มีค่าไม่ซ้ำแค่ % ตัว '
            '→ noise ไม่ได้ถูกสุ่มต่อแถว ข้อมูลชุดนี้ใช้วัด recall ไม่ได้ (ดู E11)',
            least(2000, n), n_distinct;
    END IF;

    RAISE NOTICE
        'assertion ผ่าน: % แถว · 50 กลุ่ม · กลุ่มเล็กสุด % แถว · ตัวอย่าง 2000 แถวไม่ซ้ำกัน %',
        n, min_grp, n_distinct;
END $$;

-- fingerprint: จับได้ว่า corpus เพี้ยนไปจากรอบก่อนหรือไม่
-- ใช้ 5,000 แถวแรกก็พอ เพราะถ้าลำดับ random เปลี่ยน มันเปลี่ยนตั้งแต่ต้น
INSERT INTO qf_manifest (item, value)
SELECT 'corpus_rows', count(*)::text FROM qf_corpus
ON CONFLICT (item) DO UPDATE SET value = EXCLUDED.value, recorded_at = now();

INSERT INTO qf_manifest (item, value)
SELECT 'corpus_fingerprint_first5k',
       md5(string_agg(embedding::text, '|' ORDER BY id))
FROM (SELECT id, embedding FROM qf_corpus ORDER BY id LIMIT 5000) s
ON CONFLICT (item) DO UPDATE SET value = EXCLUDED.value, recorded_at = now();

SELECT item, value FROM qf_manifest ORDER BY item;

\echo ''
\echo '>>> ต่อด้วย qf13_recall.sql เพื่อสร้างเฉลย'
