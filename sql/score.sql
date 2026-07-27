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

-- ต้องลบก่อนสร้าง ไม่งั้นเรียกซ้ำในเซสชันเดียวจะได้
-- ERROR: relation "score_result" already exists แล้วสคริปต์ที่เรียกมันตายกลางคัน
DROP TABLE IF EXISTS score_result;
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
    want_opc  text;
    n_idx_total int;
    n_idx_bad   int;
    cal_dim   int;
    tuples_mb int;
    n_rows    bigint;
    got_dim   int;
    mwm_mb    bigint;
    capacity  bigint;
    n_share   int;
    n_waiting int;
    guc_name  text;
    max_limit int;
    ef_now    int;
    n_guc     int;
    n_null_vec int;
    n_zero_vec int;
    n_no_order int;
    n_desc     int;
    n_vec_q    int;
    n_lists    int;
    probes_now int;
    probes_rec int;
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

        -- ---- ตัวตรวจของ I01: static ล้วน อ่าน catalog อย่างเดียว ----
        --
        -- ต่างจาก F01/F03/F05 ตรงที่ **ไม่ต้องมีข้อมูล ไม่ต้องรัน query เลย**
        -- นี่คือกลุ่ม "ยืนยันได้ -> fail build ทันที" ตาม PROJECT.md ข้อ 8
        ELSIF fid = 'I01' THEN
            rel      := exp ->> 'target_table';
            want_opc := exp ->> 'required_opclass';

            IF to_regclass(rel) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หาตาราง %L ไม่เจอ', rel), NULL);
                CONTINUE;
            END IF;

            -- กฎเหล็กข้อ 10: ไม่มี vector index เลย = ตรวจไม่ได้ ไม่ใช่ "ไม่พบ fault"
            -- เพราะโค้ดที่ตั้งใจใช้ ANN แต่ยังไม่มี index ก็เป็นปัญหาคนละแบบ
            SELECT count(*), count(*) FILTER (WHERE opc <> want_opc)
              INTO n_idx_total, n_idx_bad
            FROM (
                SELECT opcl.opcname AS opc
                FROM pg_index i
                JOIN pg_class c    ON c.oid = i.indexrelid
                JOIN pg_class t    ON t.oid = i.indrelid
                JOIN pg_am am      ON am.oid = c.relam
                JOIN pg_opclass opcl ON opcl.oid = i.indclass[0]
                WHERE t.relname = rel AND am.amname IN ('hnsw','ivfflat')
            ) z;

            IF n_idx_total = 0 THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('ไม่มี vector index บน %L เลย — ตรวจ opclass ไม่ได้', rel), NULL);
            ELSIF n_idx_bad > 0 THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('มี vector index %s ตัวบน %s · opclass ไม่ตรงกับ operator %s ที่โค้ดใช้ %s ตัว (ต้องเป็น %s)',
                           n_idx_total, rel, doc ->> 'declared_query_operator', n_idx_bad, want_opc),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('vector index ทั้ง %s ตัวบน %s ใช้ opclass %s ถูกต้อง',
                           n_idx_total, rel, want_opc), NULL);
            END IF;

        -- ---- ตัวตรวจของ I05: ทำนายล่วงหน้าว่า build จะ spill ไหม ----
        --
        -- ใช้ค่าความจุที่ **วัดเอง** ไม่ใช่สูตรจากเอกสาร (กฎเหล็กข้อ 2)
        --   28,359 tuples / 64MB  = 443 tuples/MB
        --   58,626 tuples / 128MB = 458 tuples/MB
        -- ใช้ค่าต่ำ 443 เพื่อให้เตือนเร็วกว่าจริงเล็กน้อย
        --
        -- ⚠️ ค่านี้ calibrate ที่ **384 มิติเท่านั้น**
        --    มิติอื่นต้องวัดใหม่ — ถ้าเจอมิติอื่นต้องตอบว่า "ตรวจไม่ได้" ไม่ใช่เดา
        ELSIF fid = 'I05' THEN
            rel        := exp ->> 'target_table';
            cal_dim    := (exp ->> 'calibrated_dim')::int;
            tuples_mb  := (exp ->> 'tuples_per_mb')::int;

            IF to_regclass(rel) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หาตาราง %L ไม่เจอ', rel), NULL);
                CONTINUE;
            END IF;

            EXECUTE format('SELECT count(*), max(vector_dims(%I)) FROM %I',
                           exp ->> 'vector_column', rel)
            INTO n_rows, got_dim;

            -- กฎเหล็กข้อ 10: มิติไม่ตรงกับที่ calibrate ไว้ = ตรวจไม่ได้ ห้ามเดา
            IF got_dim IS DISTINCT FROM cal_dim THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('ตาราง %s มิติ %s แต่ค่าความจุ calibrate ไว้ที่ %s มิติเท่านั้น '
                           '— ต้องวัดใหม่ก่อนถึงจะตรวจได้', rel, got_dim, cal_dim), NULL);
                CONTINUE;
            END IF;

            mwm_mb   := pg_size_bytes(current_setting('maintenance_work_mem')) / 1024 / 1024;
            capacity := mwm_mb * tuples_mb;

            IF n_rows > capacity THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('maintenance_work_mem = %s MB รับได้ประมาณ %s tuples '
                           'แต่ตารางมี %s แถว → build จะ spill และช้าลงราว 3 เท่า',
                           mwm_mb, capacity, n_rows),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('maintenance_work_mem = %s MB รับได้ประมาณ %s tuples · ตารางมี %s แถว',
                           mwm_mb, capacity, n_rows), NULL);
            END IF;

        -- ---- ตัวตรวจของ I03: ShareLock ของ build กับการเขียนที่รออยู่ ----
        --
        -- หลักฐานเป็น **สถานะสดของ DB** เหมือน F05 → ต้องวัดระหว่าง fault ค้าง
        -- ต่างจาก I01/I05 ที่อ่าน catalog เมื่อไหร่ก็ได้ (ดูตารางชนิดหลักฐานใน CLAUDE.md)
        ELSIF fid = 'I03' THEN
            rel := exp ->> 'target_table';

            IF to_regclass(rel) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หาตาราง %L ไม่เจอ', rel), NULL);
                CONTINUE;
            END IF;

            EXECUTE format(
                'SELECT count(*) FILTER (WHERE mode = %L AND granted), '
                '       count(*) FILTER (WHERE mode = %L AND NOT granted) '
                'FROM pg_locks WHERE relation = %L::regclass',
                exp ->> 'blocking_mode', exp ->> 'blocked_mode', rel)
            INTO n_share, n_waiting;

            IF n_share >= (exp ->> 'min_granted_share_locks')::int
               AND n_waiting >= (exp ->> 'min_waiting_writes')::int THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('%s ที่ได้รับแล้ว %s แถวบน %s · การเขียนรออยู่ %s แถว '
                           '→ build กำลังบล็อกการเขียน',
                           exp ->> 'blocking_mode', n_share, rel, n_waiting),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('%s ที่ได้รับแล้ว %s แถว · การเขียนที่รออยู่ %s แถว (ต้อง >= %s และ >= %s)',
                           exp ->> 'blocking_mode', n_share, n_waiting,
                           exp ->> 'min_granted_share_locks', exp ->> 'min_waiting_writes'),
                    NULL);
            END IF;

        -- ---- ตัวตรวจของ Q06: ef_search เทียบกับ LIMIT ที่โค้ดใช้ ----
        --
        -- static ล้วน ไม่ต้องมีข้อมูล ไม่ต้องรัน query
        -- ⚠️ ต้อง LOAD 'vector' ก่อน ไม่งั้น GUC ไม่โผล่แล้วรายงานว่าผ่าน
        --    ทั้งที่ไม่ได้ตรวจ (กฎเหล็กข้อ 9 · D12) — script โหลดไว้ที่หัวไฟล์แล้ว
        ELSIF fid = 'Q06' THEN
            guc_name  := exp ->> 'guc';
            max_limit := (exp ->> 'declared_max_limit')::int;

            SELECT count(*) INTO n_guc FROM pg_settings WHERE name = guc_name;
            IF n_guc = 0 THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หา GUC %L ไม่เจอ — LOAD ''vector'' แล้วหรือยัง', guc_name), NULL);
                CONTINUE;
            END IF;

            ef_now := current_setting(guc_name)::int;

            IF ef_now < max_limit THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('%s = %s แต่โค้ดใช้ LIMIT ได้ถึง %s → คืนผลได้ไม่เกิน %s แถว ขาดไป %s',
                           guc_name, ef_now, max_limit, ef_now, max_limit - ef_now),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('%s = %s ครอบคลุม LIMIT สูงสุดที่ประกาศไว้ (%s)',
                           guc_name, ef_now, max_limit), NULL);
            END IF;

        -- ---- ตัวตรวจของ V07: นับแถวที่ vector เป็น NULL หรือ norm = 0 ----
        --
        -- ตรวจง่ายที่สุดในบรรดา fault ทั้ง 16 ข้อ
        -- ไม่ต้องรัน query ค้นหา ไม่ต้องมี index ไม่ต้องมีเฉลย
        ELSIF fid = 'V07' THEN
            rel := exp ->> 'target_table';

            IF to_regclass(rel) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หาตาราง %L ไม่เจอ — ตัวฉีดยังไม่ได้รัน', rel), NULL);
                CONTINUE;
            END IF;

            EXECUTE format(
                'SELECT count(*) FILTER (WHERE %1$I IS NULL), '
                '       count(*) FILTER (WHERE %1$I IS NOT NULL AND vector_norm(%1$I) = 0), '
                '       count(*) FROM %2$I',
                exp ->> 'vector_column', rel)
            INTO n_null_vec, n_zero_vec, n_rows;

            IF n_null_vec + n_zero_vec > 0 THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('ตาราง %s มี %s แถว · NULL vector %s แถว · zero vector %s แถว '
                           '→ %s แถวนี้จะไม่โผล่ในผลค้นหาที่ใช้ index เลย',
                           rel, n_rows, n_null_vec, n_zero_vec, n_null_vec + n_zero_vec),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('ตาราง %s มี %s แถว · ไม่มี NULL หรือ zero vector เลย', rel, n_rows),
                    NULL);
            END IF;

        -- ---- ตัวตรวจของ Q02: อ่าน query ที่ระบบเคยรันจริงจาก pg_stat_statements ----
        --
        -- หลักฐานชนิดใหม่ในโปรเจค: **query ที่ถูกบันทึกไว้** ไม่ใช่ catalog และไม่ใช่สถานะสด
        -- ตรวจได้โดยไม่ต้องเข้าถึงซอร์สโค้ดของแอป
        --
        -- ⚠️ ตรวจได้แค่ชั้น "ขาด ORDER BY หรือ LIMIT" กับ "เรียง DESC"
        --    รูปแบบที่ห่อ operator ด้วยนิพจน์ (เช่น + 0) ตรวจจากข้อความไม่ได้
        --    ต้องดู plan → ระบุข้อจำกัดนี้ไว้ตรงๆ ห้ามอ้างว่าครอบคลุมทุกแบบ
        ELSIF fid = 'Q02' THEN
            IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    'ไม่มี extension pg_stat_statements — ตรวจ query ที่เคยรันไม่ได้', NULL);
                CONTINUE;
            END IF;

            SELECT
                -- ⚠️ ต้องมีวงเล็บครอบ NOT ทั้งก้อน
                --    เขียน "A AND B IS NOT TRUE" จะ parse เป็น "A AND (B IS NOT TRUE)"
                --    ซึ่งนับกลับหัว แล้วตัวตรวจตอบ NOT_DETECTED ในสถานะที่ควร DETECTED
                count(*) FILTER (WHERE NOT (qtext ILIKE '%order by%'
                                            AND qtext ILIKE '%limit%')),
                count(*) FILTER (WHERE qtext ~* 'order by[^;]*<[=#-]>[^;]*desc'),
                count(*)
              INTO n_no_order, n_desc, n_vec_q
            FROM (
                -- ⚠️ ห้ามตั้งชื่อ alias ว่า q — ชนกับตัวแปร plpgsql ชื่อ q ที่ประกาศไว้ข้างบน
                --    PostgreSQL จะตอบ "column reference q is ambiguous"
                SELECT query AS qtext FROM pg_stat_statements
                WHERE query ~* '<[=#-]>'
                  AND query ILIKE 'select%'
                  AND query NOT ILIKE '%pg_stat_statements%'
                  AND query NOT ILIKE '%pg_locks%'
            ) z;

            IF n_vec_q = 0 THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    'ไม่พบ query ที่ใช้ vector operator ใน pg_stat_statements — ยังไม่มีอะไรให้ตรวจ',
                    NULL);
            ELSIF n_no_order + n_desc > 0 THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('จาก %s query ที่ใช้ vector operator · ขาด ORDER BY หรือ LIMIT %s · เรียง DESC %s '
                           '→ index ใช้ไม่ได้ (ตรวจ ORDER BY ที่ห่อด้วยนิพจน์ไม่ได้ ต้องดู plan)',
                           n_vec_q, n_no_order, n_desc),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('query ที่ใช้ vector operator ทั้ง %s ตัว มี ORDER BY + LIMIT ครบ และไม่ได้เรียง DESC',
                           n_vec_q), NULL);
            END IF;

        -- ---- ตัวตรวจของ Q04: probes เทียบกับ sqrt(lists) ที่อ่านจาก catalog ----
        --
        -- static ล้วน — อ่าน lists จาก reloptions ของ ivfflat index ที่มีอยู่จริง
        -- ไม่ต้องเดาว่าใครตั้ง lists เท่าไหร่ ไม่ต้องรัน query
        ELSIF fid = 'Q04' THEN
            rel := exp ->> 'target_table';

            IF to_regclass(rel) IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('หาตาราง %L ไม่เจอ', rel), NULL);
                CONTINUE;
            END IF;

            SELECT max((regexp_match(array_to_string(c.reloptions, ','), 'lists=([0-9]+)'))[1]::int)
              INTO n_lists
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_class t ON t.oid = i.indrelid
            JOIN pg_am am   ON am.oid = c.relam
            WHERE t.relname = rel AND am.amname = 'ivfflat';

            -- กฎเหล็กข้อ 10: ไม่มี ivfflat index = ตรวจสูตรนี้ไม่ได้ ไม่ใช่ "ผ่าน"
            IF n_lists IS NULL THEN
                INSERT INTO score_result VALUES (fid, 'CANNOT_CHECK',
                    format('ไม่มี ivfflat index บน %s ที่ระบุ lists — เทียบกับ sqrt(lists) ไม่ได้', rel),
                    NULL);
                CONTINUE;
            END IF;

            probes_now := current_setting('ivfflat.probes')::int;
            probes_rec := ceil(sqrt(n_lists))::int;

            IF probes_now < probes_rec THEN
                INSERT INTO score_result VALUES (fid, 'DETECTED',
                    format('ivfflat.probes = %s แต่ index ตั้ง lists = %s → เอกสารแนะนำ sqrt(lists) = %s '
                           '· ต่ำกว่าคำแนะนำ %s เท่า',
                           probes_now, n_lists, probes_rec, round(probes_rec::numeric / probes_now, 1)),
                    doc ->> 'correct_diagnosis');
            ELSE
                INSERT INTO score_result VALUES (fid, 'NOT_DETECTED',
                    format('ivfflat.probes = %s >= sqrt(lists) = %s (lists = %s)',
                           probes_now, probes_rec, n_lists), NULL);
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
