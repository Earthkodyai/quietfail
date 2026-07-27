-- ============================================================
-- Q04 — ใช้ค่า default โดยไม่เคยวัด → recall ต่ำแบบเงียบ
--
-- รัน:  psql ... -f /sql/q04_default_params.sql
--
-- อาการ  : recall ต่ำตั้งแต่วันแรก ไม่มีใครรู้ เพราะไม่เคยวัด
-- ต้นเหตุ: ค่าเริ่มต้นของ pgvector ต่ำกว่าที่เอกสารของตัวเองแนะนำ
--            ivfflat.probes = 1   แต่เอกสารแนะนำ sqrt(lists)
--            hnsw.ef_search = 40  แต่เอกสารบอกให้เพิ่มถ้า recall ต่ำ
--
-- ⭐ ต่างจาก Q01 ตรงที่ Q01 ถามว่า "index ทำผลหายไปเท่าไหร่"
--    ส่วน Q04 ถามว่า "ที่หายไปนั้น เกิดจากค่า default ที่ไม่มีใครแตะกี่ %"
--    Q01 = ปัญหาของ ANN · Q04 = ปัญหาของค่าที่ผู้พัฒนาเลือกให้
--
-- ที่ 100,000 แถว เอกสารแนะนำ lists = rows/1000 = 100
-- จึงควรตั้ง probes = sqrt(100) = 10 แต่ค่าเริ่มต้นคือ 1 — ต่ำกว่า 10 เท่า
--
-- นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
-- ============================================================

\set ON_ERROR_STOP on
LOAD 'vector';                       -- กฎเหล็กข้อ 9
SET max_parallel_workers_per_gather = 0;

\set lists 100

DO $$
DECLARE fp text; n int;
BEGIN
    SELECT value INTO fp FROM qf_manifest WHERE item = 'query_set_fingerprint';
    IF fp IS DISTINCT FROM '607babfb6344eab74d3e76496b04fa9f' THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: fingerprint ชุด query ไม่ตรง (ได้ %)', fp;
    END IF;
    SELECT count(*) INTO n FROM qf_truth WHERE k = 10;
    IF n <> 200 THEN
        RAISE EXCEPTION 'ตรวจไม่ได้: เฉลย k=10 มี % แถว (ต้อง 200)', n;
    END IF;
    SELECT count(*) INTO n
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n <> 0 THEN
        RAISE EXCEPTION 'จุดเริ่มต้นไม่สะอาด: มี vector index ค้าง % ตัว', n;
    END IF;
    RAISE NOTICE 'ด่านตรวจผ่าน';
END $$;

DROP TABLE IF EXISTS qf_q04_results;
CREATE TABLE qf_q04_results (
    index_kind  text,
    param_name  text,
    param_value int,
    is_default  boolean,
    is_doc_rec  boolean,   -- ตรงกับที่เอกสารแนะนำไหม
    mean_recall numeric,
    min_recall  numeric,
    n_perfect   int,
    query_ms    numeric
);

CREATE OR REPLACE FUNCTION qf_q04_measure(
    p_kind text, p_param text, p_val int, p_default boolean, p_doc boolean
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; ms numeric; r record; qvec vector;
BEGIN
    PERFORM set_config(p_param, p_val::text, false);

    -- กฎเหล็กข้อ 8: อุ่น cache
    SELECT embedding INTO qvec FROM qf_queries WHERE id = 1;
    PERFORM (SELECT count(*) FROM (
        SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> qvec LIMIT 10) z);

    t0 := clock_timestamp();
    PERFORM (SELECT count(*) FROM (
                SELECT c.id FROM qf_corpus c ORDER BY c.embedding <=> q.embedding LIMIT 10) z)
    FROM qf_queries q;
    ms := round((extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric, 1);

    SELECT * INTO r FROM qf_recall_at(10);

    INSERT INTO qf_q04_results VALUES
        (p_kind, p_param, p_val, p_default, p_doc,
         r.mean_recall, r.min_recall, r.n_perfect, ms);
END $$;

-- ============================================================
-- ส่วนที่ 1 — IVFFlat: probes จากค่าเริ่มต้นถึงสแกนทุกกลุ่ม
-- ============================================================
\qecho
\qecho '=== IVFFlat lists = 100 (ตามสูตร rows/1000) · ไล่ค่า probes ==='
SET temp_file_limit = '2GB';
CREATE INDEX qf_q04_ivf ON qf_corpus USING ivfflat (embedding vector_cosine_ops) WITH (lists = :lists);
RESET temp_file_limit;

SELECT qf_q04_measure('ivfflat', 'ivfflat.probes',   1, true,  false);
SELECT qf_q04_measure('ivfflat', 'ivfflat.probes',   2, false, false);
SELECT qf_q04_measure('ivfflat', 'ivfflat.probes',   5, false, false);
SELECT qf_q04_measure('ivfflat', 'ivfflat.probes',  10, false, true);   -- sqrt(lists)
SELECT qf_q04_measure('ivfflat', 'ivfflat.probes',  20, false, false);
SELECT qf_q04_measure('ivfflat', 'ivfflat.probes',  50, false, false);
SELECT qf_q04_measure('ivfflat', 'ivfflat.probes', 100, false, false);  -- ทุกกลุ่ม = exact

DROP INDEX qf_q04_ivf;
RESET ivfflat.probes;

-- ============================================================
-- ส่วนที่ 2 — HNSW: ef_search จากค่าเริ่มต้นขึ้นไป
--             ใช้ k=10 เพื่อไม่ให้ปนกับ Q06 (ซึ่งเกิดตอน LIMIT > ef)
-- ============================================================
\qecho
\qecho '=== HNSW · ไล่ค่า ef_search (วัดที่ k=10 เพื่อแยกจาก Q06) ==='
SET temp_file_limit = '2GB';
SET maintenance_work_mem = '256MB';
CREATE INDEX qf_q04_hnsw ON qf_corpus USING hnsw (embedding vector_cosine_ops);
RESET temp_file_limit;

SELECT qf_q04_measure('hnsw', 'hnsw.ef_search',  40, true,  false);
SELECT qf_q04_measure('hnsw', 'hnsw.ef_search',  80, false, false);
SELECT qf_q04_measure('hnsw', 'hnsw.ef_search', 160, false, false);
SELECT qf_q04_measure('hnsw', 'hnsw.ef_search', 320, false, false);

DROP INDEX qf_q04_hnsw;
RESET hnsw.ef_search;

-- ============================================================
\qecho
\qecho '=== ผล: ค่า default แลกอะไรไปบ้าง ==='
SELECT index_kind AS "index", param_name AS "พารามิเตอร์", param_value AS "ค่า",
       CASE WHEN is_default THEN 'ค่าเริ่มต้น' WHEN is_doc_rec THEN 'เอกสารแนะนำ' ELSE '' END AS "หมายเหตุ",
       mean_recall AS "recall@10", min_recall AS "แย่สุด",
       n_perfect AS "ครบ 10/10", query_ms AS "200 query (ms)"
FROM qf_q04_results
ORDER BY index_kind, param_value;

-- ============================================================
-- assertion — กฎเหล็กข้อ 3
-- ============================================================
DO $$
DECLARE
    d_ivf  qf_q04_results%ROWTYPE;
    r_ivf  qf_q04_results%ROWTYPE;
    a_ivf  qf_q04_results%ROWTYPE;
    d_hnsw qf_q04_results%ROWTYPE;
    m_hnsw qf_q04_results%ROWTYPE;
BEGIN
    SELECT * INTO d_ivf  FROM qf_q04_results WHERE index_kind='ivfflat' AND is_default;
    SELECT * INTO r_ivf  FROM qf_q04_results WHERE index_kind='ivfflat' AND is_doc_rec;
    SELECT * INTO a_ivf  FROM qf_q04_results WHERE index_kind='ivfflat' AND param_value=100;
    SELECT * INTO d_hnsw FROM qf_q04_results WHERE index_kind='hnsw' AND is_default;
    SELECT * INTO m_hnsw FROM qf_q04_results WHERE index_kind='hnsw' AND param_value=320;

    -- ข้อ 1: ค่าเริ่มต้นต้องแย่กว่าค่าที่เอกสารแนะนำอย่างมีนัย
    IF d_ivf.mean_recall >= r_ivf.mean_recall THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: probes=1 ได้ recall % ไม่แย่กว่า probes=10 (%) — fault ไม่เกิด',
            d_ivf.mean_recall, r_ivf.mean_recall;
    END IF;
    RAISE NOTICE '[1/5] OK probes=1 (ค่าเริ่มต้น) recall % · probes=10 (เอกสารแนะนำ) recall %',
        d_ivf.mean_recall, r_ivf.mean_recall;

    -- ข้อ 2: สแกนทุกกลุ่มต้องได้ recall เกือบสมบูรณ์
    --        กลุ่มควบคุม: พิสูจน์ว่า index กับข้อมูลไม่มีปัญหา ตัวแปรคือ probes จริง
    IF a_ivf.mean_recall < 0.99 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: probes=100 (ทุกกลุ่ม) ได้ recall % ไม่ถึง 0.99 → ปัญหาไม่ได้อยู่ที่ probes อย่างเดียว',
            a_ivf.mean_recall;
    END IF;
    RAISE NOTICE '[2/5] OK probes=100 (สแกนทุกกลุ่ม) recall % → ตัวแปรคือ probes จริง',
        a_ivf.mean_recall;

    -- ข้อ 3: HNSW ค่าเริ่มต้นต้องแย่กว่าค่าที่สูงกว่า
    IF d_hnsw.mean_recall >= m_hnsw.mean_recall THEN
        RAISE EXCEPTION
            'ข้อ 3 ตก: ef_search=40 ได้ recall % ไม่แย่กว่า ef_search=320 (%)',
            d_hnsw.mean_recall, m_hnsw.mean_recall;
    END IF;
    RAISE NOTICE '[3/5] OK ef_search=40 (ค่าเริ่มต้น) recall % · ef_search=320 recall %',
        d_hnsw.mean_recall, m_hnsw.mean_recall;

    -- ข้อ 4: ต้นทุนของการเพิ่มค่าต้องมีจริง — ไม่งั้นค่าเริ่มต้นไม่มีเหตุผลเลย
    IF a_ivf.query_ms <= d_ivf.query_ms THEN
        RAISE EXCEPTION
            'ข้อ 4 ตก: probes=100 ไม่ได้ช้ากว่า probes=1 (% vs % ms) — การแลกไม่มีอยู่จริง',
            a_ivf.query_ms, d_ivf.query_ms;
    END IF;
    RAISE NOTICE '[4/5] OK การแลกมีจริง: probes=1 ใช้ % ms · probes=100 ใช้ % ms (ช้าลง % เท่า)',
        d_ivf.query_ms, a_ivf.query_ms, round(a_ivf.query_ms / d_ivf.query_ms, 1);

    -- ข้อ 5: ทุกค่าต้องไม่มี error — ค่าที่แย่ก็ยัง "ทำงานได้"
    IF EXISTS (SELECT 1 FROM qf_q04_results WHERE mean_recall IS NULL) THEN
        RAISE EXCEPTION 'ข้อ 5 ตก: มีค่าที่วัดไม่ได้';
    END IF;
    RAISE NOTICE '[5/5] OK วัดได้ครบทุกค่า ไม่มี error → ค่าที่แย่ก็ยังทำงานได้ปกติ';

    RAISE NOTICE 'assertion ผ่านครบ 5 ข้อ';
END $$;

\qecho
\qecho '=== ค่าเริ่มต้นต่ำกว่าที่เอกสารของผู้พัฒนาเองแนะนำ 10 เท่า ==='
\qecho '=== และไม่มีอะไรเตือน เพราะไม่มีใครวัด recall ตอน deploy ==='
