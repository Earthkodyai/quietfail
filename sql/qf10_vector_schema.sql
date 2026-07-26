-- =============================================================
-- QuietFail — โครงสร้างสำหรับวัด recall  (ไฟล์ที่ 1 จาก 4)
--
-- รัน:  psql ... -f /sql/qf10_vector_schema.sql
--
-- ไฟล์นี้ไม่สร้าง index ใดๆ และไม่ตั้งค่า ef_search / probes / lists / m
-- เพราะกฎเหล็กข้อ 2: ค่าพวกนั้นต้องมาจากการวัดเท่านั้น
-- การสร้าง index จะไปอยู่เฟส 2 หลังวัดแล้ว
-- =============================================================

\set ON_ERROR_STOP on

-- กฎเหล็กข้อ 9: GUC ของ pgvector ไม่โผล่ใน pg_settings จนกว่าจะ LOAD
LOAD 'vector';

-- มิติของ vector — ล็อกไว้ที่เดียวตรงนี้ ห้ามแก้หลังเก็บผลแล้ว
-- 384 เพื่อให้ตรงกับ merchant_embeddings ที่มีอยู่ก่อนแล้วใน init/02_schema.sql
\set dim 384

-- จำนวนกลุ่ม — PROJECT.md ข้อ 7 กำหนด 50
\set clusters 50

-- จำนวน query — D09 กำหนด 200 และห้ามเปลี่ยนหลังเห็นผล
\set queries 200

-- =============================================================
-- ตัวสุ่มแบบ deterministic
--
-- ทำไมไม่ใช้ setseed() + random() กับส่วนที่ต้องทำซ้ำได้เป๊ะ:
--   random() ให้ลำดับเดิมเฉพาะเมื่อ "ลำดับการเรียก" เหมือนเดิม
--   ถ้า planner เลือก parallel plan ลำดับเปลี่ยน → ได้ vector คนละชุด
--   โดยไม่มี error ใดๆ  (ความล้มเหลวเงียบอีกแบบหนึ่ง)
--
--   ฟังก์ชันข้างล่างคำนวณจาก md5 ของ "คีย์" ล้วนๆ ไม่มี state
--   จึงได้ค่าเดิมเสมอ ไม่ว่าจะ parallel กี่ worker เรียงแถวแบบไหน
--   หรือรันบนเครื่องไหน
-- =============================================================

-- คืนค่าสุ่มสม่ำเสมอใน [0, 1)
-- ใช้ bit(28) เพราะ cast ไป int แล้วได้ค่าไม่ติดลบแน่นอน (2^28 = 268435456)
CREATE OR REPLACE FUNCTION qf_u01(key text)
RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT ('x' || substr(md5(key), 1, 7))::bit(28)::int::double precision
           / 268435456.0
$$;

-- คืนค่าสุ่มแบบปกติ (mean 0, sd 1) ด้วย Box-Muller
CREATE OR REPLACE FUNCTION qf_gauss(key text)
RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT sqrt(-2.0 * ln(greatest(qf_u01(key || ':a'), 1e-12)))
         * cos(2.0 * pi() * qf_u01(key || ':b'))
$$;

-- =============================================================
-- ตาราง
-- =============================================================

DROP TABLE IF EXISTS qf_truth, qf_queries, qf_corpus, qf_centroids, qf_manifest;

-- จุดศูนย์กลาง 50 กลุ่ม
-- สร้างแบบ deterministic ล้วน เพราะทั้ง corpus และ query อ้างอิงจากตารางนี้
CREATE TABLE qf_centroids (
    id        int PRIMARY KEY,
    embedding vector(:dim) NOT NULL
);

-- ข้อมูลหลักที่จะถูกค้น
CREATE TABLE qf_corpus (
    id         bigint PRIMARY KEY,
    cluster_id int    NOT NULL REFERENCES qf_centroids(id),
    embedding  vector(:dim) NOT NULL
);

-- ชุด query 200 ข้อ — นี่คือของที่ D09 สั่งให้ commit ก่อนมีผลลัพธ์
CREATE TABLE qf_queries (
    id         int PRIMARY KEY,
    cluster_id int NOT NULL REFERENCES qf_centroids(id),
    embedding  vector(:dim) NOT NULL
);

-- เฉลย: ผลจาก exact search  (หนึ่งแถวต่อ query ต่อค่า k)
CREATE TABLE qf_truth (
    query_id int    NOT NULL REFERENCES qf_queries(id),
    k        int    NOT NULL,
    ids      bigint[] NOT NULL,
    PRIMARY KEY (query_id, k)
);

-- กฎเหล็กข้อ 6: ทุกผลลัพธ์ต้องประทับเวอร์ชัน + วันที่
CREATE TABLE qf_manifest (
    item         text PRIMARY KEY,
    value        text NOT NULL,
    recorded_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO qf_manifest (item, value) VALUES
    ('dim',              :'dim'),
    ('clusters',         :'clusters'),
    ('queries',          :'queries'),
    ('pg_version',       current_setting('server_version')),
    ('pgvector_version', (SELECT extversion FROM pg_extension WHERE extname = 'vector')),
    ('schema_created',   now()::text);

-- กฎเหล็กข้อ 10: ถ้าหาสิ่งที่ควรมีไม่เจอ ต้องบอกว่าตรวจไม่ได้ ไม่ใช่ผ่าน
--
-- หมายเหตุ: psql **ไม่**แทนค่า :'var' ข้างใน dollar-quoted block
-- จึงต้องอ่านค่ากลับจาก qf_manifest ห้ามเขียน :'dim' ตรงนี้
DO $$
DECLARE v text; d text; c text; q text;
BEGIN
    SELECT value INTO v FROM qf_manifest WHERE item = 'pgvector_version';
    SELECT value INTO d FROM qf_manifest WHERE item = 'dim';
    SELECT value INTO c FROM qf_manifest WHERE item = 'clusters';
    SELECT value INTO q FROM qf_manifest WHERE item = 'queries';

    IF v IS NULL THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: หา extension vector ไม่เจอ — อย่าถือว่าผ่าน';
    END IF;
    RAISE NOTICE 'pgvector % · dim % · clusters % · queries %', v, d, c, q;
END $$;

\echo 'qf10 เสร็จ — ต่อด้วย qf11_query_set.sql'
