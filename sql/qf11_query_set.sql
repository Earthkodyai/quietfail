-- =============================================================
-- QuietFail — จุดศูนย์กลาง + ชุด query 200 ข้อ  (ไฟล์ที่ 2 จาก 4)
--
-- รัน:  psql ... -f /sql/qf11_query_set.sql
--
-- ⚠️ ไฟล์นี้คือของที่ D09 สั่งให้ commit **ก่อน**มีตัวเลขผลลัพธ์ใดๆ
--    ห้ามแก้ salt / จำนวน / สูตร หลังจากเริ่มเก็บผลแล้ว
--    ถ้าแก้ = เลือกโจทย์ที่เข้าข้างผลตัวเอง ซึ่งคือสิ่งที่ D09 มีไว้ป้องกัน
--
--    ตัวยืนยันว่าไม่ได้แก้คือ fingerprint ที่พิมพ์ตอนท้าย
-- =============================================================

\set ON_ERROR_STOP on

\set dim 384
\set clusters 50
\set queries 200

-- salt ล็อกแล้ว — เปลี่ยนเมื่อไหร่ได้ชุด query คนละชุดทันที
\set salt 'quietfail-v1'

\timing on

TRUNCATE qf_truth, qf_queries, qf_corpus, qf_centroids RESTART IDENTITY;

-- =============================================================
-- จุดศูนย์กลาง 50 จุด
--
-- ทำไมต้องมีกลุ่ม: PROJECT.md ข้อ 7 ห้ามใช้ vector สุ่มสม่ำเสมอ
-- เพราะในมิติสูงจุดจะห่างกันเกือบเท่ากันหมด ทำให้ recall ดูแย่ผิดปกติ
-- แล้วสรุปผิดว่า index ห่วย ทั้งที่ข้อมูลต่างหากที่ไม่มีโครงสร้าง
-- =============================================================
INSERT INTO qf_centroids (id, embedding)
SELECT
    c,
    l2_normalize(
        array_agg(qf_gauss(:'salt' || ':c:' || c || ':' || d)::real ORDER BY d)::vector
    )
FROM generate_series(1, :clusters) AS c,
     generate_series(1, :dim)      AS d
GROUP BY c;

-- =============================================================
-- ชุด query 200 ข้อ
--
-- query แต่ละข้อ = จุดศูนย์กลางกลุ่มหนึ่ง + สัญญาณรบกวน
-- ต้องมาจากการกระจายตัวเดียวกับ corpus ไม่งั้นวัด recall แล้วไม่มีความหมาย
--
-- ค่า noise มาจากการวัด ไม่ใช่การเดา (กฎเหล็กข้อ 2)
--
-- ที่ D มิติ ระยะ cosine ภายในกลุ่มเดียวกันเป็นไปตาม
--     dist ≈ 1 − 1/(1 + s²·D)          (D = 384)
--
-- วัดจริง 2026-07-26 เทียบกับทฤษฎี — ตรงกันทั้งช่วง:
--     s     ทฤษฎี   วัดได้
--     0.02  0.133   0.131
--     0.04  0.381   0.377     <-- เลือกค่านี้
--     0.08  0.711   0.702
--     0.35  0.979   0.973     <-- ค่าแรกที่ใช้ ผิด ดู E12
--
-- ระยะข้ามกลุ่ม ≈ 1.00 (unit vector ในมิติสูงเกือบตั้งฉากกันหมด)
-- s = 0.04 จึงได้ในกลุ่ม 0.38 vs ข้ามกลุ่ม 1.00 = ห่างกัน 2.6 เท่า
-- มีโครงสร้างจริงให้ ANN ทำผิดพลาดได้ แต่ไม่ง่ายจนไร้ความหมาย
-- =============================================================
\set noise 0.04

INSERT INTO qf_queries (id, cluster_id, embedding)
SELECT
    q.id,
    q.cluster_id,
    l2_normalize(
        array_agg(
            (
                (cent.embedding::real[])[d]
                + :noise * qf_gauss(:'salt' || ':q:' || q.id || ':' || d)
            )::real
            ORDER BY d
        )::vector
    )
FROM (
    SELECT
        i AS id,
        -- กระจาย query ให้ทั่วทุกกลุ่มแบบ deterministic
        1 + (floor(qf_u01(:'salt' || ':qc:' || i) * :clusters))::int AS cluster_id
    FROM generate_series(1, :queries) AS i
) AS q
JOIN qf_centroids cent ON cent.id = q.cluster_id,
     generate_series(1, :dim) AS d
GROUP BY q.id, q.cluster_id;

-- =============================================================
-- assertion — กฎเหล็กข้อ 3
-- ถ้าไม่ได้ตามที่ตั้งใจ ต้อง error ห้ามปล่อยผ่านแล้วเอาไปวัดต่อ
-- =============================================================
DO $$
DECLARE
    n_cent    int;
    n_qry     int;
    n_groups  int;
    bad_dim   int;
    zero_vecs int;
BEGIN
    SELECT count(*) INTO n_cent FROM qf_centroids;
    SELECT count(*) INTO n_qry  FROM qf_queries;
    SELECT count(DISTINCT cluster_id) INTO n_groups FROM qf_queries;
    SELECT count(*) INTO bad_dim FROM qf_queries WHERE vector_dims(embedding) <> 384;
    -- ใช้ vector_norm() ไม่ใช่ l2_norm()
    -- pgvector 0.8.5 มี l2_norm เฉพาะ halfvec / sparsevec ไม่มีเวอร์ชันที่รับ vector
    -- เรียก l2_norm(vector) จะได้ error ว่า "is not unique" ซึ่งชี้ผิดทาง (ดู E10)
    SELECT count(*) INTO zero_vecs FROM qf_queries WHERE vector_norm(embedding) = 0;

    IF n_cent <> 50 THEN
        RAISE EXCEPTION 'centroid ต้องมี 50 จุด แต่ได้ %', n_cent;
    END IF;
    IF n_qry <> 200 THEN
        RAISE EXCEPTION 'query ต้องมี 200 ข้อ (D09) แต่ได้ %', n_qry;
    END IF;
    IF bad_dim > 0 THEN
        RAISE EXCEPTION 'มี query % ข้อที่มิติไม่ใช่ 384', bad_dim;
    END IF;
    IF zero_vecs > 0 THEN
        -- zero vector ไม่ถูก index เมื่อใช้ cosine (V07)
        -- ถ้าหลุดเข้ามาในชุด query เอง จะวัด recall เพี้ยนโดยไม่มีอะไรเตือน
        RAISE EXCEPTION 'มี query % ข้อที่เป็น zero vector — ดู V07', zero_vecs;
    END IF;
    IF n_groups < 30 THEN
        RAISE EXCEPTION
            'query กระจุกอยู่แค่ % กลุ่มจาก 50 — ชุดนี้ใช้วัดไม่ได้', n_groups;
    END IF;

    RAISE NOTICE 'assertion ผ่าน: centroid % · query % · ครอบคลุม % กลุ่ม',
        n_cent, n_qry, n_groups;
END $$;

-- =============================================================
-- fingerprint — หลักฐานว่าชุด query ไม่ถูกแก้ทีหลัง
-- เอาค่านี้ไปเทียบทุกครั้งก่อนรายงานผล ถ้าไม่ตรง = ชุดโจทย์เปลี่ยนไปแล้ว
-- =============================================================
INSERT INTO qf_manifest (item, value)
SELECT 'query_set_salt', :'salt'
ON CONFLICT (item) DO UPDATE SET value = EXCLUDED.value, recorded_at = now();

INSERT INTO qf_manifest (item, value)
SELECT 'query_set_fingerprint',
       md5(string_agg(embedding::text, '|' ORDER BY id))
FROM qf_queries
ON CONFLICT (item) DO UPDATE SET value = EXCLUDED.value, recorded_at = now();

SELECT item, value FROM qf_manifest ORDER BY item;

\echo ''
\echo '>>> จด query_set_fingerprint ลง PROJECT.md ข้อ 7 แล้วห้ามแก้ไฟล์นี้อีก'
\echo '>>> ต่อด้วย qf12_seed_corpus.sql'
