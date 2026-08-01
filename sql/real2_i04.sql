-- ============================================================
-- I04 บน embedding จริง — สร้าง index ใหม่แล้วได้คำตอบไม่เหมือนเดิม
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real_i04.sql
--
-- ข้ออ้างเดิม (corpus สังเคราะห์ · 5 build · ข้อมูลเดิมเป๊ะ · พารามิเตอร์เดิมเป๊ะ):
--   IVFFlat probes=1   ช่วง recall 9.4%  · **query ที่เปลี่ยนคำตอบ 196/200**
--   IVFFlat probes=5   ช่วง 0%           · query ที่เปลี่ยน **0/200**
--   HNSW ef=40         ช่วง 4.6%         · query ที่เปลี่ยน 132/200
--
-- ⭐ ประเด็นหลักของ I04: **ค่าเฉลี่ยซ่อนความจริงไว้เกือบทั้งหมด**
--    เฉลี่ยแกว่ง 9.4% ดูเหมือน noise ที่รับได้ แต่ราย query เกือบทุกข้อได้คำตอบไม่เท่ากัน
--
-- Q01 บนข้อมูลจริงวัดช่วงของ **ค่าเฉลี่ย** ไว้แล้ว (HNSW 0.0020 · IVFFlat 0.0960)
-- ไฟล์นี้วัด **ราย query** ซึ่งเป็นข้ออ้างจริงของ I04
--
-- ⚠️ เทียบคำตอบแบบเซ็ต (เรียง id ก่อนเทียบ) ไม่ใช่ตามลำดับ — ดู H32
-- ============================================================
\timing on
\set ON_ERROR_STOP on

DROP INDEX IF EXISTS qf_i04r2_idx;
DROP TABLE IF EXISTS qf_i04r2_ans;

CREATE TABLE qf_i04r2_ans (
    kind text, build_no int, query_id int, ids bigint[]
);

DO $$
BEGIN
    LOAD 'vector';                                        -- กฎเหล็กข้อ 9
    PERFORM set_config('temp_file_limit', '2GB', false);
END $$;

-- ------------------------------------------------------------
-- บันทึกคำตอบ top-10 ของทุก query ภายใต้ index ปัจจุบัน
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_i04r2_record(p_kind text, p_build int) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    -- อุ่น cache (กฎเหล็กข้อ 8)
    PERFORM (SELECT count(*) FROM (
        SELECT id FROM qf_real2
        ORDER BY embedding <=> (SELECT embedding FROM qf_real2_q WHERE id=0) LIMIT 10) w);

    INSERT INTO qf_i04r2_ans (kind, build_no, query_id, ids)
    SELECT p_kind, p_build, q.id,
           -- ⚠️ เรียงด้วย id เพื่อเทียบแบบเซ็ต ไม่ใช่ตามลำดับความใกล้ (H32)
           (SELECT array_agg(t.id ORDER BY t.id)
              FROM (SELECT c.id FROM qf_real2 c
                    ORDER BY c.embedding <=> q.embedding LIMIT 10) t)
    FROM qf_real2_q q;
END $$;

-- ------------------------------------------------------------
-- 3 การตั้งค่า × 5 build
-- ------------------------------------------------------------
DO $$
DECLARE b int;
BEGIN
    -- IVFFlat probes = 1 (ค่าเริ่มต้น)
    PERFORM set_config('ivfflat.probes', '1', false);
    FOR b IN 1..5 LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_i04r2_idx';
        EXECUTE 'CREATE INDEX qf_i04r2_idx ON qf_real2 '
                'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
        RAISE NOTICE 'IVFFlat probes=1 · build %/5', b;
        PERFORM qf_i04r2_record('IVFFlat probes=1', b);
    END LOOP;

    -- IVFFlat probes = 5 — ของเดิมพบว่ากลบความไม่แน่นอนได้หมดจด
    PERFORM set_config('ivfflat.probes', '5', false);
    FOR b IN 1..5 LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_i04r2_idx';
        EXECUTE 'CREATE INDEX qf_i04r2_idx ON qf_real2 '
                'USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
        RAISE NOTICE 'IVFFlat probes=5 · build %/5', b;
        PERFORM qf_i04r2_record('IVFFlat probes=5', b);
    END LOOP;
    PERFORM set_config('ivfflat.probes', '1', false);

    -- HNSW ef_search = 40 — กลุ่มควบคุม ข ของเดิม (ไม่มี k-means)
    PERFORM set_config('hnsw.ef_search', '40', false);
    FOR b IN 1..5 LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_i04r2_idx';
        EXECUTE 'CREATE INDEX qf_i04r2_idx ON qf_real2 '
                'USING hnsw (embedding vector_cosine_ops)';
        RAISE NOTICE 'HNSW ef=40 · build %/5', b;
        PERFORM qf_i04r2_record('HNSW ef_search=40', b);
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_i04r2_idx';
END $$;

-- ------------------------------------------------------------
-- ผล — ราย query เปลี่ยนคำตอบกี่ข้อ
-- ------------------------------------------------------------
\qecho ''
\qecho '=== query ที่ได้คำตอบไม่เหมือนกันข้าม 5 build (เทียบแบบเซ็ต) ==='
SELECT kind                                   AS "การตั้งค่า",
       count(*)                               AS "query ทั้งหมด",
       count(*) FILTER (WHERE n_distinct > 1) AS "เปลี่ยนคำตอบ",
       round(100.0 * count(*) FILTER (WHERE n_distinct > 1) / count(*), 1) AS "%",
       max(n_distinct)                        AS "คำตอบต่างกันสูงสุด (จาก 5)"
FROM (
    SELECT kind, query_id, count(DISTINCT ids) AS n_distinct
    FROM qf_i04r2_ans GROUP BY kind, query_id
) s
GROUP BY kind ORDER BY kind;

-- ------------------------------------------------------------
-- assertion
-- ------------------------------------------------------------
DO $$
DECLARE n_b int; n_idx int;
BEGIN
    SELECT count(DISTINCT build_no) INTO n_b FROM qf_i04r2_ans;
    IF n_b <> 5 THEN
        RAISE EXCEPTION 'ข้อ 1 ตก: บันทึกได้ % build (ต้อง 5)', n_b;
    END IF;
    RAISE NOTICE '[1/2] OK บันทึกครบ 5 build ต่อการตั้งค่า';

    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'ข้อ 2 ตก: มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE '[2/2] OK ไม่มี index ค้าง';
END $$;
