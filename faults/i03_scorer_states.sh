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

# 5433 = พอร์ตที่ compose map ออกมา (รันในคอนเทนเนอร์ให้ส่ง PGPORT=5432)
HOST="${PGHOST:-localhost}"; PORT="${PGPORT:-5433}"; DB="${PGDATABASE:-faultlab}"
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
  # 🔴 ห้ามกลบ stderr — DELETE บน **ตารางที่ล็อกไว้** ถ้าล้มแล้วเงียบ
  #    จำนวนแถวจะไม่กลับมาเท่าเดิม แล้ว fingerprint เพี้ยนทั้งชุด (กับดักข้อ 1)
  adm -qAt -c "DELETE FROM qf_corpus WHERE id > 100000000" >/dev/null
}
trap cleanup EXIT

ROWS_BEFORE="$(adm -qAt -c 'SELECT count(*) FROM qf_corpus')"

# 🔴 เติม assertion 2026-08-02 — ไฟล์นี้มีไว้ "พิสูจน์ว่าตัวนับคะแนนพลิกได้"
#    แต่เดิม**พิมพ์ผลเฉยๆ ไม่ได้ตรวจอะไรเลย** จบด้วย exit 0 ตราบใดที่จำนวนแถว
#    ไม่เปลี่ยน · ถ้าตัวนับคะแนนตอบ NOT_DETECTED ทั้งสามสถานะ ไฟล์ผลก็จะถูก
#    commit เป็น "หลักฐานการพลิก" แล้ว audit ผ่าน — ซึ่งคือความล้มเหลวเงียบ
#    ชนิดเดียวกับที่โครงงานนี้ศึกษาอยู่ และเป็นรูปแบบเดียวกับ E30 (I05)
# วัด **ครั้งเดียว** ต่อสถานะ แล้วทั้งพิมพ์และดึง verdict จากผลก้อนเดียวกัน
# (ถ้ายิง score.sql ซ้ำเพื่อดึง verdict รอบสองอาจไปตกหลัง build จบแล้ว
#  = ดึง verdict ของคนละสถานะกับที่พิมพ์ออกมา)
SCORE_OUT=""
measure() {
  SCORE_OUT="$(adm -v fault=i03 -f /sql/score.sql 2>&1 | grep 'I03')"
  printf '%s
' "$SCORE_OUT"
}
verdict() { awk -F'|' '/^ *I03 /{gsub(/ /,"",$2); print $2; exit}' <<< "$SCORE_OUT"; }

echo "--- สถานะ 1: ไม่มี build ค้าง -> ต้องได้ NOT_DETECTED ---"
measure
S1="$(verdict)"

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

measure
S2="$(verdict)"

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
measure
S3="$(verdict)"

ROWS_AFTER="$(adm -qAt -c 'SELECT count(*) FROM qf_corpus')"

# =============================================================
# assertion — กฎเหล็กข้อ 3 · สูตรข้อ 6
# =============================================================
echo
FAIL=0
printf 'สถานะที่วัดได้: 1=%s · 2=%s · 3=%s
' "$S1" "$S2" "$S3"

if [[ "$S1" == "NOT_DETECTED" ]]; then
  echo "[1/4] ✅ สถานะ 1 (ไม่มี build) = NOT_DETECTED"
else
  echo "[1/4] ❌ สถานะ 1 ได้ '$S1' — ควรเป็น NOT_DETECTED"; FAIL=1
fi

if [[ "$S2" == "DETECTED" ]]; then
  echo "[2/4] ✅ สถานะ 2 (build ค้าง + มีคนรอเขียน) = DETECTED"
else
  echo "[2/4] ❌ สถานะ 2 ได้ '$S2' — ควรเป็น DETECTED"
  echo "        ถ้าได้ CANNOT_CHECK แปลว่าวัดไม่ทันจังหวะ ไม่ใช่ว่า fault ไม่เกิด"
  FAIL=1
fi

if [[ "$S3" == "NOT_DETECTED" ]]; then
  echo "[3/4] ✅ สถานะ 3 (หลังเก็บกวาด) = NOT_DETECTED — พลิกกลับได้"
else
  echo "[3/4] ❌ สถานะ 3 ได้ '$S3' — ควรพลิกกลับเป็น NOT_DETECTED"; FAIL=1
fi

# ตัวนับที่ตอบเหมือนกันทุกสถานะ = ไม่ได้วัดอะไรเลย (สูตรข้อ 6)
if [[ "$S1" == "$S2" ]]; then
  echo "[4/4] ❌ ตัวนับคะแนนตอบเหมือนกันทั้งตอนมีและไม่มี fault ('$S1')"
  echo "        = ไม่ได้วัดอะไรเลย ห้ามถือว่าไฟล์นี้เป็นหลักฐานการพลิก"
  FAIL=1
else
  echo "[4/4] ✅ ตัวนับคะแนนพลิกได้จริง ($S1 -> $S2 -> $S3)"
fi

if [[ "$ROWS_BEFORE" != "$ROWS_AFTER" ]]; then
  echo "!! corpus เปลี่ยน $ROWS_BEFORE -> $ROWS_AFTER"; FAIL=1
else
  echo "      (corpus คงที่ $ROWS_AFTER แถว)"
fi

if (( FAIL )); then
  echo
  echo "!! หลักฐานการพลิกใช้ไม่ได้ — ห้าม commit ผลรอบนี้เป็นหลักฐาน"
  exit 1
fi
