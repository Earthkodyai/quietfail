#!/usr/bin/env bash
# =============================================================
# F05 — อ่านข้อมูลก็ค้าง เพราะ migration ที่ยังไม่ได้เริ่ม
#
# อาการที่เห็น : SELECT ธรรมดา timeout ทั้งที่ query เบามาก
# คนมักแก้ผิด  : โทษ network / โทษ DB ช้า / restart แอป
# สาเหตุจริง   : ALTER TABLE รออยู่ในคิว lock
#                แล้ว **คิวบล็อกทุกคนที่มาทีหลัง**
#
# จุดที่หลอกที่สุด: ALTER TABLE ยังไม่ได้เริ่มทำงานเลย มันแค่รอ
# แต่การรอของมันทำให้ SELECT ที่ควรเสร็จใน 1ms ค้างไปด้วย
#
#   session A:  BEGIN; SELECT * FROM orders LIMIT 1;   (ค้างไว้ ไม่ commit)
#   session B:  ALTER TABLE orders ADD COLUMN tmp int; (รอ A)
#   session C:  SELECT * FROM orders LIMIT 1;          (ค้าง! ทั้งที่ควรได้ทันที)
#
# นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5433}"
DB="${PGDATABASE:-faultlab}"

ADMIN_USER="${ADMIN_USER:-lab}";  ADMIN_PW="${ADMIN_PW:-labpass}"
APP_USER="${APP_USER:-app}";      APP_PW="${APP_PW:-apppass}"

TABLE="${TABLE:-orders}"
TMP_COL="${TMP_COL:-qf_f05_tmp}"

# C ต้องค้างนานกว่านี้ถึงจะนับว่า fault เกิด (ปกติ query นี้เสร็จใน < 10ms)
MIN_BLOCK_SECS="${MIN_BLOCK_SECS:-2}"

# C รอจริงกี่วินาทีก่อนเรายอมแพ้แล้วไปวัด
C_WAIT="${C_WAIT:-6}"

# ค้าง fault ไว้กี่วินาทีหลัง assert ผ่าน ให้ตัวนับคะแนนที่รันแยกขั้นมาทัน
# บทเรียนจาก E14 — ถ้าเก็บกวาดทันที ตัวนับจะรายงาน "ไม่พบ" ทั้งที่ fault เกิดจริง
HOLD_OPEN="${HOLD_OPEN:-0}"

admin() {
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" \
    -v ON_ERROR_STOP=1 -qAt "$@"
}

A_PID=""; B_PID=""; C_PID=""
C_TIME_FILE="$(mktemp)"

# 🔴 เดิม session A/B/C ทิ้ง stderr ด้วย 2>/dev/null ทั้งสามตัว
#    ตัวที่สำคัญคือ **B ซึ่งรัน ALTER TABLE** — เป็นคำสั่งเปลี่ยนสภาพระบบ
#    ถ้ามันล้ม (สิทธิ์ไม่พอ · คอลัมน์ค้างจากรอบก่อน) จะเงียบสนิท แล้ว assertion
#    รายงานว่า "fault ไม่เกิด" โดยไม่บอกสาเหตุ = กับดักข้อ 1
#    ตอนนี้เก็บลงไฟล์แล้วโชว์เมื่อ assertion ตก (แก้ 2026-08-02)
A_ERR="$(mktemp)"; B_ERR="$(mktemp)"; C_ERR="$(mktemp)"

cleanup() {
  echo
  echo "--- เก็บกวาด ---"

  # ⚠️ ต้องยกเลิก ALTER ที่ฝั่ง **server** ก่อน ไม่ใช่แค่ฆ่า process ฝั่ง client
  #
  # เคยพลาดมาแล้ว: kill psql ฝั่ง client ไม่ได้ยกเลิก query ที่ค้างในคิว
  # พอ A ตาย B ได้ lock แล้วรัน ALTER สำเร็จ = แก้ schema จริงโดยไม่ตั้งใจ
  # (รอบแรกโดนจริง ตาข่าย DROP COLUMN ข้างล่างรับไว้ทัน — ดู E15)
  # ⚠️ ต้องเล็งเฉพาะ leader (backend_type = 'client backend') และใช้ cancel ก่อน
  #    ห้ามแตะ parallel worker — ฆ่า worker ทำให้ leader ตาย exit 2 แล้ว
  #    postmaster ถือว่า crash แล้วรีเซ็ตทั้งคลัสเตอร์ (E29 · กับดักข้อ 3ก)
  #
  #    🔴 ไฟล์นี้เคยไม่มีทั้งสองอย่าง — เจอตอนทวน faults/ เมื่อ 2026-08-01
  #    ความเสี่ยงจริงต่ำ เพราะ ALTER TABLE ADD COLUMN ไม่ใช้ parallel worker
  #    แต่ `pg_stat_activity.query` ของ worker เหมือน leader ทุกตัวอักษร
  #    ตัวกรองด้วย query จึงไม่ปลอดภัยโดยตัวมันเอง — และ i03_*.sh แก้ไปแล้ว
  #    ตั้งแต่ E29 โดยไม่มีใครย้อนมาดูไฟล์นี้ (ตรงกับกับดักข้อ 9 พอดี)
  admin -c "
    SELECT pg_cancel_backend(pid)
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND backend_type = 'client backend'
      AND query ILIKE 'ALTER TABLE ${TABLE} ADD COLUMN ${TMP_COL}%'
      AND pid <> pg_backend_pid()" >/dev/null 2>&1
  sleep 1
  # ถ้า cancel ไม่พอ (ยังค้างอยู่) จึงค่อย terminate — ยังคงเล็งเฉพาะ leader
  admin -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND backend_type = 'client backend'
      AND query ILIKE 'ALTER TABLE ${TABLE} ADD COLUMN ${TMP_COL}%'
      AND pid <> pg_backend_pid()" >/dev/null 2>&1

  # ลำดับสำคัญ: B ก่อน A เสมอ
  for p in "$B_PID" "$C_PID" "$A_PID"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  wait 2>/dev/null

  # กันเหนียว: ถ้า B แอบทำสำเร็จ ให้ถอนออก
  local leftover
  leftover="$(admin -c "SELECT count(*) FROM information_schema.columns
                        WHERE table_name='${TABLE}' AND column_name='${TMP_COL}'" 2>/dev/null || echo 0)"
  if [[ "$leftover" != "0" ]]; then
    echo "!! คอลัมน์ ${TMP_COL} ถูกเพิ่มจริง กำลังถอนออก"
    # 🔴 ห้ามกลบ stderr — นี่คือตาข่ายที่ถอนคอลัมน์ที่ถูกเพิ่มโดยไม่ตั้งใจ (E15)
    #    ถ้ามันล้มแล้วเงียบ schema จะเปลี่ยนถาวรโดยไม่มีใครรู้ (กับดักข้อ 1)
    admin -c "ALTER TABLE ${TABLE} DROP COLUMN IF EXISTS ${TMP_COL}" >/dev/null
  fi

  rm -f "$C_TIME_FILE" "$A_ERR" "$B_ERR" "$C_ERR"
}
trap cleanup EXIT

echo "=== F05: สร้างคิว lock บนตาราง ${TABLE} ==="

# ---------- ตรวจก่อนว่าจุดเริ่มต้นสะอาด ----------
PRE_BLOCKED="$(admin -c "
  SELECT count(*) FROM pg_locks l
  WHERE l.relation = '${TABLE}'::regclass AND NOT l.granted")"
if [[ "$PRE_BLOCKED" != "0" ]]; then
  echo "!! จุดเริ่มต้นไม่สะอาด: มี lock ที่ยังไม่ได้รับอยู่แล้ว $PRE_BLOCKED แถว"
  echo "!! รันซ้ำจากรอบก่อนค้างอยู่หรือเปล่า"
  exit 1
fi

# ---------- session A: ถือ ACCESS SHARE ไว้ ----------
echo "-- A: BEGIN แล้ว SELECT ค้างไว้ (ถือ ACCESS SHARE)"
( echo "BEGIN; SELECT * FROM ${TABLE} LIMIT 1;"; sleep 120 ) \
  | PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB" \
      -q -o /dev/null 2>"$A_ERR" &
A_PID=$!
sleep 2

# ---------- session B: ALTER TABLE ต้องรอ A ----------
#
# ⚠️ B ต้องรันด้วย role **เจ้าของตาราง** (lab) ไม่ใช่ app
#    ไม่งั้นได้ `ERROR: must be owner of table orders` ทันที
#    แล้ว B ตายก่อนเข้าคิว → fault ไม่มีวันเกิด (ดู E15)
#
#    นี่ไม่ใช่การหลบเลี่ยง แต่เป็นแบบจำลองที่ตรงกับของจริง:
#    migration รันด้วย role ที่มีสิทธิ์ ส่วนแอปรันด้วย role จำกัดสิทธิ์
#    fault จึงเกิดจาก **สอง role คนละตัวชนกัน** ซึ่งเป็นเหตุผลว่าทำไม
#    ทีมแอปกับทีม DB มักโทษกันไปมาแทนที่จะเห็นคิว lock
echo "-- B: ALTER TABLE ADD COLUMN โดย role เจ้าของ (ต้องการ ACCESS EXCLUSIVE จึงต้องรอ A)"
PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" \
  -q -o /dev/null -c "ALTER TABLE ${TABLE} ADD COLUMN ${TMP_COL} int" 2>"$B_ERR" &
B_PID=$!
sleep 2

# ---------- session C: SELECT ธรรมดา ที่ควรเสร็จทันที ----------
echo "-- C: SELECT ธรรมดา — นี่คือ query ที่แอปจริงยิงทุกวินาที"
(
  start=$(date +%s.%N)
  PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB" \
    -q -o /dev/null -c "SELECT * FROM ${TABLE} LIMIT 1" 2>"$C_ERR"
  end=$(date +%s.%N)
  echo "$start $end" > "$C_TIME_FILE"
) &
C_PID=$!

echo "-- รอ ${C_WAIT} วินาที แล้วไปดูว่า C ยังค้างอยู่ไหม"
sleep "$C_WAIT"

# =============================================================
# assertion — กฎเหล็กข้อ 3
# =============================================================
FAIL=0

# ---- ถ้า B ล้ม fault ไม่มีทางเกิด — ต้องบอกก่อนไปวัดอย่างอื่น ----
if [[ -s "$B_ERR" ]]; then
  echo "!! session B (ALTER TABLE) มี stderr — fault อาจไม่เกิดเพราะเหตุนี้:"
  sed 's/^/!!   /' "$B_ERR"
fi
if [[ -s "$A_ERR" ]]; then
  echo "!! session A มี stderr:"; sed 's/^/!!   /' "$A_ERR"
fi

# ---- ข้อ 1: C ต้องยังค้างอยู่ (query ที่ปกติเสร็จใน < 10ms) ----
if kill -0 "$C_PID" 2>/dev/null; then
  echo
  echo "[1/3] ✅ C ยังค้างอยู่หลังผ่านไป ${C_WAIT} วินาที (ปกติ query นี้เสร็จใน < 10ms)"
else
  echo
  echo "[1/3] ❌ C เสร็จไปแล้ว — fault ไม่เกิด"
  FAIL=1
fi

# ---- ข้อ 2: pg_locks ต้องมี granted = false อย่างน้อย 2 แถว ----
NOT_GRANTED="$(admin -c "
  SELECT count(*) FROM pg_locks l
  WHERE l.relation = '${TABLE}'::regclass AND NOT l.granted")"

if (( NOT_GRANTED >= 2 )); then
  echo "[2/3] ✅ pg_locks มีแถวที่ granted = false จำนวน ${NOT_GRANTED} แถว (ต้อง >= 2)"
else
  echo "[2/3] ❌ pg_locks มีแถวที่ granted = false แค่ ${NOT_GRANTED} แถว (ต้อง >= 2)"
  FAIL=1
fi

# ---- ข้อ 3: ไล่ห่วงโซ่ได้ว่า C ถูกบล็อกโดย B และ B ถูกบล็อกโดย A ----
# นี่คือข้อที่แยก F05 ออกจาก "DB ช้า" — ต้องเห็นห่วงโซ่ ไม่ใช่แค่เห็นการรอ
CHAIN="$(admin -c "
  WITH waiters AS (
    SELECT a.pid, a.query, pg_blocking_pids(a.pid) AS blockers
    FROM pg_stat_activity a
    WHERE cardinality(pg_blocking_pids(a.pid)) > 0
      AND a.datname = current_database()
  )
  SELECT count(*) FROM waiters w
  WHERE w.query ILIKE 'SELECT%'
    AND EXISTS (
      SELECT 1 FROM waiters b2
      WHERE b2.pid = ANY(w.blockers) AND b2.query ILIKE 'ALTER TABLE%'
    )")"

if [[ "$CHAIN" -ge 1 ]]; then
  echo "[3/3] ✅ ไล่ห่วงโซ่ได้: SELECT ถูกบล็อกโดย ALTER TABLE ซึ่งเองก็กำลังรออยู่"
else
  echo "[3/3] ❌ ไล่ห่วงโซ่ไม่ได้ — ไม่พบ SELECT ที่ถูกบล็อกโดย ALTER TABLE ที่กำลังรอ"
  FAIL=1
fi

if (( FAIL )); then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ"
  echo "!! ตรวจ: lock_timeout = $(admin -c 'SHOW lock_timeout')"
  echo "!!       statement_timeout = $(admin -c 'SHOW statement_timeout')"
  echo "!! ถ้าสองค่านี้ไม่ใช่ 0 แปลว่ากำลังรันโปรไฟล์ realistic อยู่"
  exit 1
fi

# =============================================================
# ground truth
# =============================================================
echo
echo "=== หลักฐาน: ต้นเหตุอยู่ที่คิว lock ไม่ใช่ที่ query หรือ network ==="
admin -P border=2 -P format=aligned -c "
SELECT l.pid,
       l.granted,
       l.mode,
       a.state,
       left(a.query, 46) AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE l.relation = '${TABLE}'::regclass
ORDER BY l.granted DESC, a.query_start;"

echo
echo "=== ห่วงโซ่การรอ: ใครรอใคร ==="
admin -P border=2 -P format=aligned -c "
SELECT a.pid,
       pg_blocking_pids(a.pid) AS blocked_by,
       left(a.query, 46) AS query
FROM pg_stat_activity a
WHERE a.datname = current_database()
  AND cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY a.query_start;"

if (( HOLD_OPEN > 0 )); then
  echo
  echo "=== ค้าง fault ไว้ ${HOLD_OPEN} วินาที ให้ตัวนับคะแนนมาตรวจ ==="
  sleep "$HOLD_OPEN"
fi

echo
echo "=== ALTER TABLE ยังไม่ได้เริ่มทำงานเลย มันแค่ 'รอ' ==="
echo "=== แต่การรอของมันทำให้ SELECT ที่ควรเสร็จใน 1ms ค้างไปด้วย ==="
echo "=== วิธีแก้ที่ถูก: ตั้ง lock_timeout ให้ DDL แล้วให้มันยอมแพ้แทนที่จะไปค้างในคิว ==="
echo "=== ไม่ใช่ restart แอป และไม่ใช่โทษ network ==="
