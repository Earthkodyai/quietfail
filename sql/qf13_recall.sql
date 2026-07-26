-- =============================================================
-- QuietFail — เฉลย + สูตร recall@k  (ไฟล์ที่ 4 จาก 4)
--
-- รัน:  psql ... -f /sql/qf13_recall.sql
--
-- ⚠️ ไฟล์นี้คือ "เกณฑ์วัดผล" ที่ PROJECT.md ข้อ 9 บังคับให้ commit
--    ก่อนมีตัวเลขใดๆ  แก้สูตรหลังเห็นผล = เลือกเกณฑ์เข้าข้างตัวเอง (D09)
--
-- นิยาม:  recall@k = จำนวนที่ตรงกับเฉลย k อันดับแรก หารด้วย k
--         รายงานเป็นค่าเฉลี่ยข้าม 200 query
--
-- ระยะทางที่ใช้: cosine (<=>)
--   vector ทุกตัวถูก l2_normalize แล้ว การเรียงลำดับจึงเท่ากับ L2
--   แต่ต้องเขียนให้ชัดว่าใช้ตัวไหน เพราะ opclass ต้องตรงกับ operator (I01)
-- =============================================================

\set ON_ERROR_STOP on

LOAD 'vector';

\timing on

-- =============================================================
-- สร้างเฉลยด้วย exact search
--
-- วิธีปิด index เป็นวิธีที่เอกสารทางการแนะนำเอง (ดู EVIDENCE.md)
-- ไม่ใช้ DROP INDEX เพราะช้าและเปลี่ยนสภาพฐานข้อมูล
-- =============================================================
CREATE OR REPLACE FUNCTION qf_build_truth(p_k int)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    n_done bigint := 0;
    q      record;
    plan   json;
    plan_s text;
BEGIN
    -- true = มีผลเฉพาะใน transaction นี้ ไม่แตะสภาพ DB
    PERFORM set_config('enable_indexscan',     'off', true);
    PERFORM set_config('enable_indexonlyscan', 'off', true);
    PERFORM set_config('enable_bitmapscan',    'off', true);

    -- กฎเหล็กข้อ 10: ต้องพิสูจน์ว่า "ปิด index สำเร็จจริง"
    -- ถ้าเผลอบันทึกผลจาก approximate search มาเป็นเฉลย
    -- recall จะออกมาสวยเสมอโดยไม่มีอะไรเตือน — พังทั้งโปรเจค
    EXECUTE format(
        'EXPLAIN (FORMAT JSON) SELECT id FROM qf_corpus '
        'ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id = 1) '
        'LIMIT %s', p_k
    ) INTO plan;

    plan_s := plan::text;
    IF plan_s ILIKE '%Index Scan%' OR plan_s ILIKE '%Index Only Scan%' THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: ยังมี index scan อยู่ในแผน เฉลยนี้ใช้ไม่ได้ — plan: %',
            plan_s;
    END IF;

    DELETE FROM qf_truth WHERE k = p_k;

    FOR q IN SELECT id, embedding FROM qf_queries ORDER BY id LOOP
        INSERT INTO qf_truth (query_id, k, ids)
        SELECT q.id, p_k, array_agg(t.id ORDER BY t.rn)
        FROM (
            SELECT c.id, row_number() OVER () AS rn
            FROM qf_corpus c
            ORDER BY c.embedding <=> q.embedding
            LIMIT p_k
        ) t;
        n_done := n_done + 1;
    END LOOP;

    RETURN n_done;
END $$;

-- =============================================================
-- วัด recall@k ด้วยการตั้งค่าที่ใช้อยู่ ณ ขณะนั้น
--
-- ฟังก์ชันนี้ไม่แตะ ef_search / probes เลย — คนเรียกเป็นคนตั้ง
-- แล้วบันทึกว่าตั้งเท่าไหร่ (กฎเหล็กข้อ 2: ค่าต้องมาจากการวัด ไม่ใช่จากไฟล์นี้)
-- =============================================================
CREATE OR REPLACE FUNCTION qf_recall_at(p_k int)
RETURNS TABLE (
    k             int,
    n_queries     int,
    mean_recall   numeric,
    min_recall    numeric,
    n_perfect     int
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM qf_truth WHERE qf_truth.k = p_k) THEN
        RAISE EXCEPTION
            'ตรวจไม่ได้: ยังไม่มีเฉลยสำหรับ k=% — เรียก qf_build_truth(%) ก่อน',
            p_k, p_k;
    END IF;

    RETURN QUERY
    WITH per_query AS (
        SELECT
            t.query_id,
            (
                SELECT count(*)
                FROM unnest(t.ids) AS truth_id
                WHERE truth_id = ANY (
                    SELECT c.id
                    FROM qf_corpus c
                    ORDER BY c.embedding <=> q.embedding
                    LIMIT p_k
                )
            )::numeric / p_k AS recall
        FROM qf_truth t
        JOIN qf_queries q ON q.id = t.query_id
        WHERE t.k = p_k
    )
    SELECT
        p_k,
        count(*)::int,
        round(avg(recall), 4),
        round(min(recall), 4),
        count(*) FILTER (WHERE recall = 1.0)::int
    FROM per_query;
END $$;

-- =============================================================
-- สร้างเฉลยสำหรับ k = 10 และ k = 100
-- ที่ 100k แถว งานนี้คือ exact scan 200 รอบ ใช้เวลาพอสมควร
-- =============================================================
SELECT qf_build_truth(10)  AS truth_rows_k10;
SELECT qf_build_truth(100) AS truth_rows_k100;

DO $$
DECLARE n10 int; n100 int; short_rows int;
BEGIN
    SELECT count(*) INTO n10   FROM qf_truth WHERE k = 10;
    SELECT count(*) INTO n100  FROM qf_truth WHERE k = 100;
    SELECT count(*) INTO short_rows
    FROM qf_truth WHERE cardinality(ids) <> k;

    IF n10 <> 200 OR n100 <> 200 THEN
        RAISE EXCEPTION 'เฉลยไม่ครบ 200 query (k10=% k100=%)', n10, n100;
    END IF;
    IF short_rows > 0 THEN
        RAISE EXCEPTION
            'มีเฉลย % แถวที่ได้ไม่ครบ k — corpus เล็กเกินไปหรือ query พัง',
            short_rows;
    END IF;
    RAISE NOTICE 'เฉลยครบ: k=10 และ k=100 อย่างละ 200 query';
END $$;

-- =============================================================
-- อ่านค่าฐาน — ยังไม่มี vector index จึงต้องได้ recall = 1.0 พอดี
-- ถ้าไม่ใช่ 1.0 แปลว่าสูตรวัดผิดเอง ต้องหยุดแก้ก่อนวัดอะไรต่อ
--
-- กฎเหล็กข้อ 8: อุ่น cache ก่อนวัดเสมอ
-- =============================================================
SELECT count(*) FROM qf_corpus;   -- warm-up รอบทิ้ง

SELECT * FROM qf_recall_at(10);
SELECT * FROM qf_recall_at(100);

DO $$
DECLARE r numeric;
BEGIN
    SELECT mean_recall INTO r FROM qf_recall_at(10);
    IF r IS DISTINCT FROM 1.0000 THEN
        RAISE EXCEPTION
            'sanity check ไม่ผ่าน: ยังไม่มี index แต่ recall@10 = % (ต้องเป็น 1.0) '
            '→ สูตรวัดผิด ห้ามเอาไปวัดผลจริง', r;
    END IF;
    RAISE NOTICE 'sanity check ผ่าน: ไม่มี index → recall@10 = 1.0 ตามนิยาม';
END $$;

INSERT INTO qf_manifest (item, value)
SELECT 'metric', 'cosine (<=>) · recall@k = |truth_k ∩ approx_k| / k · เฉลี่ย 200 query'
ON CONFLICT (item) DO UPDATE SET value = EXCLUDED.value, recorded_at = now();

SELECT item, value, recorded_at FROM qf_manifest ORDER BY item;

\echo ''
\echo '>>> เฟส 0 ปิดได้เมื่อไฟล์นี้รันผ่านทั้งหมดโดยไม่มี exception'
