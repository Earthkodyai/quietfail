-- ============================================================
-- I04 — ทดสอบสมมติฐาน "การสุ่มระดับชั้นตอน build คือกลไก"
--
-- 🔴🔴 อ่านก่อนใช้ไฟล์นี้อ้างอะไรก็ตาม — การทดลองนี้ **เล็งผิดตัวตั้งแต่ต้น** (E41)
--
--   หลังรันเสร็จจึงไปอ่านซอร์ส แล้วพบว่า
--     pgvector  : #define RandomDouble() pg_prng_double(&pg_global_prng_state)
--     PostgreSQL: static pg_prng_state prng_state;   <- setseed() คุมตัวนี้
--   **คนละตัวกัน** · setseed() จึงไม่มีทางมีผลกับ HNSW ตั้งแต่แรก
--   ผลลบที่ได้จึงเป็นสิ่งที่ทำนายได้จากซอร์ส ไม่ใช่ข้อค้นพบ
--
--   และ **กลไกของ I04 ทราบแล้ว** — HNSW สุ่มระดับชั้นให้ทุกจุดตอน build
--   (int level = (int)(-log(RandomDouble()) * ml) ใน hnswutils.c)
--   ซึ่งเป็นขั้นตอนมาตรฐานของอัลกอริทึม จึงต่างกันทุก build **โดยการออกแบบ**
--
--   สิ่งที่ไฟล์นี้ยังยืนยันได้จริง: **ไม่มีวิธีทำให้ build ซ้ำได้จากฝั่ง SQL**
--   เพราะ pg_global_prng_state ไม่มีอินเทอร์เฟซให้ผู้ใช้ตั้งค่า
--
--   บทเรียน: กฎเหล็กข้อ 1 บอกให้ซอร์สเป็นคนตัดสิน รอบนี้ทำสลับลำดับ
--   **ก่อนออกแบบการทดลองเพื่อหา "กลไก" ให้ค้นซอร์สก่อนเสมอ**
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/i04_seed_probe.sql
--
-- คำถามที่ค้างมาทั้งโปรเจค: **ทำไมสร้าง HNSW ใหม่บนข้อมูลเดิมเป๊ะ แล้วได้คำตอบต่างกัน**
--   กลุ่มควบคุมเดิมตัดออกได้ 2 ข้อ — ฝั่ง query (นิ่ง) และ parallel build (ปิดแล้วยังแกว่ง)
--   ยังไม่เคยทดสอบข้อที่สาม: **ตัวสุ่มของ PostgreSQL เอง**
--
-- อัลกอริทึม HNSW มาตรฐานสุ่ม "ระดับชั้น" ให้แต่ละจุดตอนสร้างกราฟ
-- ถ้าตัวสุ่มนั้นผูกกับ PRNG ของ session การ setseed ค่าเดิมควรทำให้ build ซ้ำได้
--
-- ออกแบบ: 3 build ต่อเงื่อนไข · เทียบคำตอบ top-10 ราย query
--   A  setseed ค่าเดียวกันทุก build   -> ถ้าเหมือนกันหมด = เจอกลไก
--   B  ไม่ setseed เลย (ค่าฐาน)       -> ควรแกว่งราว 132/200 ตามที่ I04 วัดไว้
--
-- ⚠️ ใช้ qf_corpus เพราะสัญญาณแรงที่สุด (แกว่ง 66%) — บน embedding จริงแกว่งแค่ 3%
--    ซึ่งน้อยเกินกว่าจะแยกผลได้ชัด
-- ⚠️ อ่าน qf_corpus อย่างเดียว ไม่แก้แถวใดๆ · มี guard fingerprint ก่อน/หลัง
-- ⚠️ ปิด parallel build เพื่อให้ทุกอย่างอยู่ใน session เดียวกับที่ setseed
--    ไม่งั้น worker อาจมี PRNG ของตัวเอง แล้วแยกผลไม่ออก
-- ⚠️ เทียบคำตอบแบบเซ็ต (เรียง id ก่อน) ตาม H32
-- ============================================================
-- 🔴 ไฟล์นี้สร้าง index **บน qf_corpus โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_seed_idx;
--    แล้วยืนยันด้วย    python scripts/audit.py
\timing on
\set ON_ERROR_STOP on

SET max_parallel_maintenance_workers = 0;
SET max_parallel_workers_per_gather = 0;

DROP INDEX IF EXISTS qf_seed_idx;
DROP TABLE IF EXISTS qf_seed_ans;
DROP TABLE IF EXISTS qf_seed_guard;

-- ⭐ เรียกนิยามกลาง ห้ามเขียนสูตรเอง (E40)
CREATE TABLE qf_seed_guard AS
SELECT (SELECT count(*) FROM qf_corpus) AS rows,
       qf_fingerprint('qf_corpus') AS fp;

DO $$
DECLARE g record;
BEGIN
    SELECT * INTO g FROM qf_seed_guard;
    IF g.fp <> '5a32cba54ea2be4ed022fe8bfedae9b0' THEN
        RAISE EXCEPTION 'จุดเริ่มต้นผิด: fingerprint ของ qf_corpus = %', g.fp;
    END IF;
    LOAD 'vector';                                        -- กฎเหล็กข้อ 9
    PERFORM set_config('temp_file_limit', '2GB', false);  -- กับดักข้อ 8
    RAISE NOTICE 'qf_corpus ปกติ — เริ่มทดสอบได้';
END $$;

CREATE TABLE qf_seed_ans (cond text, build_no int, query_id int, ids bigint[]);

-- ------------------------------------------------------------
-- บันทึกคำตอบ top-10 ของทุก query ภายใต้ index ปัจจุบัน
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_seed_record(p_cond text, p_build int) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    -- อุ่น cache (กฎเหล็กข้อ 8)
    PERFORM (SELECT count(*) FROM (
        SELECT id FROM qf_corpus
        ORDER BY embedding <=> (SELECT embedding FROM qf_queries WHERE id=1) LIMIT 10) w);

    INSERT INTO qf_seed_ans (cond, build_no, query_id, ids)
    SELECT p_cond, p_build, q.id,
           (SELECT array_agg(t.id ORDER BY t.id)      -- เรียง id = เทียบแบบเซ็ต (H32)
              FROM (SELECT c.id FROM qf_corpus c
                    ORDER BY c.embedding <=> q.embedding LIMIT 10) t)
    FROM qf_queries q;
END $$;

-- ------------------------------------------------------------
-- A) setseed ค่าเดียวกันก่อนทุก build
-- ------------------------------------------------------------
\qecho ''
\qecho '=== A: setseed(0.42) เหมือนกันทุก build ==='
DO $$
DECLARE b int;
BEGIN
    PERFORM set_config('hnsw.ef_search', '40', false);
    FOR b IN 1..3 LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_seed_idx';
        PERFORM setseed(0.42);                    -- <- ตัวแปรเดียวที่ต่างจาก B
        EXECUTE 'CREATE INDEX qf_seed_idx ON qf_corpus '
                'USING hnsw (embedding vector_cosine_ops)';
        RAISE NOTICE 'A setseed(0.42) · build %/3', b;
        PERFORM qf_seed_record('A setseed เท่ากัน', b);
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_seed_idx';
END $$;

-- ------------------------------------------------------------
-- B) ไม่ setseed เลย — ค่าฐาน ควรแกว่งตามที่ I04 วัดไว้
-- ------------------------------------------------------------
\qecho ''
\qecho '=== B: ไม่ setseed (ค่าฐาน) ==='
DO $$
DECLARE b int;
BEGIN
    PERFORM set_config('hnsw.ef_search', '40', false);
    FOR b IN 1..3 LOOP
        EXECUTE 'DROP INDEX IF EXISTS qf_seed_idx';
        EXECUTE 'CREATE INDEX qf_seed_idx ON qf_corpus '
                'USING hnsw (embedding vector_cosine_ops)';
        RAISE NOTICE 'B ไม่ setseed · build %/3', b;
        PERFORM qf_seed_record('B ไม่ setseed', b);
    END LOOP;
    EXECUTE 'DROP INDEX IF EXISTS qf_seed_idx';
END $$;

-- ------------------------------------------------------------
-- ผล
-- ------------------------------------------------------------
\qecho ''
SELECT cond                                   AS "เงื่อนไข",
       count(*)                               AS "query ทั้งหมด",
       count(*) FILTER (WHERE n > 1)          AS "เปลี่ยนคำตอบ",
       round(100.0 * count(*) FILTER (WHERE n > 1) / count(*), 1) AS "%"
FROM (SELECT cond, query_id, count(DISTINCT ids) AS n
      FROM qf_seed_ans GROUP BY cond, query_id) s
GROUP BY cond ORDER BY cond;

-- ------------------------------------------------------------
-- assertion + สรุปผล
-- ------------------------------------------------------------
DO $$
DECLARE
    a_diff int; b_diff int; g record; now_fp text; n_idx int;
BEGIN
    SELECT count(*) FILTER (WHERE n > 1) INTO a_diff
      FROM (SELECT query_id, count(DISTINCT ids) n FROM qf_seed_ans
            WHERE cond LIKE 'A%' GROUP BY query_id) s;
    SELECT count(*) FILTER (WHERE n > 1) INTO b_diff
      FROM (SELECT query_id, count(DISTINCT ids) n FROM qf_seed_ans
            WHERE cond LIKE 'B%' GROUP BY query_id) s;

    -- ค่าฐานต้องแกว่งจริง ไม่งั้นการทดลองไม่มีความหมาย
    IF b_diff = 0 THEN
        RAISE EXCEPTION
            'ข้อ 1 ตก: ค่าฐานไม่แกว่งเลย — I04 ไม่เกิดในรอบนี้ ผลของ A จึงตีความไม่ได้';
    END IF;
    RAISE NOTICE '[1/3] OK ค่าฐานแกว่ง % จาก 200 query — I04 เกิดจริงในรอบนี้', b_diff;

    IF a_diff = 0 THEN
        RAISE NOTICE '[2/3] ⭐⭐ setseed เท่ากัน -> คำตอบเหมือนกันทุก query';
        RAISE NOTICE '        => กลไกคือการสุ่มที่ผูกกับ PRNG ของ session';
    ELSIF a_diff < b_diff THEN
        RAISE NOTICE '[2/3] setseed ลดความแกว่งจาก % เหลือ % — มีผลบางส่วน', b_diff, a_diff;
        RAISE NOTICE '        => PRNG ของ session เป็นปัจจัยหนึ่ง แต่ไม่ใช่ทั้งหมด';
    ELSE
        RAISE NOTICE '[2/3] setseed ไม่ช่วย (% vs ค่าฐาน %)', a_diff, b_diff;
        RAISE NOTICE '        => ตัดออกได้อีกหนึ่งข้อ — ไม่ใช่ PRNG ของ session';
    END IF;

    -- ⚠️ plpgsql ไม่ยอมให้ตัวแปรชนิด record อยู่ใน INTO ร่วมกับตัวแปรอื่น
    --    เขียนแยกสองคำสั่งเสมอ (เจอตอนรันจริงครั้งแรก)
    SELECT * INTO g FROM qf_seed_guard;
    SELECT qf_fingerprint('qf_corpus') INTO now_fp;
    IF now_fp <> g.fp THEN
        RAISE EXCEPTION 'qf_corpus เปลี่ยนไป! ก่อน % · หลัง %', g.fp, now_fp;
    END IF;

    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n_idx;
    END IF;
    RAISE NOTICE '[3/3] OK qf_corpus ไม่ถูกแตะ · ไม่มี index ค้าง';
END $$;

-- 🔴 รุ่นก่อนลบแต่ qf_seed_guard ทิ้ง qf_seed_ans ค้างไว้ทุกครั้ง (240 kB)
--    เจอตอนทวน 2026-08-02 · ตารางผลไม่ใช่หลักฐาน (ผลจริงอยู่ใน results/)
DROP TABLE IF EXISTS qf_seed_guard;
DROP TABLE IF EXISTS qf_seed_ans;
