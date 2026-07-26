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
    min_locks int;
    min_chain int;
    rel       text;
    got_locks int;
    got_chain int;
    obs_tbl   text;
    min_err_b numeric; max_err_a numeric; min_buf_r numeric;
    err_b     numeric; err_a     numeric; buf_r     numeric;
    n_f03     int;
    n_f03b    int;
    blk_f03   boolean;
    blk_f03b  boolean;
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

        -- ---- ตัวตรวจของ F05: คิว lock บล็อกคนที่มาทีหลัง ----
        ELSIF fid = 'F05' THEN
            min_locks := (exp ->> 'min_not_granted_locks')::int;
            min_chain := (exp ->> 'min_blocked_chain_depth')::int;
            rel       := exp ->> 'relation';

            IF to_regclass(rel) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หาตาราง %L ไม่เจอ — ตรวจไม่ได้ อย่าถือว่าไม่พบ', rel), NULL);
                CONTINUE;
            END IF;

            EXECUTE format(
                'SELECT count(*) FROM pg_locks WHERE relation = %L::regclass AND NOT granted', rel
            ) INTO got_locks;

            -- ความลึกของห่วงโซ่: นับ session ที่กำลังรอ และตัวที่บล็อกมันก็รออยู่ด้วย
            SELECT count(*) INTO got_chain
            FROM pg_stat_activity a
            WHERE a.datname = current_database()
              AND cardinality(pg_blocking_pids(a.pid)) > 0;

            IF got_locks >= min_locks AND got_chain >= min_chain THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('lock ที่ granted=false %s แถว (ต้อง >= %s) · session ที่ถูกบล็อก %s (ต้อง >= %s)',
                           got_locks, min_locks, got_chain, min_chain),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('lock ที่ granted=false %s แถว (ต้อง >= %s) · session ที่ถูกบล็อก %s (ต้อง >= %s)',
                           got_locks, min_locks, got_chain, min_chain),
                    NULL);
            END IF;

        -- ---- ตัวตรวจของ F03/F03b: ข้อความเดียวกัน แต่ blocker ต่างกัน ----
        --
        -- ต่างจาก F01/F05 ตรงที่ fault นี้เป็น "คู่เปรียบเทียบ"
        -- ตัวตรวจจึงอ่านจากตารางสังเกตการณ์ที่ตัวฉีดเก็บไว้ ไม่ใช่สถานะสดของ DB
        ELSIF fid = 'F03' THEN
            obs_tbl := exp ->> 'observation_table';

            IF to_regclass(obs_tbl) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('ไม่มีตาราง %L — ตัวฉีดยังไม่ได้รัน หรือเก็บกวาดไปแล้ว', obs_tbl), NULL);
                CONTINUE;
            END IF;

            EXECUTE format($f$
                SELECT count(*) FILTER (WHERE tag = 'F03'),
                       count(*) FILTER (WHERE tag = 'F03b'),
                       coalesce(bool_or(cardinality(blockers) > 0) FILTER (WHERE tag = 'F03'),  false),
                       coalesce(bool_or(cardinality(blockers) > 0) FILTER (WHERE tag = 'F03b'), false)
                FROM %I $f$, obs_tbl)
            INTO n_f03, n_f03b, blk_f03, blk_f03b;

            -- กฎเหล็กข้อ 10: ไม่มีตัวอย่าง = ตรวจไม่ได้ ห้ามสรุปว่าไม่มี blocker
            IF n_f03 = 0 OR n_f03b = 0 THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('ตัวอย่างไม่ครบทั้งสองเคส (F03=%s F03b=%s) — ห้ามสรุปอะไร',
                           n_f03, n_f03b), NULL);
            ELSIF blk_f03 AND NOT blk_f03b THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('แยกได้: F03 ถูกบล็อก (%s ตัวอย่าง) · F03b ไม่ถูกบล็อกเลย (%s ตัวอย่าง)',
                           n_f03, n_f03b),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('แยกไม่ได้: F03 blocked=%s · F03b blocked=%s', blk_f03, blk_f03b),
                    NULL);
            END IF;

        -- ---- ตัวตรวจของ F10: planner เดาผิดเพราะสถิติเก่า ----
        -- หลักฐานเป็นตารางเหมือน F03 ไม่ใช่สถานะสด
        ELSIF fid = 'F10' THEN
            obs_tbl   := exp ->> 'observation_table';
            min_err_b := (exp ->> 'min_estimate_error_before')::numeric;
            max_err_a := (exp ->> 'max_estimate_error_after')::numeric;
            min_buf_r := (exp ->> 'min_buffer_reduction')::numeric;

            IF to_regclass(obs_tbl) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('ไม่มีตาราง %L — ตัวฉีดยังไม่ได้รัน หรือเก็บกวาดไปแล้ว', obs_tbl), NULL);
                CONTINUE;
            END IF;

            EXECUTE format($f$
                SELECT
                  (SELECT actual_rows::numeric / greatest(est_rows,1)
                     FROM %I WHERE phase = 'before_analyze'),
                  (SELECT actual_rows::numeric / greatest(est_rows,1)
                     FROM %I WHERE phase = 'after_analyze'),
                  (SELECT b.buffers::numeric / greatest(a.buffers,1)
                     FROM %I b, %I a
                    WHERE b.phase='before_analyze' AND a.phase='after_analyze')
            $f$, obs_tbl, obs_tbl, obs_tbl, obs_tbl)
            INTO err_b, err_a, buf_r;

            IF err_b IS NULL OR err_a IS NULL OR buf_r IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    'ตารางหลักฐานมีไม่ครบทั้งสองเฟส — ห้ามสรุปอะไร', NULL);
            ELSIF err_b >= min_err_b AND err_a <= max_err_a AND buf_r >= min_buf_r THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('ก่อน ANALYZE เดาคลาด %sx (ต้อง >= %s) · หลัง %sx (ต้อง <= %s) · buffers ลด %sx (ต้อง >= %s)',
                           round(err_b,1), min_err_b, round(err_a,1), max_err_a,
                           round(buf_r,1), min_buf_r),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('ก่อน %sx · หลัง %sx · buffers ลด %sx — ไม่ครบเกณฑ์',
                           round(err_b,1), round(err_a,1), round(buf_r,1)), NULL);
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
