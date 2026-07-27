#!/usr/bin/env bash
# =============================================================
# I03 — พิสูจน์ว่าตัวนับคะแนนพลิกได้จริง (สูตรใน CLAUDE.md ข้อ 6)
#
# แยกจากตัวฉีดหลัก เพราะต้องคุมจังหวะให้แม่น:
# หลักฐานของ I03 เป็น **สถานะสดของ pg_locks** ต้องวัดตอน build ยังค้างจริง
#
# ⚠️ ห้ามใช้ -qAt กับ psql ที่จะเอาผลไป grep ต่อ
#    -qAt ให้ผลแบบ I03|DETECTED|... (ไม่มีช่องว่าง)
#    ส่วนแบบ aligned ให้  I03      | DETECTED | ...
#    เคยกรองพลาดเพราะเรื่องนี้มาแล้ว
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"; PORT="${PGPORT:-5432}"; DB="${PGDATABASE:-faultlab}"
ADMIN_PW="${ADMIN_PW:-labpass}"; APP_PW="${APP_PW:-apppass}"

adm() { PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U lab -d "$DB" "$@"; }

BUILD_PID=""; WRITER_PID=""
cleanup() {
  # ⚠️ ต้องเล็งเฉพาะ leader (client backend) ห้ามแตะ parallel worker
  #    ฆ่า worker ตรงๆ ทำให้ leader ตายด้วย exit code 2
  #    แล้ว postmaster ถือว่า crash แล้วรีเซ็ตทั้งคลัสเตอร์ (ยืนยันจาก log ดู E29)
  #    ใช้ cancel ไม่ใช่ terminate ด้วย จะยกเลิก build ทั้งชุดอย่างสะอาด
  adm -qAt -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
               WHERE datname = current_database() AND pid <> pg_backend_pid()
                 AND backend_type = 'client backend'
                 AND (query LIKE 'CREATE INDEX%qf_i03_idx%'
                      OR query LIKE '%INSERT INTO qf_corpus%')" >/dev/null 2>&1
  sleep 2
  [[ -n "$WRITER_PID" ]] && kill "$WRITER_PID" 2>/dev/null
  [[ -n "$BUILD_PID"  ]] && kill "$BUILD_PID"  2>/dev/null
  wait 2>/dev/null
  adm -qAt -c "DROP INDEX IF EXISTS qf_i03_idx" >/dev/null 2>&1
  adm -qAt -c "DELETE FROM qf_corpus WHERE id > 100000000" >/dev/null 2>&1
}
trap cleanup EXIT

ROWS_BEFORE="$(adm -qAt -c 'SELECT count(*) FROM qf_corpus')"

echo "--- สถานะ 1: ไม่มี build ค้าง -> ต้องได้ NOT_DETECTED ---"
adm -v fault=i03 -f /sql/score.sql 2>&1 | grep "I03"

echo
echo "--- สถานะ 2: build ค้างอยู่ + มีการเขียนรอ -> ต้องได้ DETECTED ---"
adm -v concurrently=no -f /sql/i03_build_index.sql >/dev/null 2>/tmp/i03s.err &
BUILD_PID=$!
sleep 5

# ตัวเขียนที่จะค้างอยู่ในคิว — ต้องปล่อยค้างไว้จริง ไม่ timeout
PGPASSWORD="$APP_PW" psql -h "$HOST" -p "$PORT" -U app -d "$DB" -qAt -c \
  "BEGIN; INSERT INTO qf_corpus (id, cluster_id, embedding)
   SELECT 100000001, 1, embedding FROM qf_corpus WHERE id = 1; ROLLBACK;" >/dev/null 2>&1 &
WRITER_PID=$!
sleep 3

adm -v fault=i03 -f /sql/score.sql 2>&1 | grep "I03"

echo
echo "--- หลักฐานดิบตอนนั้น ---"
adm -P border=2 -P format=aligned -c "
SELECT a.pid, l.mode, l.granted, left(a.query, 40) AS query
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'qf_corpus'::regclass
ORDER BY l.granted DESC;"

cleanup; BUILD_PID=""; WRITER_PID=""
sleep 2

echo
echo "--- สถานะ 3: หลังเก็บกวาด -> ต้องพลิกกลับเป็น NOT_DETECTED ---"
adm -v fault=i03 -f /sql/score.sql 2>&1 | grep "I03"

ROWS_AFTER="$(adm -qAt -c 'SELECT count(*) FROM qf_corpus')"
echo
if [[ "$ROWS_BEFORE" == "$ROWS_AFTER" ]]; then
  echo "corpus คงที่ $ROWS_AFTER แถว"
else
  echo "!! corpus เปลี่ยน $ROWS_BEFORE -> $ROWS_AFTER"
  exit 1
fi
