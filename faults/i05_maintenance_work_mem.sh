#!/usr/bin/env bash
# =============================================================
# I05 — maintenance_work_mem ต่ำ ทำให้ build HNSW ช้าผิดปกติ
#
# อาการที่เห็น : CREATE INDEX ใช้เวลานานผิดปกติ
# คนมักแก้ผิด  : ลด m / ef_construction · แบ่ง build เป็นก้อน · โทษว่า HNSW ช้า
# สาเหตุจริง   : กราฟ HNSW ใหญ่เกิน maintenance_work_mem
#                pgvector จึงเปลี่ยนไป build แบบใช้ดิสก์ ซึ่งช้ากว่ามาก
#
# ⚠️ ข้อนี้ **ไม่เงียบสนิท** — pgvector พิมพ์ NOTICE บอกตรงๆ
#    แต่ NOTICE ออกทาง stderr และแทบไม่มีใครอ่าน log ตอน migration ผ่าน
#    จึงเป็น "เตือนแล้วไม่มีใครอ่าน" ไม่ใช่ "ไม่เตือน" (เทียบ D11 กับ I02)
#
# นิยามเต็มอยู่ใน FAULTS.md — ห้ามแก้ assertion โดยไม่แก้ที่นั่นด้วย
# =============================================================
set -uo pipefail

HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5432}"
DB="${PGDATABASE:-faultlab}"
ADMIN_USER="${ADMIN_USER:-lab}"; ADMIN_PW="${ADMIN_PW:-labpass}"

# ค่าที่จะไล่ทดสอบ — เรียงจากน้อยไปมาก
# 64MB คือค่าของโปรไฟล์ fragile · ค่าที่เหลือไว้หาว่าเส้นแบ่งอยู่ตรงไหน
# ⚠️ เพดานบนถูกจำกัดด้วย /dev/shm ของคอนเทนเนอร์ ไม่ใช่ด้วย RAM
#    HNSW build แบบขนานจอง dynamic shared memory ตามขนาด maintenance_work_mem
#    ที่ 1GB จะขอ DSM ~1GB แต่ compose ตั้ง shm_size: 256mb → build ล้มเหลว
#    ยืนยันแล้ว: ปิด max_parallel_maintenance_workers แล้ว 1GB ผ่านทันที (ดู U05)
#    256MB พอสำหรับ 100k x 384 มิติ และไม่มี NOTICE แล้ว จึงใช้เป็นกลุ่มควบคุมได้
MWM_LIST="${MWM_LIST:-64MB 128MB 256MB}"

NOTICE_RE='no longer fits into maintenance_work_mem'

psql_run() {
  PGPASSWORD="$ADMIN_PW" psql -h "$HOST" -p "$PORT" -U "$ADMIN_USER" -d "$DB" "$@"
}

echo "=== I05: build HNSW ที่ maintenance_work_mem หลายค่า ==="
echo "    corpus: $(psql_run -qAt -c 'SELECT count(*) FROM qf_corpus') แถว"
echo

psql_run -qAt -c "DROP TABLE IF EXISTS qf_i05_results" >/dev/null

declare -A SAW_NOTICE
declare -A NOTICE_TUPLES

for MWM in $MWM_LIST; do
  echo "-- maintenance_work_mem = $MWM"

  # ⚠️ ห้ามใส่ 2>/dev/null ตรงนี้เด็ดขาด — NOTICE ที่เราต้องการอยู่ใน stderr
  #    และถ้า CREATE INDEX ล้มเหลว เราต้องเห็น (บทเรียน E26)
  ERR_FILE="$(mktemp)"
  psql_run -v mwm="$MWM" -f /sql/i05_build_one.sql >/dev/null 2>"$ERR_FILE"
  RC=$?

  if (( RC != 0 )); then
    # แยก "ชนข้อจำกัดของสภาพแวดล้อม" ออกจาก "fault ไม่เกิด" ให้ชัด
    # ไม่งั้นจะอ่านผลผิดว่า fault พัง ทั้งที่เป็นเรื่องของ shm
    if grep -q 'could not resize shared memory segment' "$ERR_FILE"; then
      echo "!! ชนข้อจำกัดของสภาพแวดล้อม ไม่ใช่ fault ไม่เกิด:"
      echo "   maintenance_work_mem=$MWM ใหญ่เกิน /dev/shm ของคอนเทนเนอร์"
      echo "   ($(df -h /dev/shm 2>/dev/null | awk 'NR==2{print $2}') available)"
      echo "   ทางออก: ลดค่าลง หรือเพิ่ม shm_size ใน docker-compose.yml"
      echo "   หรือ SET max_parallel_maintenance_workers = 0 (ยืนยันแล้วว่าผ่าน)"
    else
      echo "!! build ล้มเหลวที่ $MWM"
    fi
    sed 's/^/   /' "$ERR_FILE"
    rm -f "$ERR_FILE"
    exit 1
  fi

  if grep -q "$NOTICE_RE" "$ERR_FILE"; then
    SAW_NOTICE[$MWM]=1
    NOTICE_TUPLES[$MWM]="$(grep -oE 'after [0-9]+ tuples' "$ERR_FILE" | grep -oE '[0-9]+' | head -1)"
    echo "   NOTICE: กราฟไม่พอดีหน่วยความจำหลังจาก ${NOTICE_TUPLES[$MWM]} tuples"
  else
    SAW_NOTICE[$MWM]=0
    NOTICE_TUPLES[$MWM]=""
    echo "   ไม่มี NOTICE — กราฟอยู่ในหน่วยความจำได้ทั้งหมด"
  fi
  rm -f "$ERR_FILE"
done

echo
echo "=== ผลการวัด ==="
psql_run -P border=2 -P format=aligned -c "
SELECT mwm, mwm_kb, corpus_rows, build_ms,
       round(build_ms / min(build_ms) OVER (), 2) AS slower_than_best,
       index_size
FROM qf_i05_results ORDER BY mwm_kb;"

# =============================================================
# assertion — กฎเหล็กข้อ 3
# =============================================================
echo
FAIL=0
LOWEST="$(echo $MWM_LIST | awk '{print $1}')"
HIGHEST="$(echo $MWM_LIST | awk '{print $NF}')"

# ---- ข้อ 1: ค่าต่ำสุดต้องได้ NOTICE ----
if (( ${SAW_NOTICE[$LOWEST]} == 1 )); then
  echo "[1/3] ✅ ที่ $LOWEST ได้ NOTICE ตามที่เอกสารระบุ (หลัง ${NOTICE_TUPLES[$LOWEST]} tuples)"
else
  echo "[1/3] ❌ ที่ $LOWEST ไม่ได้ NOTICE — fault ไม่เกิด หรือข้อมูลเล็กเกินไป"
  FAIL=1
fi

# ---- ข้อ 2: ค่าสูงสุดต้องไม่ได้ NOTICE (กลุ่มควบคุม) ----
# ถ้าข้อนี้ไม่ผ่าน แปลว่าเพิ่มหน่วยความจำแล้วก็ยังไม่พอ ข้อ 1 จึงไม่พิสูจน์ว่าเป็นเพราะ mwm
if (( ${SAW_NOTICE[$HIGHEST]} == 0 )); then
  echo "[2/3] ✅ ที่ $HIGHEST ไม่มี NOTICE → ยืนยันว่าตัวแปรคือ maintenance_work_mem จริง"
else
  echo "[2/3] ❌ ที่ $HIGHEST ยังได้ NOTICE — เพิ่มค่าให้สูงกว่านี้แล้วรันใหม่"
  FAIL=1
fi

# ---- ข้อ 3: build ที่ค่าต่ำต้องช้ากว่าค่าสูงอย่างมีนัย ----
RATIO="$(psql_run -qAt -c "
  SELECT round(
    (SELECT build_ms FROM qf_i05_results ORDER BY mwm_kb ASC  LIMIT 1) /
    (SELECT build_ms FROM qf_i05_results ORDER BY mwm_kb DESC LIMIT 1), 2)")"

if awk "BEGIN{exit !($RATIO > 1.2)}"; then
  echo "[3/3] ✅ build ที่ $LOWEST ช้ากว่าที่ $HIGHEST ${RATIO} เท่า"
else
  echo "[3/3] ❌ build ต่างกันแค่ ${RATIO} เท่า (ต้องเกิน 1.2) — ผลไม่ชัดพอ"
  FAIL=1
fi

if (( FAIL )); then
  echo
  echo "!! FAULT ไม่เกิดตามที่ตั้งใจ"
  exit 1
fi

echo
echo "=== หลักฐาน: pgvector เตือนตรงๆ แต่เตือนทาง stderr ==="
echo "=== ไม่มีใครอ่าน log ตอน migration ที่ 'ผ่าน' → เตือนแล้วก็เท่านั้น ==="
echo "=== ต่างจาก Q01/I01 ที่เงียบสนิท — ข้อนี้คือ 'เตือนแล้วไม่มีใครอ่าน' ==="
