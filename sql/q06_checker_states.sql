-- ============================================================
-- Q06 — พิสูจน์ว่าตัวตรวจ static พลิกได้ตามค่า ef_search
--
-- รัน:  psql ... -v fault=q06 -v ef=40 -f /sql/q06_checker_states.sql
--
-- ⚠️ ต้องเป็นไฟล์ .sql ไม่ใช่ -c ใน bash
--    ลำดับสำคัญ: LOAD 'vector' ก่อน แล้วค่อย SET hnsw.ef_search
--    ถ้า SET มาก่อน LOAD จะได้ unrecognized configuration parameter
--    และการยัด LOAD 'vector' ผ่าน bash -c ทำให้ quote พังมาแล้ว (กฎข้อ 2 · E26)
-- ============================================================

\set ON_ERROR_STOP on

LOAD 'vector';

\if :{?ef}
\else
\set ef 40
\endif

SET hnsw.ef_search = :ef;

\qecho '--- hnsw.ef_search = :ef (LIMIT ที่ประกาศไว้ = 100) ---'
\i /sql/score.sql
