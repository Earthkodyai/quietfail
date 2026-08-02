#!/usr/bin/env bash
# =============================================================
# I03 — CREATE INDEX บน vector column ไม่ใช้ CONCURRENTLY → บล็อกการเขียน
#
# อาการที่เห็น : ระบบเขียนไม่ได้ทั้งระบบตอน deploy · แต่ "อ่านได้ปกติ"
# คนมักแก้ผิด  : restart แอป · โทษ connection pool · rollback deploy ทั้งชุด
# สาเหตุจริง   : CREATE INDEX ธรรมดาถือ SHARE lock ตลอดเวลาที่ build
#                SHARE ชนกับ ROW EXCLUSIVE (การเขียน) แต่ไม่ชนกับ ACCESS SHARE (การอ่าน)
#
# ⭐ จุดที่ต่างจาก F05 และเป็นเหตุผลว่าทำไมทีมทดสอบไม่เจอ
#    F05 ใช้ ALTER TABLE ซึ่งถือ ACCESS EXCLUSIVE → บล็อกทุกอย่างรวมทั้งการอ่าน
#    I03 ใช้ CREATE INDEX ซึ่งถือ SHARE → **การอ่านยังทำงานปกติ**
#    staging ที่ทดสอบด้วย traffic อ่านอย่างเดียวจึงไม่เห็นอะไรผิดเลย
#
# ⭐ ระยะเวลาที่ระบบเขียนไม่ได้ = เวลา build ซึ่ง I05 วัดไว้แล้ว
#    HNSW 100k แถวที่ maintenance_work_mem=64MB ใช้ ~60 วินาที
#    ที่ 500k ใช้ 603 วินาที = เขียนไม่ได้ 10 นาที
#
# นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"
# 5433 = พอร์ตที่ docker-compose map ออกมา (รันในคอนเทนเนอร์ให้ส่ง PGPORT=5432
# ตามที่ WINDOWS.md เขียนไว้) — เดิมตั้ง 5432 ต่างจาก f01/f03/f05/f10 ทุกไฟล์
PORT="${PGPORT:-5433}"
DB="${PGDATABASE:-faultlab}"
ADMIN_USER="${ADMIN_USER:-lab}"; ADMIN_PW="${ADMIN_PW:-labpass}"
APP_USER="${APP_USER:-app}";     APP_PW="${APP_PW:-apppass}"

# รอสูงสุดกี่วินาทีก่อนสรุปว่า "ถูกบล็อก"
WAIT_LIMIT="${WAIT_LIMIT:-12}"
# ต้องถูกบล็อกนานกว่ากี่วินาทีถึงนับว่า fault เกิด
MIN_BLOCK_MS="${MIN_BLOCK_MS:-5000}"

admin() {
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" -qAt "$@"
}
app() {
  PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB" -qAt "$@"
}

BUILD_PID=""
cleanup() {
  echo
  echo "--- เก็บกวาด ---"
  # บทเรียน E16/E23: ฆ่า client ไม่พอ ต้องหยุดที่ฝั่ง server
  #
  # ⚠️ แต่ต้องเล็งเฉพาะ leader (backend_type = 'client backend')
  #    ห้ามแตะ parallel worker — ฆ่า worker ทำให้ leader ตายด้วย exit code 2
  #    แล้ว postmaster ถือว่า crash แล้วรีเซ็ตทั้งคลัสเตอร์ (ยืนยันจาก log ดู E29)
  #    และใช้ cancel แทน terminate เพราะยกเลิก build ทั้งชุดได้สะอาดกว่า
  admin -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
            WHERE datname = current_database() AND pid <> pg_backend_pid()
              AND backend_type = 'client backend'
              AND query LIKE 'CREATE INDEX%qf_i03_idx%'" >/dev/null 2>&1
  sleep 2
  [[ -n "$BUILD_PID" ]] && kill "$BUILD_PID" 2>/dev/null
  wait 2>/dev/null
  admin -c "DROP INDEX IF EXISTS qf_i03_idx" >/dev/null
  # ต้องคืนจำนวนแถวให้เท่าเดิม ไม่งั้น corpus ที่ล็อกไว้เพี้ยน
  # 🔴 ห้ามกลบ stderr — เป็น DELETE บน **ตารางที่ล็อกไว้** ถ้าล้มแล้วเงียบ
  #    จำนวนแถวจะไม่กลับมาเท่าเดิม แล้ว fingerprint เพี้ยนทั้งชุด (กับดักข้อ 1)
  admin -c "DELETE FROM qf_corpus WHERE id > 100000000" >/dev/null
}
trap cleanup EXIT

# วัดเวลาของคำสั่งหนึ่ง (ms) — คืน 'BLOCKED' ถ้าเกิน WAIT_LIMIT · 'ERROR' ถ้าคำสั่งล้ม
#
# 🔴 แก้ 2026-08-02 — เดิมดูแค่ exit 124 แล้วที่เหลือคืนเป็น "เวลา"
#    คำสั่งที่ **error ทันที** (สิทธิ์ไม่พอ · ตารางหาย · syntax) จึงคืนเลขน้อยๆ
#    แล้ว assertion ข้อ 4 ซึ่งเป็น**กลุ่มควบคุม** อ่านว่า "ไม่ถูกบล็อก ✅"
#    = ผ่านเพราะคำสั่งล้ม ไม่ใช่เพราะ CONCURRENTLY ทำงาน (ผลบวกลวงของกลุ่มควบคุม)
#    ตอนนี้แยก rc ออกมา และเก็บ stderr ไว้ให้ดูตอน assertion ตก
LAST_ERR=""
time_stmt() {
  local sql="$1"
  local s e rc errf
  errf="$(mktemp)"
  s=$(date +%s%3N)
  timeout "$WAIT_LIMIT" env PGPASSWORD="$APP_PW"     psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB"       -v ON_ERROR_STOP=1 -qAt -c "$sql" >/dev/null 2>"$errf"
  rc=$?
  e=$(date +%s%3N)
  LAST_ERR="$(cat "$errf")"; rm -f "$errf"
  if (( rc == 124 )); then
    echo "BLOCKED"
  elif (( rc != 0 )); then
    echo "ERROR"
  else
    echo $(( e - s ))
  fi
}

# เรียกทันทีหลัง time_stmt — เก็บ stderr ไว้โชว์ตอน assertion ตก
keep_err() { printf '%s' "$LAST_ERR"; }

# INSERT ที่ต้อง rollback เสมอ ไม่งั้น corpus ที่ล็อกไว้เปลี่ยน
INSERT_SQL="BEGIN; INSERT INTO qf_corpus (id, cluster_id, embedding)
            SELECT 100000001, 1, embedding FROM qf_corpus WHERE id = 1; ROLLBACK;"
SELECT_SQL="SELECT count(*) FROM qf_corpus WHERE id = 1;"

echo "=== I03: CREATE INDEX ไม่ใช้ CONCURRENTLY ==="
echo "    corpus $(admin -c 'SELECT count(*) FROM qf_corpus') แถว"

ROWS_BEFORE="$(admin -c 'SELECT count(*) FROM qf_corpus')"

# =============================================================
# A) ค่าฐาน — ไม่มีอะไรกำลัง build
# =============================================================
echo
echo "-- A) ค่าฐาน: ไม่มี build ค้างอยู่"
BASE_SELECT="$(time_stmt "$SELECT_SQL")"
BASE_INSERT="$(time_stmt "$INSERT_SQL")"
echo "   SELECT ${BASE_SELECT} ms · INSERT ${BASE_INSERT} ms"

# =============================================================
# B) CREATE INDEX ธรรมดา  ← นี่คือ fault
# =============================================================
echo
echo "-- B) CREATE INDEX ธรรมดา (ไม่ CONCURRENTLY)"
admin -v concurrently=no -f /sql/i03_build_index.sql >/dev/null 2>/tmp/i03_b.err &
BUILD_PID=$!
sleep 6

LOCK_ROWS="$(admin -c "
  SELECT count(*) FROM pg_locks
  WHERE relation = 'qf_corpus'::regclass AND mode = 'ShareLock' AND granted")"

B_SELECT="$(time_stmt "$SELECT_SQL")"; B_SELECT_ERR="$(keep_err)"
B_INSERT="$(time_stmt "$INSERT_SQL")"; B_INSERT_ERR="$(keep_err)"
echo "   SELECT ${B_SELECT} ms · INSERT ${B_INSERT} ms"
echo "   ShareLock ที่ได้รับแล้วบน qf_corpus: ${LOCK_ROWS} แถว"

if [[ "${RUN_SCORER:-0}" == "1" ]]; then
  echo
  echo "   --- ตัวนับคะแนนระหว่าง fault ค้าง (ต้องได้ DETECTED) ---"
  # การเขียนที่ค้างอยู่ต้องยังค้างตอนวัด จึงยิงอีกตัวไว้เบื้องหลัง
  timeout 20 env PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U "$APP_USER" -d "$DB"     -qAt -c "$INSERT_SQL" >/dev/null 2>&1 &
  sleep 2
  admin -v fault=i03 -f /sql/score.sql 2>&1 | grep -E "I03 +\|" || true
  wait 2>/dev/null
fi

echo
echo "   --- ห่วงโซ่การรอระหว่าง build ---"
admin -P border=2 -P format=aligned -c "
SELECT a.pid, l.mode, l.granted, left(a.query, 44) AS query
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'qf_corpus'::regclass
ORDER BY l.granted DESC, a.query_start;" || true

wait "$BUILD_PID" 2>/dev/null; BUILD_PID=""
admin -c "DROP INDEX IF EXISTS qf_i03_idx" >/dev/null

# =============================================================
# C) CREATE INDEX CONCURRENTLY — กลุ่มควบคุม
# =============================================================
echo
echo "-- C) CREATE INDEX CONCURRENTLY (ทางแก้ที่เอกสารแนะนำ)"
admin -v concurrently=yes -f /sql/i03_build_index.sql >/dev/null 2>/tmp/i03_c.err &
BUILD_PID=$!
sleep 6

C_SELECT="$(time_stmt "$SELECT_SQL")"; C_SELECT_ERR="$(keep_err)"
C_INSERT="$(time_stmt "$INSERT_SQL")"; C_INSERT_ERR="$(keep_err)"
echo "   SELECT ${C_SELECT} ms · INSERT ${C_INSERT} ms"

wait "$BUILD_PID" 2>/dev/null; BUILD_PID=""
admin -c "DROP INDEX IF EXISTS qf_i03_idx" >/dev/null

# =============================================================
# assertion — กฎเหล็กข้อ 3
# =============================================================
echo
FAIL=0

# ---- ข้อ 1: ระหว่าง build ธรรมดา การเขียนต้องถูกบล็อก ----
if [[ "$B_INSERT" == "ERROR" ]]; then
  echo "[1/4] ❌ ตรวจไม่ได้: การเขียนล้มด้วย error ไม่ใช่ถูกบล็อก (กฎเหล็กข้อ 10)"
  sed 's/^/          /' <<< "$B_INSERT_ERR"
  FAIL=1
elif [[ "$B_INSERT" == "BLOCKED" ]] || (( B_INSERT > MIN_BLOCK_MS )); then
  echo "[1/4] ✅ ระหว่าง CREATE INDEX ธรรมดา การเขียนถูกบล็อก (${B_INSERT})"
else
  echo "[1/4] ❌ การเขียนไม่ถูกบล็อก (${B_INSERT} ms) — fault ไม่เกิด"
  FAIL=1
fi

# ---- ข้อ 2: การอ่านต้องยังทำงานได้ — นี่คือจุดที่ทำให้ไม่มีใครเจอ ----
if [[ "$B_SELECT" == "ERROR" ]]; then
  echo "[2/4] ❌ ตรวจไม่ได้: การอ่านล้มด้วย error"
  sed 's/^/          /' <<< "$B_SELECT_ERR"
  FAIL=1
elif [[ "$B_SELECT" != "BLOCKED" ]] && (( B_SELECT < MIN_BLOCK_MS )); then
  echo "[2/4] ✅ การอ่านยังทำงานปกติระหว่าง build (${B_SELECT} ms) — staging อ่านอย่างเดียวจึงไม่เจอ"
else
  echo "[2/4] ❌ การอ่านถูกบล็อกด้วย (${B_SELECT}) — กลไกไม่ตรงกับที่ตั้งใจ"
  FAIL=1
fi

# ---- ข้อ 3: ต้องเห็น ShareLock ใน pg_locks จริง ----
# กฎเหล็กข้อ 10: อ่าน lock ไม่เจอ = ตรวจไม่ได้ ห้ามสรุปจากเวลาอย่างเดียว
if (( LOCK_ROWS >= 1 )); then
  echo "[3/4] ✅ pg_locks ยืนยัน ShareLock บน qf_corpus (${LOCK_ROWS} แถว)"
else
  echo "[3/4] ❌ ตรวจไม่ได้: ไม่เห็น ShareLock ใน pg_locks — อย่าสรุปจากเวลาอย่างเดียว"
  FAIL=1
fi

# ---- ข้อ 4: CONCURRENTLY ต้องไม่บล็อกการเขียน (กลุ่มควบคุม) ----
# 🔴 ข้อนี้เป็นกลุ่มควบคุม — ถ้าคำสั่งล้ม จะ "ไม่ถูกบล็อก" แบบว่างเปล่า
if [[ "$C_INSERT" == "ERROR" ]]; then
  echo "[4/4] ❌ ตรวจไม่ได้: การเขียนตอน CONCURRENTLY ล้มด้วย error"
  echo "        ห้ามอ่านว่า 'ไม่ถูกบล็อก' — กลุ่มควบคุมต้องสำเร็จจริงถึงจะยืนยันอะไรได้"
  sed 's/^/          /' <<< "$C_INSERT_ERR"
  FAIL=1
elif [[ "$C_INSERT" != "BLOCKED" ]] && (( C_INSERT < MIN_BLOCK_MS )); then
  echo "[4/4] ✅ CONCURRENTLY ไม่บล็อกการเขียน (${C_INSERT} ms) → ยืนยันว่าทางแก้ใช้ได้จริง"
else
  echo "[4/4] ❌ CONCURRENTLY ยังบล็อกการเขียน (${C_INSERT}) — กลุ่มควบคุมไม่ผ่าน"
  FAIL=1
fi

# ---- ตรวจว่าไม่ได้ทำ corpus เพี้ยน ----
ROWS_AFTER="$(admin -c 'SELECT count(*) FROM qf_corpus')"
if [[ "$ROWS_BEFORE" != "$ROWS_AFTER" ]]; then
  echo "!! corpus เปลี่ยนจาก $ROWS_BEFORE เป็น $ROWS_AFTER — INSERT ไม่ได้ถูก rollback"
  FAIL=1
else
  echo "      (corpus คงที่ $ROWS_AFTER แถว — INSERT ถูก rollback ครบ)"
fi

if (( FAIL )); then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ"
  exit 1
fi

echo
echo "=== เขียนไม่ได้นานเท่าเวลา build — ซึ่ง I05 วัดไว้แล้ว ==="
echo "===   100k แถว @ 64MB = ~60 วินาที · 500k แถว = 603 วินาที (10 นาที) ==="
echo "=== และ 'อ่านได้ปกติ' คือเหตุผลที่ทีมทดสอบด้วย read traffic ไม่เจออะไรเลย ==="
