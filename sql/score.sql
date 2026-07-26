-- ============================================================
-- ตัวนับคะแนน — เกณฑ์ผ่านเฟส 1 ข้อสุดท้าย (PROJECT.md ข้อ 9)
--
-- ตอบ RQ2: "ความผิดพลาดเหล่านี้ตรวจจับอัตโนมัติได้กี่ข้อ และจากหลักฐานอะไร"
--
-- รัน:  psql ... -v fault=f01 -f /sql/score.sql
--       ไม่ใส่ -v fault จะไล่ทุกไฟล์ใน /groundtruth
--
-- วิธีทำงาน:
--   1. อ่านไฟล์เฉลยด้วย pg_read_file() แล้ว parse เป็น json ใน postgres
--      (ไม่ต้องพึ่ง jq ซึ่งไม่มีใน image นี้)
--   2. รัน evidence_query ที่เขียนไว้ในเฉลย
--   3. เทียบผลกับ evidence_expectation
--   4. รายงาน 3 สถานะ ไม่ใช่ 2
--
-- ⚠️ กฎเหล็กข้อ 10: ต้องมีสถานะ "ตรวจไม่ได้" แยกจาก "ไม่พบ"
--    เครื่องมือที่บอกว่า "ปลอดภัย" ทั้งที่ไม่ได้ดูอะไรเลย อันตรายกว่าไม่มีเครื่องมือ
-- ============================================================

\set ON_ERROR_STOP on

LOAD 'vector';

\if :{?fault}
\else
\set fault 'ALL'
\endif

SELECT set_config('qf.fault', :'fault', false);

CREATE TEMP TABLE score_result (
    fault_id     text,
    verdict      text,     -- DETECTED / NOT_DETECTED / CANNOT_CHECK
    detail       text,
    evidence     text
);

DO $$
DECLARE
    want      text := current_setting('qf.fault');
    f         record;
    doc       json;
    fid       text;
    q         text;
    exp       json;
    min_sess  int;
    min_secs  int;
    got_sess  int;
    got_secs  numeric;
BEGIN
    FOR f IN
        SELECT name FROM pg_ls_dir('/groundtruth') AS name
        WHERE name LIKE '%.json'
          AND (want = 'ALL' OR name = want || '.json')
        ORDER BY name
    LOOP
        BEGIN
            doc := pg_read_file('/groundtruth/' || f.name)::json;
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO score_result VALUES
                (f.name, 'CANNOT_CHECK', 'อ่านหรือ parse ไฟล์เฉลยไม่ได้: ' || SQLERRM, NULL);
            CONTINUE;
        END;

        fid := doc ->> 'fault_id';
        q   := doc ->> 'evidence_query';
        exp := doc -> 'evidence_expectation';

        -- กฎข้อ 10: ไม่มีสิ่งที่ควรมี = ตรวจไม่ได้ ห้ามนับเป็นผ่านหรือไม่พบ
        IF q IS NULL OR exp IS NULL THEN
            INSERT INTO score_result VALUES
                (COALESCE(fid, f.name), 'CANNOT_CHECK',
                 'เฉลยไม่มี evidence_query หรือ evidence_expectation', NULL);
            CONTINUE;
        END IF;

        IF (doc #>> '{verified_on,date}') IS NULL THEN
            INSERT INTO score_result VALUES
                (fid, 'CANNOT_CHECK',
                 'เฉลยยังไม่ถูกยืนยันด้วยการรันจริง (verified_on.date ว่าง)', NULL);
            CONTINUE;
        END IF;

        -- ---- ตัวตรวจของ F01: นับ session ที่ค้างใน idle in transaction ----
        IF fid = 'F01' THEN
            min_sess := (exp ->> 'min_idle_in_transaction_sessions')::int;
            min_secs := (exp ->> 'min_stuck_seconds')::int;

            SELECT count(*),
                   COALESCE(max(extract(epoch FROM now() - state_change)), 0)
              INTO got_sess, got_secs
            FROM pg_stat_activity
            WHERE state = 'idle in transaction'
              AND datname = current_database();

            IF got_sess >= min_sess AND got_secs >= min_secs THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('idle in transaction %s session (ต้อง >= %s) · ค้างนานสุด %s วิ (ต้อง >= %s)',
                           got_sess, min_sess, round(got_secs,1), min_secs),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('idle in transaction %s session (ต้อง >= %s) · ค้างนานสุด %s วิ (ต้อง >= %s)',
                           got_sess, min_sess, round(got_secs,1), min_secs),
                    NULL);
            END IF;

        ELSE
            -- ยังไม่มีตัวตรวจสำหรับ fault นี้ -> ตรวจไม่ได้ ไม่ใช่ผ่าน
            INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                'ยังไม่ได้เขียนตัวตรวจสำหรับ fault นี้ใน score.sql', NULL);
        END IF;
    END LOOP;
END $$;

\qecho
\qecho ============================================================
\qecho ผลการนับคะแนน
\qecho ============================================================

SELECT fault_id, verdict, detail FROM score_result ORDER BY fault_id;

\qecho
\qecho --- สรุป ---
SELECT
    count(*) FILTER (WHERE verdict = 'DETECTED')     AS detected,
    count(*) FILTER (WHERE verdict = 'NOT_DETECTED') AS not_detected,
    count(*) FILTER (WHERE verdict = 'CANNOT_CHECK') AS cannot_check,
    count(*)                                          AS total
FROM score_result;

\qecho
\qecho หมายเหตุ: cannot_check ไม่ใช่ผ่าน และไม่ใช่ไม่พบ (กฎเหล็กข้อ 10)
