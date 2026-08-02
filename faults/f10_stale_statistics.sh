#!/usr/bin/env bash
# =============================================================
# F10 — statistics เก่า ทำให้ planner เลือกผิด
#
# อาการที่เห็น : query เดิม โค้ดเดิม ช้าลงหลายสิบเท่า **ไม่มี error**
# คนมักแก้ผิด  : rewrite query · เพิ่ม index ที่ไม่จำเป็น
# สาเหตุจริง   : สถิติระดับคอลัมน์ไม่ทันข้อมูล planner จึงประมาณจำนวนแถวผิด
#
# ตรรกะทั้งหมดอยู่ใน sql/f10_stale_stats.sql
# ไฟล์นี้ทำแค่ 3 อย่าง: รัน · ตรวจ exit code · เก็บกวาด
#
# ทำไมแยก: F10 ไม่ต้องใช้หลาย session เลย จึงเขียนเป็น SQL ล้วนได้
# และ SQL ล้วนอ่านง่ายกว่า ไม่ต้องสู้กับ quoting ของ bash (บทเรียน E19)
#
# นิยามเต็มอยู่ใน FAULTS.md
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5433}"
DB="${PGDATABASE:-faultlab}"
ADMIN_USER="${ADMIN_USER:-lab}"; ADMIN_PW="${ADMIN_PW:-labpass}"

ROWS="${ROWS:-300000}"

# หลักฐานของ F10 เป็น **ตาราง** เหมือน F03 ไม่ใช่สถานะสดเหมือน F01/F05
# ตัวนับคะแนนจึงรันหลังตัวฉีดจบได้ ไม่ต้องแข่งกับเวลา (บทเรียน E21)
KEEP_OBS="${KEEP_OBS:-0}"

admin() {
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" -qAt "$@"
}

cleanup() {
  echo
  echo "--- เก็บกวาด ---"
  # กวาดตาม **ชื่อขึ้นต้น** ไม่ใช่รายชื่อตายตัว
  # เคยเปลี่ยนชื่อตารางระหว่างพัฒนาแล้วของเก่าค้างอยู่โดยไม่มีใครรู้
  # ตัวเก็บกวาดที่ผูกกับรายชื่อตายตัวจะพลาดทุกครั้งที่ชื่อเปลี่ยน
  local keep="'qf_f10_obs'"
  [[ "$KEEP_OBS" == "1" ]] || keep="''"
  admin -c "
    DO \$\$
    DECLARE t record;
    BEGIN
      FOR t IN SELECT relname FROM pg_class
               WHERE relkind = 'r' AND relname LIKE 'qf\_f10\_%'
                 AND relname <> ${keep}
      LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', t.relname);
      END LOOP;
    END \$\$;" >/dev/null 2>&1
  [[ "$KEEP_OBS" == "1" ]] && echo "   (KEEP_OBS=1 — เก็บ qf_f10_obs ไว้ให้ตัวนับคะแนน)"
  admin -c "DROP FUNCTION IF EXISTS qf_f10_measure(text)" >/dev/null
}
trap cleanup EXIT

echo "=== F10: bulk insert แล้วไม่ ANALYZE (${ROWS} แถว) ==="

# ตรวจก่อนว่าจุดเริ่มต้นสะอาด — ห้ามมีของค้างจากรอบก่อน
LEFTOVER="$(admin -c "
  SELECT count(*) FROM pg_class WHERE relkind='r' AND relname LIKE 'qf\_f10\_%'")"
if [[ "$LEFTOVER" != "0" ]]; then
  echo "!! มีตาราง qf_f10_* ค้างจากรอบก่อน $LEFTOVER ตาราง — กำลังล้าง"
  KEEP_OBS=0 cleanup >/dev/null 2>&1
fi

PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" \
  -v ON_ERROR_STOP=1 -v rows="$ROWS" -f /sql/f10_stale_stats.sql
RC=$?

if (( RC != 0 )); then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ (exit $RC)"
  echo "!! ถ้า assertion ข้อ 1 ตก ให้ตรวจว่า autovacuum แอบมา ANALYZE หรือเปล่า"
  exit 1
fi

echo
echo "=== ข้อสังเกตที่สำคัญกว่าตัวเลขความเร็ว ==="
admin -P border=2 -P format=aligned -c "
SELECT phase,
       buffers,
       round(exec_ms,1) AS ms,
       node_type
FROM qf_f10_obs ORDER BY phase DESC;"

echo
echo "=== นาฬิกาบอกว่าช้าลงไม่กี่เท่า แต่ buffers บอกว่าทำงานเพิ่มหลายร้อยเท่า ==="
echo "=== เพราะข้อมูลชุดนี้อยู่ใน cache หมด — บนเครื่องที่ข้อมูลไม่พอใส่ RAM"
echo "=== buffers ส่วนเกินทั้งหมดนั้นจะกลายเป็นการอ่านดิสก์จริง ==="
echo "=== นี่คือเหตุผลของกฎเหล็กข้อ 7 ==="
