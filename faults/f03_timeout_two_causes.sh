#!/usr/bin/env bash
# =============================================================
# F03 + F03b — statement timeout ที่มีข้อความเหมือนกันเป๊ะ แต่คนละสาเหตุ
#
# นี่คือข้อที่พิสูจน์วิทยานิพนธ์ของโปรเจคทั้งหมด
#
#   F03  : ERROR: canceling statement due to statement timeout
#          ต้นเหตุ = รอ row lock จาก transaction อื่น
#          ทางแก้ที่ถูก = ไล่หา transaction ที่ถือ lock
#
#   F03b : ข้อความ **เหมือนกันทุกตัวอักษร**
#          ต้นเหตุ = query ช้าจริง (ไม่มี index)
#          ทางแก้ที่ถูก = สร้าง index
#
# 🔴 ต้องระบุเงื่อนไขให้ชัด — แก้ 2026-08-02 (E46)
#
#    ข้อความ "เหมือนกันทุกตัวอักษร" **จริงเฉพาะเมื่อ lock_timeout = 0**
#    ซึ่งเป็นค่าตั้งต้นของ PostgreSQL · เอกสารระบุไว้เองว่า
#      "Unlike statement_timeout, this timeout can only occur while
#       waiting for locks."
#    วัดแล้ว (results/doc_crosscheck_f.txt)
#      F03  · lock_timeout = 0    -> canceling statement due to statement timeout
#      F03  · lock_timeout = 500  -> canceling statement due to **lock** timeout
#      F03b · lock_timeout = 50   -> canceling statement due to statement timeout
#
#    -> **ตัวแยกมีสองอย่าง ไม่ใช่หนึ่ง**
#         1. pg_blocking_pids()   F03 ไม่ว่าง · F03b ว่าง
#         2. lock_timeout         ตั้งแล้ว F03 เปลี่ยนข้อความ ส่วน F03b ไม่เปลี่ยน
#
#    ข้อ 2 เป็นกลไกที่ PostgreSQL มีให้อยู่แล้วแต่ **ค่าตั้งต้นเป็น 0**
#    จึงเข้าธีมเดียวกับ hnsw.iterative_scan ที่ปริยายปิด (ตารางที่ 16 ในเล่ม)
#
# LLM ที่เห็นแค่ข้อความ error แยกสองกรณีนี้ไม่ออก ต้องดูสถานะจริงของ DB
# — ซึ่งยังจริงอยู่ **ภายใต้ค่าตั้งต้น** ที่ทีมส่วนใหญ่ใช้
#
# นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5433}"
DB="${PGDATABASE:-faultlab}"

ADMIN_USER="${ADMIN_USER:-lab}";  ADMIN_PW="${ADMIN_PW:-labpass}"
APP_USER="${APP_USER:-app}";      APP_PW="${APP_PW:-apppass}"

# ⚠️ ต้องเท่ากันทั้งสองเคส ไม่งั้นเปรียบเทียบไม่ยุติธรรม
#
# 100ms มาจากการวัด ไม่ใช่การเดา (กฎเหล็กข้อ 2):
#   query ของ F03b (sort บนคอลัมน์ที่ไม่มี index) วัดได้ 252-280 ms
#   นิ่งมาก แกว่งแค่ ~10% ข้ามการรัน 4 ครั้ง
#   -> margin ประมาณ 2.6 เท่า
#
# สคริปต์ตรวจ margin นี้เองก่อนเริ่มทดลอง ถ้าไม่พอจะ exit พร้อมบอกเหตุผล
# (สเปกเดิมใน FAULTS.md เขียน 2s ซึ่งใช้ไม่ได้ — ไม่มี query ไหนบนชุดข้อมูลนี้
#  ช้าถึง 2 วินาที ดู E18)
TIMEOUT_MS="${TIMEOUT_MS:-100}"
MIN_MARGIN="${MIN_MARGIN:-2}"

HOLD_OPEN="${HOLD_OPEN:-0}"

# query ของ F03b: sort บนคอลัมน์ที่ไม่มี index เลยสักคอลัมน์
# ตารางมี index บน created_at (มี timezone) แต่ไม่มีบน created_at_naive,
# total_float, status, total_satang
#
# วัดค่าต่ำสุดจาก 5 รอบ (ค่าต่ำสุดคือตัวที่สำคัญ เพราะเป็นกรณีแย่สุดของ margin):
#   sort คอลัมน์เดียว   240 ms
#   distinct 3 คอลัมน์  274 ms
#   sort 4 คอลัมน์      331 ms   <- เลือกอันนี้ margin 3.3x
SLOW_SQL="SELECT count(*) FROM (SELECT * FROM orders ORDER BY created_at_naive, total_float, status, total_satang) t"

admin() {
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" \
    -v ON_ERROR_STOP=1 -qAt "$@"
}
app_err() {
  # รันแล้วคืนเฉพาะข้อความ error
  PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB" \
    -q -o /dev/null "$@" 2>&1 >/dev/null
}

A_PID=""; W_PID=""
# 🔴 เดิม session A ทิ้ง stderr — A คือตัวที่ถือ row lock ทั้งข้อ
#    ถ้า UPDATE ของมันล้ม (แถวถูกล็อกค้างจากรอบก่อน · สิทธิ์ไม่พอ) จะไม่มี
#    blocker แล้ว assertion 3 ตกโดยไม่บอกสาเหตุ = รูปแบบเดียวกับ F05 (แก้ 2026-08-02)
A_ERR="$(mktemp)"
cleanup() {
  echo
  echo "--- เก็บกวาด ---"
  [[ -n "$W_PID" ]] && kill "$W_PID" 2>/dev/null
  [[ -n "$A_PID" ]] && kill "$A_PID" 2>/dev/null
  wait 2>/dev/null
  rm -f "${READY_FILE:-/tmp/qf_f03_ready}" "$A_ERR"
  # KEEP_OBS=1 ให้เก็บตารางสังเกตการณ์ไว้ เพื่อให้ตัวนับคะแนนรัน**หลัง**ตัวฉีดจบได้
  #
  # ต่างจาก F01/F05 ที่หลักฐานเป็นสถานะสดของ DB (ต้องวัดตอน fault ยังค้าง)
  # หลักฐานของ F03 คือ **ตาราง** ที่บันทึกไว้แล้ว จึงไม่มีเหตุผลต้องแข่งกับเวลา
  # เคยพยายามใช้ HOLD_OPEN + ไฟล์สัญญาณ แล้ววัดผิดจังหวะซ้ำๆ (ดู E21)
  if [[ "${KEEP_OBS:-0}" != "1" ]]; then
    admin -c "DROP TABLE IF EXISTS qf_f03_obs" >/dev/null
  else
    echo "   (KEEP_OBS=1 — เก็บตาราง qf_f03_obs ไว้ให้ตัวนับคะแนน)"
  fi
  # คืนค่า status ของแถวที่เอามาทดลอง
  # 🔴 ห้ามกลบ stderr — ถ้าคืนค่า status ไม่สำเร็จ แถวทดลองจะค้างสถานะผิด
  admin -c "UPDATE orders SET status='paid' WHERE id=1 AND status IN ('x','y')" >/dev/null
}
trap cleanup EXIT

echo "=== F03 / F03b: ข้อความ error เดียวกัน สองสาเหตุ ==="
echo "    statement_timeout = ${TIMEOUT_MS}ms (เท่ากันทั้งสองเคส)"

# =============================================================
# pre-flight — query ของ F03b ต้องช้าพอจะชน timeout จริง
# ถ้า margin ไม่พอ การทดลองจะกระพริบ ต้องรู้ตั้งแต่ก่อนเริ่ม ไม่ใช่ตอนอ่านผล
# =============================================================
echo
echo "-- pre-flight: วัดว่า query ของ F03b ช้าจริงเท่าไหร่ (ยังไม่ตั้ง timeout)"
START=$(date +%s%3N)
admin -c "SET max_parallel_workers_per_gather = 0; ${SLOW_SQL}" >/dev/null
END=$(date +%s%3N)
SLOW_MS=$((END - START))

# ---- lock_timeout ต้องเป็น 0 ไม่งั้นทั้งข้อวัดคนละเรื่อง (E46 · 2026-08-02) ----
#
# เอกสาร PostgreSQL: "Unlike statement_timeout, this timeout can only occur
# while waiting for locks." -> lock_timeout **แยก F03 ออกจาก F03b ได้เอง**
# วัดแล้ว: ตั้ง lock_timeout=500 แล้ว F03 เปลี่ยนเป็น "due to lock timeout"
# ส่วน F03b ยังเป็น "due to statement timeout" เหมือนเดิม
#
# ข้ออ้าง "ข้อความเหมือนกันเป๊ะ" จึงจริง **เฉพาะที่ค่าตั้งต้น 0** เท่านั้น
# ถ้าไม่ตรวจตรงนี้ assertion ข้อ 1 จะตกแล้วรายงานว่า "ออกแบบผิด" ซึ่งผิด
LOCK_TO="$(admin -c 'SHOW lock_timeout')"
echo "   lock_timeout = ${LOCK_TO} (ต้องเป็น 0 — ดู E46)"
if [[ "$LOCK_TO" != "0" ]]; then
  echo
  echo "!! lock_timeout ไม่ใช่ 0 — ทั้งข้อนี้วัดภายใต้ค่าตั้งต้นเท่านั้น"
  echo "!! ที่ค่าอื่น F03 จะได้ 'canceling statement due to lock timeout'"
  echo "!! ซึ่ง**แยกจาก F03b ได้ด้วยข้อความ** = ไม่ใช่ fault ที่เงียบอีกต่อไป"
  echo "!! ตั้ง lock_timeout = 0 แล้วรันใหม่ ห้ามปล่อยผ่านแล้วนับคะแนน"
  exit 1
fi

NEED=$((TIMEOUT_MS * MIN_MARGIN))
echo "   query ของ F03b ใช้เวลา ${SLOW_MS}ms · ต้องการอย่างน้อย ${NEED}ms (${MIN_MARGIN}x ของ timeout)"
if (( SLOW_MS < NEED )); then
  echo
  echo "!! margin ไม่พอ การทดลองจะกระพริบ"
  echo "!! ลด TIMEOUT_MS หรือหา query ที่ช้ากว่านี้ — ห้ามปล่อยผ่านแล้วนับคะแนน"
  exit 1
fi

# =============================================================
# ตัวเฝ้าดู — สุ่มตัวอย่าง pg_blocking_pids() ระหว่างที่ victim ยังทำงานอยู่
#
# ต้องเฝ้าจากในฐานข้อมูล ไม่ใช่ยิง psql เป็นรอบๆ
# เพราะหน้าต่างเวลามีแค่ ~100ms การ round-trip แต่ละครั้งกินเวลาใกล้เคียงกัน
# =============================================================
admin -c "
DROP TABLE IF EXISTS qf_f03_obs;
CREATE TABLE qf_f03_obs (
    tag        text,
    pid        int,
    blockers   int[],
    state      text,
    wait_event text,
    sampled_at timestamptz DEFAULT clock_timestamp()
);" >/dev/null

start_watcher() {
  # ตัวเฝ้าดูอยู่ในไฟล์ SQL ต่างหาก ไม่ฝังใน shell
  # เพราะ quoting ของ bash กับ dollar-quote ของ plpgsql เคยตีกันจนมันตายเงียบ (ดู E19)
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB"     -v ON_ERROR_STOP=1 -qAt -v secs="${WATCH_SECS:-6}" -f /sql/f03_watcher.sql     > /tmp/qf_f03_watcher.log 2>&1 &
  W_PID=$!
}

# ถ้าตัวเฝ้าดูตาย ต้องรู้ทันที ไม่ใช่ไปสรุปว่า "ไม่มี blocker"
watcher_must_be_alive() {
  if [[ -s /tmp/qf_f03_watcher.log ]]; then
    echo "!! ตัวเฝ้าดูมีปัญหา:"
    sed 's/^/   /' /tmp/qf_f03_watcher.log
    exit 1
  fi
}

# =============================================================
# เคส F03 — รอ row lock
# =============================================================
echo
echo "=== F03: victim รอ row lock ==="
echo "-- A: BEGIN แล้ว UPDATE แถว id=1 ค้างไว้ (ถือ row lock)"
( echo "BEGIN; UPDATE orders SET status='x' WHERE id=1;"; sleep 60 ) \
  | PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB" \
      -q -o /dev/null 2>"$A_ERR" &
A_PID=$!
sleep 2

start_watcher
sleep 1

echo "-- B: ตั้ง statement_timeout แล้ว UPDATE แถวเดียวกัน"
F03_ERR="$(app_err -c "SET statement_timeout = '${TIMEOUT_MS}ms'; /* qf_f03_victim */ UPDATE orders SET status='y' WHERE id=1")"
echo "   ได้: ${F03_ERR:-(ไม่มี error — fault ไม่เกิด)}"

wait "$W_PID" 2>/dev/null; W_PID=""
watcher_must_be_alive

# ปล่อย A ก่อนเข้าเคสถัดไป ไม่งั้น F03b จะโดน lock ปนเข้ามา
kill "$A_PID" 2>/dev/null; wait 2>/dev/null; A_PID=""
sleep 1

# =============================================================
# เคส F03b — query ช้าจริง ไม่มีใครบล็อก
# =============================================================
echo
echo "=== F03b: victim ช้าเอง ไม่มีใครบล็อก ==="
start_watcher
sleep 1

echo "-- session เดียว ไม่มี transaction อื่นเลย"
F03B_ERR="$(app_err -c "SET statement_timeout = '${TIMEOUT_MS}ms'; SET max_parallel_workers_per_gather = 0; /* qf_f03b_victim */ ${SLOW_SQL}")"
echo "   ได้: ${F03B_ERR:-(ไม่มี error — fault ไม่เกิด)}"

wait "$W_PID" 2>/dev/null; W_PID=""
watcher_must_be_alive

# =============================================================
# assertion — กฎเหล็กข้อ 3
# =============================================================
echo
FAIL=0

# ---- ข้อ 1: บรรทัด ERROR ต้องเหมือนกันเป๊ะ ----
#
# เทียบเฉพาะ **บรรทัดแรก (บรรทัด ERROR)** ไม่ใช่ข้อความทั้งก้อน
#
# เหตุผล — ค้นพบจากการรันจริง (ดู E20):
#   PostgreSQL แถมบรรทัด CONTEXT มาให้เฉพาะ F03:
#     CONTEXT:  while updating tuple (0,1) in relation "orders"
#
#   แต่ CONTEXT บอกว่า "คำสั่งนี้กำลัง update tuple" ซึ่งเป็นคุณสมบัติของ
#   **ชนิดคำสั่ง** ไม่ใช่ของ **สาเหตุ** — UPDATE ที่ช้าเองก็ได้ CONTEXT แบบนี้
#   จึงแยกไม่ได้ว่ารอ lock หรือช้าเอง และไม่บอกว่าต้องแก้ตรงไหน
#
#   สิ่งที่ระบบ log และ client library ส่วนใหญ่โชว์คือบรรทัด ERROR
F03_MSG="$(head -1 <<< "$F03_ERR")"
F03B_MSG="$(head -1 <<< "$F03B_ERR")"

if [[ -z "$F03_MSG" || -z "$F03B_MSG" ]]; then
  echo "[1/4] ❌ มีเคสที่ไม่ได้ error เลย — fault ไม่เกิด"
  FAIL=1
elif [[ "$F03_MSG" == "$F03B_MSG" ]]; then
  echo "[1/4] ✅ บรรทัด ERROR เหมือนกันทุกตัวอักษร (ที่ lock_timeout = 0)"
  echo "        \"$F03_MSG\""
  if [[ "$F03_ERR" != "$F03B_ERR" ]]; then
    echo "        (มีบรรทัดเสริมต่างกัน — ดูหัวข้อ CONTEXT ข้างล่าง)"
  fi
else
  echo "[1/4] ❌ บรรทัด ERROR ต่างกัน — ออกแบบผิด ทั้งข้อตั้งอยู่บนสมมติฐานว่าเหมือนกัน"
  echo "        F03 : $F03_MSG"
  echo "        F03b: $F03B_MSG"
  FAIL=1
fi

# ---- ข้อ 2: ตัวเฝ้าดูต้องเห็น victim ทั้งสองเคสจริง ----
# กฎเหล็กข้อ 10: ถ้าเฝ้าไม่ทัน ต้องบอกว่า "ตรวจไม่ได้" ไม่ใช่ "ผ่าน"
SEEN_F03="$(admin -c "SELECT count(*) FROM qf_f03_obs WHERE tag='F03'")"
SEEN_F03B="$(admin -c "SELECT count(*) FROM qf_f03_obs WHERE tag='F03b'")"
if (( SEEN_F03 > 0 && SEEN_F03B > 0 )); then
  echo "[2/4] ✅ ตัวเฝ้าดูเก็บตัวอย่างได้ (F03 ${SEEN_F03} ครั้ง · F03b ${SEEN_F03B} ครั้ง)"
else
  echo "[2/4] ❌ ตรวจไม่ได้: ตัวเฝ้าดูไม่ทัน (F03 ${SEEN_F03} · F03b ${SEEN_F03B})"
  echo "        อย่าถือว่าผ่าน — เพิ่ม TIMEOUT_MS แล้วรันใหม่"
  FAIL=1
fi

# ---- ข้อ 3: F03 ต้องมี blocker ----
F03_BLOCKED="$(admin -c "
  SELECT count(*) FROM qf_f03_obs WHERE tag='F03' AND cardinality(blockers) > 0")"
if (( F03_BLOCKED > 0 )); then
  echo "[3/4] ✅ F03: pg_blocking_pids() ไม่ว่าง (${F03_BLOCKED} ตัวอย่าง) = ถูกบล็อกจริง"
else
  echo "[3/4] ❌ F03: pg_blocking_pids() ว่างตลอด — ไม่ได้รอ lock ตามที่ตั้งใจ"
  if [[ -s "$A_ERR" ]]; then
    echo "        session A (ตัวที่ควรถือ lock) มี stderr — น่าจะเป็นสาเหตุ:"
    sed 's/^/          /' "$A_ERR"
  fi
  FAIL=1
fi

# ---- ข้อ 4: F03b ต้องไม่มี blocker เลย ----
F03B_BLOCKED="$(admin -c "
  SELECT count(*) FROM qf_f03_obs WHERE tag='F03b' AND cardinality(blockers) > 0")"
# ⚠️ ต้องมีตัวอย่าง > 0 ด้วย ไม่งั้น "ไม่มี blocker" เป็นจริงแบบว่างเปล่า
# รอบแรกสคริปต์นี้เคยขึ้น ✅ ทั้งที่เก็บตัวอย่างไม่ได้เลย = ละเมิดกฎเหล็กข้อ 10 ในตัวเอง
if (( SEEN_F03B == 0 )); then
  echo "[4/4] ❌ ตรวจไม่ได้: ไม่มีตัวอย่างของ F03b เลย — ห้ามสรุปว่าไม่มี blocker"
  FAIL=1
elif (( F03B_BLOCKED == 0 )); then
  echo "[4/4] ✅ F03b: pg_blocking_pids() ว่างทุกตัวอย่าง (${SEEN_F03B} ตัวอย่าง) = ช้าเอง ไม่มีใครบล็อก"
else
  echo "[4/4] ❌ F03b: มี blocker ${F03B_BLOCKED} ตัวอย่าง — มี lock ปนเข้ามา ผลใช้ไม่ได้"
  FAIL=1
fi

if (( FAIL )); then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ"
  exit 1
fi

# =============================================================
# ground truth
# =============================================================
echo
echo "=== หลักฐาน: ข้อความเดียวกัน แต่ pg_blocking_pids() แยกออกได้ ==="
admin -P border=2 -P format=aligned -c "
SELECT tag,
       count(*)                                   AS samples,
       max(cardinality(blockers))                 AS max_blockers,
       bool_or(cardinality(blockers) > 0)         AS was_blocked
FROM qf_f03_obs
GROUP BY tag
ORDER BY tag;"

echo
echo "=== CONTEXT: บรรทัดเสริมที่ PostgreSQL แถมมา ==="
echo "--- F03 เต็มๆ ---"
sed 's/^/    /' <<< "$F03_ERR"
echo "--- F03b เต็มๆ ---"
sed 's/^/    /' <<< "$F03B_ERR"
echo
echo "    CONTEXT บอกว่าคำสั่งกำลัง update tuple = คุณสมบัติของ 'ชนิดคำสั่ง'"
echo "    ไม่ใช่ของ 'สาเหตุ' — UPDATE ที่ช้าเองก็ได้ CONTEXT แบบเดียวกัน"
echo "    จึงยังแยกไม่ได้ว่ารอ lock หรือช้าเอง และไม่บอกว่าต้องแก้ตรงไหน"

echo
echo "=== ตัวอย่างดิบ ==="
admin -P border=2 -P format=aligned -c "
SELECT tag, pid, blockers FROM qf_f03_obs ORDER BY sampled_at LIMIT 8;"

if (( HOLD_OPEN > 0 )); then
  echo
  echo "=== ค้างผลไว้ ${HOLD_OPEN} วินาที ให้ตัวนับคะแนนมาตรวจ ==="
  # ส่งสัญญาณว่าพร้อมให้วัดแล้ว แทนที่จะให้ผู้เรียกเดาเวลาด้วย sleep
  # เวลาที่ใช้ก่อนถึงจุดนี้ขึ้นกับความเร็วเครื่อง เดาแล้วพลาดแน่
  # (พลาดมาแล้วจริง — วัดตอน F03 เสร็จแต่ F03b ยังไม่เริ่ม ได้ CANNOT_CHECK)
  touch "${READY_FILE:-/tmp/qf_f03_ready}"
  sleep "$HOLD_OPEN"
  rm -f "${READY_FILE:-/tmp/qf_f03_ready}"
fi

echo
echo "=== ข้อความ error บอกอะไรไม่ได้เลยว่าต้องแก้ตรงไหน ==="
echo "=== F03  แก้ถูก = ไล่หา transaction ที่ถือ lock ==="
echo "=== F03b แก้ถูก = สร้าง index ==="
echo "=== ทั้งคู่ 'แก้' ด้วยการเพิ่ม timeout ได้ และทั้งคู่ผิดทั้งคู่ ==="
echo
echo "=== แต่ PostgreSQL มีตัวแยกให้อยู่แล้ว — ปริยายปิด (E46) ==="
echo "    lock_timeout ปริยาย = 0 -> ทั้งสองเคสได้ข้อความเดียวกัน"
echo "    ตั้ง lock_timeout ต่ำกว่า statement_timeout แล้ว F03 จะได้"
echo "      canceling statement due to lock timeout"
echo "    ส่วน F03b ยังได้ 'statement timeout' เหมือนเดิม = แยกออกจากกันทันที"
echo "    -> รูปแบบเดียวกับ hnsw.iterative_scan · idle_in_transaction_session_timeout"
echo "       คือ 'เครื่องมือมีอยู่แล้ว แต่ค่าตั้งต้นทำให้เงียบ'"
