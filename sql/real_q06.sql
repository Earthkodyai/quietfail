-- ============================================================
-- Q06 บน embedding จริง — หน้าผาที่ k = ef_search + 1
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real_q06.sql
--
-- ข้ออ้างเดิม (corpus สังเคราะห์ · ef_search = 40):
--   ขอ 39 -> ได้ 39 ครบ · ขอ 40 -> ได้ 40 ครบ
--   ขอ 41 -> ได้ **40** ขาด 1 · ขอ 100 -> ได้ **40** ขาด 60
--   **เพดานเท่ากับ ef_search พอดีเป๊ะ ไม่ใช่ใกล้เคียง**
--
-- Q01 บนข้อมูลจริงให้ recall@100 = 0.4005 นิ่งสนิททั้ง 5 build
-- ซึ่งเท่ากับ 40/100 พอดี = หลักฐานทางอ้อมว่าเพดานยังอยู่
-- ไฟล์นี้วัดตรงๆ แทนที่จะอนุมาน
-- ============================================================
\timing on
\set ON_ERROR_STOP on

DROP INDEX IF EXISTS qf_q06r_idx;
DROP TABLE IF EXISTS qf_q06r_obs;

CREATE TABLE qf_q06r_obs (ef int, asked int, got bigint, got_exact bigint);

DO $$
BEGIN
    LOAD 'vector';                                        -- กฎเหล็กข้อ 9
    PERFORM set_config('temp_file_limit', '2GB', false);
END $$;

CREATE INDEX qf_q06r_idx ON qf_real USING hnsw (embedding vector_cosine_ops);
ANALYZE qf_real;

CREATE OR REPLACE FUNCTION qf_q06r_probe(p_ef int, p_limit int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE n bigint; n_exact bigint;
BEGIN
    PERFORM set_config('hnsw.ef_search', p_ef::text, false);

    -- อุ่น cache (กฎเหล็กข้อ 8)
    PERFORM (SELECT count(*) FROM (
        SELECT id FROM qf_real
        ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 10) w);

    EXECUTE format('SELECT count(*) FROM (SELECT id FROM qf_real '
                   'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) '
                   'LIMIT %s) s', p_limit) INTO n;

    PERFORM set_config('enable_indexscan', 'off', true);
    EXECUTE format('SELECT count(*) FROM (SELECT id FROM qf_real '
                   'ORDER BY embedding <=> (SELECT embedding FROM qf_real_q WHERE id=0) '
                   'LIMIT %s) s', p_limit) INTO n_exact;
    PERFORM set_config('enable_indexscan', 'on', true);

    INSERT INTO qf_q06r_obs VALUES (p_ef, p_limit, n, n_exact);
END $$;

\qecho ''
\qecho '=== ef_search = 40 (ค่าเริ่มต้น) · ไล่ค่า LIMIT รอบหน้าผา ==='
SELECT qf_q06r_probe(40, 10);
SELECT qf_q06r_probe(40, 39);
SELECT qf_q06r_probe(40, 40);
SELECT qf_q06r_probe(40, 41);
SELECT qf_q06r_probe(40, 50);
SELECT qf_q06r_probe(40, 100);
SELECT qf_q06r_probe(40, 1000);

\qecho ''
\qecho '=== ขอ 100 แถว · ไล่ค่า ef_search ==='
SELECT qf_q06r_probe(100, 100);
SELECT qf_q06r_probe(200, 100);

SELECT ef AS "ef_search", asked AS "ขอ", got AS "ได้", got_exact AS "เฉลย",
       CASE WHEN got < asked THEN 'ขาด ' || (asked - got) ELSE 'ครบ' END AS "ผล"
FROM qf_q06r_obs ORDER BY ctid;

-- ------------------------------------------------------------
-- assertion — เพดานต้องเท่ากับ ef_search พอดี ไม่ใช่ใกล้เคียง
-- ------------------------------------------------------------
DO $$
DECLARE g39 bigint; g40 bigint; g41 bigint; g100 bigint; g1000 bigint;
BEGIN
    SELECT got INTO g39   FROM qf_q06r_obs WHERE ef=40 AND asked=39;
    SELECT got INTO g40   FROM qf_q06r_obs WHERE ef=40 AND asked=40;
    SELECT got INTO g41   FROM qf_q06r_obs WHERE ef=40 AND asked=41;
    SELECT got INTO g100  FROM qf_q06r_obs WHERE ef=40 AND asked=100;
    SELECT got INTO g1000 FROM qf_q06r_obs WHERE ef=40 AND asked=1000;

    IF g39 <> 39 OR g40 <> 40 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: ที่ k <= ef ต้องได้ครบ แต่ได้ 39->% · 40->%', g39, g40;
    END IF;
    RAISE NOTICE '[1/2] OK ที่ k <= ef_search ได้ครบทุกกรณี';

    -- ⚠️ เพดานไม่จำเป็นต้องอยู่ที่ ef พอดี — บนข้อมูลจริงอยู่ที่ 41 (ef+1)
    --    ตัวชี้ขาดคือ "ขอเยอะขึ้นแล้วได้เท่าเดิม" ไม่ใช่ค่าเพดานที่แน่นอน
    IF g100 <> g1000 THEN
        RAISE EXCEPTION
            'ข้อ 2 ตก: ขอ 100 ได้ % แต่ขอ 1000 ได้ % — ไม่มีเพดานตายตัว fault ไม่เกิด',
            g100, g1000;
    END IF;
    RAISE NOTICE '[2/2] OK เพดานตายตัวที่ % แถว (ef_search = 40) — ขอ 50·100·1000 ได้เท่ากันหมด',
        g1000;
END $$;

DROP INDEX IF EXISTS qf_q06r_idx;
RESET hnsw.ef_search;

DO $$
DECLARE n_idx int;
BEGIN
    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE 'ไม่มี index ค้าง';
END $$;
