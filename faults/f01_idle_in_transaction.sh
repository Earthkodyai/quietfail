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

# ค้าง fault ไว้กี่วินาทีหลัง assert ผ่าน ก่อนเก็บกวาด
# ต้องมีเพราะเฟส 1 แยกเป็น 3 ขั้น: ฉีด -> วินิจฉัย -> นับคะแนน
# ถ้าเก็บกวาดทันที ตัวนับคะแนนที่รันแยกกันจะมาไม่ทัน แล้วรายงานว่า "ไม่พบ"
# ทั้งที่ fault เกิดจริง (false negative — กฎเหล็กข้อ 10)
HOLD_OPEN="${HOLD_OPEN:-0}"

# ข้อความจริงมีสองแบบ ขึ้นกับว่าใครเต็มก่อน — ยืนยันด้วยการรันจริง 2026-07-26 (ดู E13)
#
#   A) superuser_reserved_connections ยังเหลือ แต่โควตาผู้ใช้ธรรมดาเต็ม
#      -> "remaining connection slots are reserved for roles with the SUPERUSER attribute"
#      นี่คือสิ่งที่ **แอปจริงเจอ** เพราะแอปต่อด้วย role ธรรมดา
#
#   B) เต็มหมดจริงๆ รวม slot สำรอง
#      -> "too many clients already"
#
# เดิมสคริปต์นี้ assert เฉพาะ (B) ซึ่งไม่มีวันเกิดกับ role ธรรมดา
# บนโปรไฟล์ fragile (max_connections=20, superuser_reserved=3)
#
# ทั้งสองข้อความชี้ไปที่ "โควตา connection" เหมือนกัน และผิดทางเหมือนกัน
# ต้นเหตุจริงคือ transaction ที่ไม่ถูกปิด
#
# หมายเหตุ: ข้อความพวกนี้เสถียรได้เพราะ config ล็อก lc_messages = 'C'
#          และ image tag ล็อกที่ 0.8.5-pg17 — ถ้าเปลี่ยนอย่างใดอย่างหนึ่ง ต้องรันยืนยันใหม่
EXPECTED_RE="remaining connection slots are reserved|too many clients already"

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
if ! grep -Eq "$EXPECTED_RE" <<< "$VICTIM_ERR"; then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ"
  echo "!! คาดว่าจะเจอข้อความที่ตรงกับ: $EXPECTED_RE"
  echo "!! ตรวจ: max_connections ตอนนี้ = $(admin -c 'SHOW max_connections')"
  echo "!! ถ้าค่าสูงกว่า 20 แปลว่ากำลังรันโปรไฟล์ realistic อยู่ ให้เพิ่ม LEAKS"
  exit 1
fi

# บันทึกว่าเจอแบบไหน เพราะสองแบบมีความหมายต่างกัน (ดู E13)
if grep -q "remaining connection slots are reserved" <<< "$VICTIM_ERR"; then
  echo ">> รูปแบบ A: โควตาผู้ใช้ธรรมดาเต็ม slot สำรองของ superuser ยังเหลือ"
else
  echo ">> รูปแบบ B: เต็มหมดรวม slot สำรอง"
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

if (( HOLD_OPEN > 0 )); then
  if (( HOLD_OPEN + 5 > HOLD )); then
    echo
    echo "!! HOLD_OPEN=$HOLD_OPEN ยาวเกิน HOLD=$HOLD"
    echo "!! session ที่ฉีดไว้จะตายก่อนตัวนับคะแนนมาถึง ตั้ง HOLD ให้ >= HOLD_OPEN+5"
    exit 1
  fi
  echo
  echo "=== ค้าง fault ไว้ $HOLD_OPEN วินาที ให้ตัวนับคะแนนมาตรวจ ==="
  sleep "$HOLD_OPEN"
fi

echo
echo "=== ถ้าเห็น idle in transaction เป็นก้อนใหญ่ = ยืนยันสาเหตุ ==="
echo "=== วิธีแก้ที่ถูก: ไล่หา code path ที่ลืม commit/rollback ==="
echo "=== แก้บรรเทาชั่วคราวได้ด้วย idle_in_transaction_session_timeout ==="
echo "=== แต่นั่นคือการตัด session ทิ้ง ไม่ใช่การแก้ต้นเหตุ ==="
