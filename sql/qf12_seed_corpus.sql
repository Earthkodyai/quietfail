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
\set spread 0.35

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

INSERT INTO qf_corpus (id, cluster_id, embedding)
SELECT
    g.id,
    g.cluster_id,
    l2_normalize(
        array_agg(
            ((cent.embedding::real[])[d] + :spread * g.noise[d])::real ORDER BY d
        )::vector
    )
FROM (
    SELECT
        i AS id,
        1 + (i % :clusters) AS cluster_id,
        (SELECT array_agg(
                    sqrt(-2.0 * ln(greatest(random(), 1e-12)))
                        * cos(2.0 * pi() * random())
                )
         FROM generate_series(1, :dim)) AS noise
    FROM generate_series(1, :rows) AS i
) AS g
JOIN qf_centroids cent ON cent.id = g.cluster_id,
     generate_series(1, :dim) AS d
GROUP BY g.id, g.cluster_id;

ANALYZE qf_corpus;

-- =============================================================
-- assertion — กฎเหล็กข้อ 3
-- =============================================================
DO $$
DECLARE
    n         bigint;
    expected  bigint := :rows;
    bad_dim   bigint;
    zero_vecs bigint;
    n_groups  int;
    min_grp   bigint;
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

    RAISE NOTICE 'assertion ผ่าน: % แถว · 50 กลุ่ม · กลุ่มเล็กสุด % แถว',
        n, min_grp;
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
