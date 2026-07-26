#!/usr/bin/env bash
# =============================================================
# F01 — connection หมด เพราะ transaction ค้าง
#
# อาการที่เห็น : FATAL: sorry, too many clients already
# สิ่งที่คนมักแก้: เพิ่ม max_connections   <-- ผิด
# สาเหตุจริง    : session ที่ BEGIN แล้วไม่ commit/rollback
#
# สคริปต์นี้ทำ 3 อย่าง:
#   1) ฉีด fault ให้เกิดซ้ำได้
#   2) assert ว่าเกิดจริงตามที่ตั้งใจ (ถ้าไม่เกิด = ต้อง fail ไม่ใช่ปล่อยผ่าน)
#   3) พิมพ์ ground truth ออกมาเป็นหลักฐาน
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5433}"
DB="${PGDATABASE:-faultlab}"

ADMIN_USER="${ADMIN_USER:-lab}";  ADMIN_PW="${ADMIN_PW:-labpass}"
APP_USER="${APP_USER:-app}";      APP_PW="${APP_PW:-apppass}"

# max_connections=20, superuser_reserved=3 -> non-superuser ใช้ได้ 17
LEAKS="${LEAKS:-17}"
HOLD="${HOLD:-45}"

EXPECTED_ERROR="too many clients already"

admin() {
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" \
    -v ON_ERROR_STOP=1 -qAt "$@"
}

PIDS=()
cleanup() {
  echo
  echo "--- เก็บกวาด: ปิด session ที่ค้างไว้ ---"
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

echo "=== F01: ฉีด $LEAKS session ที่ค้างสถานะ idle in transaction ==="

for i in $(seq 1 "$LEAKS"); do
  # กลไก: ท่อ stdin ยังเปิดอยู่ระหว่าง sleep
  # psql จึงรอรับคำสั่งถัดไป -> session นั่งนิ่งอยู่ในสถานะ idle in transaction
  # (ห้ามใช้ pg_sleep เพราะนั่นทำให้ state เป็น 'active' ซึ่งคนละเรื่อง)
  ( echo "BEGIN; SELECT 1;"; sleep "$HOLD" ) \
    | PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB" \
        -q -o /dev/null 2>/dev/null &
  PIDS+=($!)
done

sleep 3

echo
echo "--- ลองต่อ connection ใหม่แบบผู้ใช้ธรรมดา (นี่คือสิ่งที่แอปจริงเจอ) ---"
VICTIM_ERR="$(PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" \
                -d "$DB" -c 'SELECT 1' 2>&1 >/dev/null)"
echo "${VICTIM_ERR:-(ต่อสำเร็จ — fault ยังไม่เกิด)}"

# ---------- assertion ----------
if [[ "$VICTIM_ERR" != *"$EXPECTED_ERROR"* ]]; then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ"
  echo "!! คาดว่าจะเจอข้อความ: $EXPECTED_ERROR"
  echo "!! ตรวจ: max_connections ตอนนี้ = $(admin -c 'SHOW max_connections')"
  echo "!! ถ้าค่าสูงกว่า 20 แปลว่ากำลังรันโปรไฟล์ realistic อยู่ ให้เพิ่ม LEAKS"
  exit 1
fi

# ---------- ground truth ----------
echo
echo "=== หลักฐาน: ต้นเหตุจริงอยู่ตรงนี้ ไม่ใช่ที่ max_connections ==="
admin -P border=2 -P format=aligned -c "
SELECT state,
       count(*) AS sessions,
       max(now() - state_change)::interval(0) AS longest_stuck
FROM pg_stat_activity
WHERE datname = current_database() AND usename = '${APP_USER}'
GROUP BY state
ORDER BY sessions DESC;"

echo
echo "=== ถ้าเห็น idle in transaction เป็นก้อนใหญ่ = ยืนยันสาเหตุ ==="
echo "=== วิธีแก้ที่ถูก: ไล่หา code path ที่ลืม commit/rollback ==="
echo "=== แก้บรรเทาชั่วคราวได้ด้วย idle_in_transaction_session_timeout ==="
echo "=== แต่นั่นคือการตัด session ทิ้ง ไม่ใช่การแก้ต้นเหตุ ==="
