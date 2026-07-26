-- ============================================================
-- ตัวเฝ้าดูของ F03 / F03b
--
-- รัน:  psql ... -v secs=6 -f /sql/f03_watcher.sql
--
-- ทำไมต้องเฝ้าจากในฐานข้อมูล ไม่ใช่ยิง psql เป็นรอบๆ จากฝั่ง shell:
--   หน้าต่างเวลาที่ victim ยังมีชีวิตอยู่มีแค่ประมาณ statement_timeout (100ms)
--   การ round-trip ของ psql แต่ละครั้งกินเวลาใกล้เคียงกัน จึงพลาดได้ง่าย
--   ลูปข้างในนี้สุ่มตัวอย่างทุก 5ms โดยไม่มีต้นทุนการเชื่อมต่อ
--
-- ทำไมต้องอยู่เป็นไฟล์ ไม่ฝังใน .sh:
--   เคยฝังแล้วเจอปัญหา quoting ของ bash กับ dollar-quote ของ plpgsql ตีกัน
--   จนตัวเฝ้าดูตายเงียบๆ แล้วสคริปต์รายงานว่า "ไม่มี blocker" (ดู E19)
-- ============================================================

\set ON_ERROR_STOP on

\if :{?secs}
\else
\set secs 6
\endif

-- ส่งค่าเข้า DO block ผ่าน GUC เพราะ psql ไม่แทนค่า :'var' ใน dollar-quote
-- และต้องกลบผลลัพธ์ ไม่งั้นมันพิมพ์เลขออก stdout แล้วตัวตรวจสุขภาพฝั่ง shell
-- เข้าใจผิดว่าตัวเฝ้าดูพัง
\o /dev/null
SELECT set_config('qf.watch_secs', :'secs', false);
\o

DO $$
DECLARE
    deadline timestamptz := clock_timestamp()
                          + (current_setting('qf.watch_secs') || ' seconds')::interval;
    n bigint := 0;
BEGIN
    WHILE clock_timestamp() < deadline LOOP
        -- ⚠️ บรรทัดนี้ขาดไม่ได้ ห้ามลบ
        --
        -- pg_stat_activity ถูก snapshot **ครั้งเดียวต่อ transaction**
        -- DO block ทั้งก้อนคือ transaction เดียว ถ้าไม่ล้าง snapshot
        -- ลูปนี้จะเห็นภาพเดิมซ้ำทุกรอบตลอด 6 วินาที
        -- แล้วรายงานว่า "ไม่มีใครถูกบล็อกเลย" ทั้งที่มี
        --
        -- ตัวเฝ้าดูจะไม่ error ไม่มีคำเตือน แค่เก็บได้ 0 แถว (ดู E19)
        PERFORM pg_stat_clear_snapshot();

        INSERT INTO qf_f03_obs (tag, pid, blockers, state, wait_event)
        SELECT CASE WHEN a.query LIKE '%qf_f03b_victim%' THEN 'F03b' ELSE 'F03' END,
               a.pid,
               pg_blocking_pids(a.pid),
               a.state,
               coalesce(a.wait_event_type || ':' || a.wait_event, '-')
        FROM pg_stat_activity a
        WHERE a.datname = current_database()
          AND a.pid <> pg_backend_pid()
          AND a.state = 'active'
          AND (a.query LIKE '%qf_f03_victim%' OR a.query LIKE '%qf_f03b_victim%');

        GET DIAGNOSTICS n = ROW_COUNT;
        PERFORM pg_sleep(0.005);
    END LOOP;
END $$;
