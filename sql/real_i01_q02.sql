-- ============================================================
-- I01 + Q02 บน embedding จริง — สองข้อสุดท้ายที่ยังไม่ได้ทดสอบข้ามชุดข้อมูล
--
-- รัน:  MSYS_NO_PATHCONV=1 docker compose exec -T db \
--         psql -U lab -d faultlab -v ON_ERROR_STOP=1 -f //sql/real_i01_q02.sql
--
-- ต้องรัน real_load.sql ก่อน
--
-- ทั้งสองข้อเป็น **กลไกของ planner/catalog ล้วน** ไม่เกี่ยวกับการกระจายตัวของเวกเตอร์
-- เส้นแบ่งที่ได้จาก 8 fault ก่อนหน้าทำนายว่า **ทั้งคู่ควรรอด**
-- ไฟล์นี้ทดสอบคำทำนายนั้น (กฎเหล็กข้อ 1 — ให้การรันจริงเป็นคนตัดสิน)
--
-- I01: สร้าง index ด้วย vector_l2_ops แต่ค้นด้วย <=> (cosine)
--      planner ใช้ index นั้นไม่ได้ -> ช้าเหมือนไม่มี index แต่ recall สมบูรณ์
-- Q02: รูปแบบ query ที่ทำให้ index ใช้ได้ / ใช้ไม่ได้ โดยไม่มี error สักแบบ
--
-- ⚠️ ตรวจการใช้ index จาก **ชื่อ index** ไม่ใช่ค้นคำว่า Index Scan (E25)
-- ⚠️ buffers ต้องรวม hit + read (กฎเหล็กข้อ 7ก)
-- ============================================================
-- 🔴 ไฟล์นี้สร้าง index **บน qf_real โดยตรง** ไม่ได้ทำสำเนา
--    ถ้าถูกตัดกลางคันจะทิ้ง index ค้างบนตารางที่ล็อกไว้ ทำให้ score.sql ·
--    audit.py · quietfail_check.py รายงานผิดไปทั้งชุด (กับดักข้อ 4 · 14ธ)
--    เก็บกวาดด้วยมือ:  DROP INDEX IF EXISTS qf_r_bad;
--    แล้วยืนยันด้วย    python scripts/audit.py
\timing on
\set ON_ERROR_STOP on

SET max_parallel_workers_per_gather = 0;

DROP INDEX IF EXISTS qf_r_bad;
DROP INDEX IF EXISTS qf_r_good;
DROP TABLE IF EXISTS qf_r_i01;
DROP TABLE IF EXISTS qf_r_q02;

CREATE TABLE qf_r_i01 (label text, opclass text, uses_index bool,
                       buffers bigint, got bigint, recall numeric);
CREATE TABLE qf_r_q02 (shape text, uses_index bool, got bigint, buffers bigint);

DO $$
BEGIN
    LOAD 'vector';                                        -- กฎเหล็กข้อ 9
    PERFORM set_config('temp_file_limit', '2GB', false);
END $$;

-- ------------------------------------------------------------
-- ตัววัดร่วม — คืน (ใช้ index ตัวที่ระบุไหม, buffers, จำนวนแถว)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION qf_r_probe(p_sql text, p_idx text)
RETURNS TABLE (uses bool, buf bigint, got bigint)
LANGUAGE plpgsql AS $$
DECLARE j json;
BEGIN
    -- อุ่น cache (กฎเหล็กข้อ 8)
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') w';

    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO j;

    uses := CASE WHEN p_idx = '' THEN NULL ELSE j::text LIKE '%' || p_idx || '%' END;
    buf  := coalesce((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
          + coalesce((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') w' INTO got;
    RETURN NEXT;
END $$;

-- ============================================================
-- ส่วนที่ 1 — I01 opclass ไม่ตรงกับ operator
-- ============================================================
\qecho ''
\qecho '=== I01: opclass ตอนสร้าง vs operator ตอน query ==='

-- ก) ไม่มี index เลย — ค่าฐาน
DO $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY c.embedding <=> '
        '(SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 10', '');
    INSERT INTO qf_r_i01 VALUES ('A ไม่มี index', '-', NULL, r.buf, r.got, 1.0000);
END $$;

-- ข) opclass ผิด: สร้างด้วย l2 แต่ค้นด้วย cosine
CREATE INDEX qf_r_bad ON qf_real USING hnsw (embedding vector_l2_ops);
ANALYZE qf_real;
DO $$
DECLARE r record; rec numeric;
BEGIN
    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY c.embedding <=> '
        '(SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 10', 'qf_r_bad');
    SELECT mean_recall INTO rec FROM qf_real_recall_at(10);
    INSERT INTO qf_r_i01 VALUES ('B opclass ผิด (l2 แต่ค้น cosine)',
                                 'vector_l2_ops', r.uses, r.buf, r.got, rec);
END $$;
DROP INDEX qf_r_bad;

-- ค) opclass ถูก — กลุ่มควบคุม
CREATE INDEX qf_r_good ON qf_real USING hnsw (embedding vector_cosine_ops);
ANALYZE qf_real;
DO $$
DECLARE r record; rec numeric;
BEGIN
    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY c.embedding <=> '
        '(SELECT embedding FROM qf_real_q WHERE id=0) LIMIT 10', 'qf_r_good');
    SELECT mean_recall INTO rec FROM qf_real_recall_at(10);
    INSERT INTO qf_r_i01 VALUES ('C opclass ถูก (กลุ่มควบคุม)',
                                 'vector_cosine_ops', r.uses, r.buf, r.got, rec);
END $$;

SELECT label AS "เงื่อนไข", opclass AS "opclass", uses_index AS "ใช้ index",
       buffers, got AS "ได้", recall AS "recall@10"
FROM qf_r_i01 ORDER BY label;

-- ============================================================
-- ส่วนที่ 2 — Q02 รูปแบบ query (ใช้ index ตัวที่ opclass ถูก)
-- ============================================================
\qecho ''
\qecho '=== Q02: รูปแบบ query แบบไหนใช้ index ได้ (index เดียวกันทุกแถว) ==='

DO $$
DECLARE r record; q text := '(SELECT embedding FROM qf_real_q WHERE id=0)';
BEGIN
    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY c.embedding <=> ' || q || ' LIMIT 10',
        'qf_r_good');
    INSERT INTO qf_r_q02 VALUES ('1. ORDER BY <=> ASC + LIMIT', r.uses, r.got, r.buf);

    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c WHERE c.embedding <=> ' || q || ' < 0.5',
        'qf_r_good');
    INSERT INTO qf_r_q02 VALUES ('2. WHERE <=> < 0.5 อย่างเดียว', r.uses, r.got, r.buf);

    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c WHERE c.embedding <=> ' || q || ' < 0.5 '
        'ORDER BY c.embedding <=> ' || q || ' LIMIT 10', 'qf_r_good');
    INSERT INTO qf_r_q02 VALUES ('3. WHERE + ORDER BY + LIMIT', r.uses, r.got, r.buf);

    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY c.embedding <=> ' || q || ' DESC LIMIT 10',
        'qf_r_good');
    INSERT INTO qf_r_q02 VALUES ('4. ORDER BY <=> DESC', r.uses, r.got, r.buf);

    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY (c.embedding <=> ' || q || ') + 0 LIMIT 10',
        'qf_r_good');
    INSERT INTO qf_r_q02 VALUES ('5. ORDER BY (<=>) + 0', r.uses, r.got, r.buf);

    SELECT * INTO r FROM qf_r_probe(
        'SELECT c.id FROM qf_real c ORDER BY c.embedding <=> ' || q, 'qf_r_good');
    INSERT INTO qf_r_q02 VALUES ('6. ORDER BY ไม่มี LIMIT', r.uses, r.got, r.buf);
END $$;

SELECT shape AS "เขียนแบบ", uses_index AS "ใช้ index", got AS "ได้กี่แถว", buffers
FROM qf_r_q02 ORDER BY shape;

-- ============================================================
-- assertion
-- ============================================================
DO $$
DECLARE b record; c record; n1 bool; n2 bool; n_idx int;
BEGIN
    SELECT * INTO b FROM qf_r_i01 WHERE label LIKE 'B%';
    SELECT * INTO c FROM qf_r_i01 WHERE label LIKE 'C%';

    IF b.uses_index THEN
        RAISE EXCEPTION
            'I01 ข้อ 1 ตก: opclass ผิดแต่ planner ยังใช้ index — fault ไม่เกิด';
    END IF;
    RAISE NOTICE '[I01 1/2] OK opclass ผิด -> planner ไม่ใช้ index (buffers %)', b.buffers;

    IF NOT c.uses_index THEN
        RAISE EXCEPTION 'I01 ข้อ 2 ตก: opclass ถูกแล้วยังไม่ใช้ index — การวัดใช้ไม่ได้';
    END IF;
    RAISE NOTICE '[I01 2/2] OK กลุ่มควบคุมใช้ index (buffers % · recall %)',
        c.buffers, c.recall;

    SELECT uses_index INTO n1 FROM qf_r_q02 WHERE shape LIKE '1.%';
    SELECT uses_index INTO n2 FROM qf_r_q02 WHERE shape LIKE '6.%';
    IF NOT n1 THEN
        RAISE EXCEPTION 'Q02 ข้อ 1 ตก: รูปแบบมาตรฐานไม่ใช้ index — การวัดใช้ไม่ได้';
    END IF;
    RAISE NOTICE '[Q02] รูปแบบที่ใช้ index ได้ % จาก 6 แบบ',
        (SELECT count(*) FROM qf_r_q02 WHERE uses_index);
END $$;

DROP INDEX IF EXISTS qf_r_good;

DO $$
DECLARE n_idx int;
BEGIN
    SELECT count(*) INTO n_idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam WHERE am.amname IN ('hnsw','ivfflat');
    IF n_idx <> 0 THEN
        RAISE EXCEPTION 'มี vector index ค้าง % ตัว (กับดักข้อ 4)', n_idx;
    END IF;
    RAISE NOTICE 'ไม่มี index ค้าง';
END $$;
