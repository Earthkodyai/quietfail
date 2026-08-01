-- ============================================================================
-- I05 — ทดสอบแบบจำลองความจุที่อนุมานจากซอร์ส pgvector 0.8.5
-- ============================================================================
-- CLAUDE.md เคยเขียนว่า "มีต้นทุนต่อ element ที่ไม่ขึ้นกับมิติปนอยู่ราว 700–1,000 ไบต์
-- (อนุมานจากการวัด ยังไม่ได้ยืนยันกับซอร์ส — อย่าอ้างในเล่มจนกว่าจะตรวจ)"
--
-- อ่านซอร์สแล้วได้สูตรเต็ม (src/hnswbuild.c · src/hnsw.h v0.8.5)
--
--   งบหน่วยความจำ = (maintenance_work_mem - 3MiB) - 1MiB
--       3MiB  : estother  "Leave space for other objects in shared memory"
--       1MiB  : memoryMargin ของ parallel build (base != NULL)
--
--   ต่อ element  = 674 + MAXALIGN(8 + 4*dim)  ไบต์
--       128 : sizeof(HnswElementData)
--         8 : HnswNeighborArrayPtr[1]
--       520 : HNSW_NEIGHBOR_ARRAY_SIZE(m*2=32) ที่ชั้น 0
--        18 : ชั้นสูงกว่า 0 เฉลี่ย (E[level]=1/15 จาก ml=1/ln(16))
--     8+4d : VARSIZE ของ vector
--
-- 🔴 ทำนายไว้ก่อนรัน (384 มิติ) — mwm 32MB -> 13,236 · mwm 128MB -> 58,617
--    ถ้าผลไม่ตรง แบบจำลองผิด · ถ้าตรง แปลว่าอ่านซอร์สถูก
--
-- ✅ ผลที่ได้จริง — **เก็บคำทำนายข้างบนไว้ตามเดิม** เพราะเป็นหลักฐานว่าทำนายก่อนวัด
--
--      mwm 128MB  ทำนาย 58,617   วัดได้ 58,625   คลาด 8 tuple    ✅ ตรง
--      mwm  32MB  ทำนาย 13,236   วัดได้ 14,902   คลาด 12.6%      ❌ ไม่ตรง
--
--    **ความคลาดที่ 32MB คือสิ่งที่มีค่าที่สุดของการทดลองนี้** — มันพาไปเจอว่า
--    PostgreSQL เลือกเส้นทาง build ให้เอง ผ่าน plan_create_index_workers()
--    ซึ่งบังคับให้ผู้ร่วม build แต่ละคนได้ >= 32MB
--      mwm 32MB -> 32/(0+1+1) = 16MB < 32MB -> worker = 0 -> **serial**
--    เส้นทาง serial ใช้ MemoryContextMemAllocated และ **ไม่หัก 3MiB ไม่มี margin**
--    จึงได้งบเต็ม mwm -> ความจุมากกว่าที่สูตร parallel ทำนาย
--
--    -> สูตรที่ถูกต้องมีสองเส้นทาง
--         parallel : (mwm - 4MiB) / (674 + MAXALIGN(8 + 4*dim))
--         serial   :  mwm เต็ม    / (ค่าเดียวกัน x ~1.015 จาก overhead ของ aset)
--    ทำนายซ้ำด้วยสูตรสองเส้นทาง แล้วตรงทั้ง 5 เงื่อนไข คลาดไม่เกิน 16 tuple
--    (ดู results/i05_capacity_model.txt)
--
--    ⚠️ ข้อความ \echo ข้างล่างยังพิมพ์เลขทำนายเดิม 13,236 อยู่ **โดยตั้งใจ**
--       เพื่อให้ผู้รันเห็นว่าเลขนั้นคือคำทำนายก่อนรู้เรื่องสองเส้นทาง
--
-- ⚠️ NOTICE ออกตอน build ซึ่งอยู่ต้น output — **ห้ามใส่ tail ตัดท้าย**
--    (ความผิดพลาดที่เคยทำจริงตอนวัด 768 มิติ)
-- ============================================================================
\timing off
\set ON_ERROR_STOP on
SET client_min_messages = notice;
LOAD 'vector';

SELECT qf_fingerprint('qf_corpus') AS fp_before \gset

DROP TABLE IF EXISTS qf_i05m;
CREATE TABLE qf_i05m AS SELECT id, embedding FROM qf_corpus;

\echo ''
\echo '=============================================================='
\echo 'A. maintenance_work_mem = 32MB  ->  ทำนายด้วยสูตร parallel 13,236 tuples'
\echo '   (ค่าจริงราว 14,902 เพราะ PostgreSQL เลือก serial ที่ mwm นี้ — ดูหัวไฟล์)'
\echo '=============================================================='
SET maintenance_work_mem = '32MB';
DROP INDEX IF EXISTS qf_i05m_idx;
CREATE INDEX qf_i05m_idx ON qf_i05m USING hnsw (embedding vector_cosine_ops);
DROP INDEX qf_i05m_idx;

\echo ''
\echo '=============================================================='
\echo 'B. maintenance_work_mem = 128MB ->  ทำนาย 58,617 tuples'
\echo '=============================================================='
SET maintenance_work_mem = '128MB';
DROP INDEX IF EXISTS qf_i05m_idx;
CREATE INDEX qf_i05m_idx ON qf_i05m USING hnsw (embedding vector_cosine_ops);
DROP INDEX qf_i05m_idx;

DROP TABLE IF EXISTS qf_i05m;
RESET maintenance_work_mem;

SELECT qf_fingerprint('qf_corpus') AS fp_after \gset
SET quietfail.fp_before = :'fp_before';
SET quietfail.fp_after  = :'fp_after';

DO $$
DECLARE n int;
BEGIN
    IF current_setting('quietfail.fp_before') <> current_setting('quietfail.fp_after') THEN
        RAISE EXCEPTION 'qf_corpus fingerprint เปลี่ยน';
    END IF;
    SELECT count(*) INTO n FROM pg_class c JOIN pg_am a ON a.oid = c.relam
    WHERE a.amname IN ('hnsw','ivfflat');
    IF n <> 0 THEN RAISE EXCEPTION 'มี vector index ค้าง % ตัว', n; END IF;
    RAISE NOTICE 'ผ่าน: fingerprint เดิม · ไม่มี index ค้าง';
END $$;
