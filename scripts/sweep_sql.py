# -*- coding: utf-8 -*-
"""
กวาด sql/ ทั้งโฟลเดอร์ด้วยเกณฑ์ที่ได้จากการทวนทีละไฟล์ (2026-08-02)

ทำไมต้องมี
----------
การทวน sql/ ทีละไฟล์เจอรูปแบบเดิมซ้ำ **9 ไฟล์ติดกัน** — ทุกครั้งเป็นเรื่อง
เดียวกันไม่กี่เรื่อง แต่ไม่มีอะไรตรวจให้ จึงหลุดมาเรื่อยๆ จนต้องมีคนไล่อ่านเอง
สคริปต์นี้ทำให้การทวนนั้น **รันซ้ำได้ในไม่กี่วินาที**

ตรวจ 7 ข้อ
----------
1. ตารางที่สร้างแล้วไม่ถูก DROP ในครึ่งหลังของไฟล์ **และยังค้างอยู่ในฐานจริง**
   (กับดักข้อ 14ฐ — DROP ที่ต้นไฟล์กันรอบถัดไป ไม่ได้เก็บของรอบนี้)
2. สร้าง index บนตารางที่ล็อกไว้ (qf_corpus · qf_real · qf_real2)
   โดยไม่มีคำเตือนในไฟล์ (กับดักข้อ 14ธ)
3. เขียนสูตร fingerprint เองแทนที่จะเรียก qf_fingerprint() (E40)
4. ตั้ง client_min_messages = warning จน RAISE NOTICE ที่ยืนยันว่า assertion
   ผ่านไม่โผล่ (กับดักข้อ 14ฑ — "เงียบ = ผ่าน" คือรูปแบบที่โครงงานนี้ศึกษาอยู่)

เพิ่ม 2026-08-02 หลังพบว่าเกณฑ์เดิมตอบ "ไม่มีข้อสังเกต" ทั้งที่มีของจริง
(บทเรียนกับดักข้อ 14ฟ — การกวาดที่ได้ 0 ต้องถามว่าเกณฑ์ครอบคลุมจริงไหม)

5. ยิง score.sql หลายรอบเพื่อพิสูจน์การพลิก **แต่ไม่มีอะไรตรวจ verdict**
   (กับดักข้อ 14ว — 9 ใน 10 ไฟล์ *_checker_states เคยเป็นแบบนี้)
6. ทำลายตารางที่เอกสารระบุว่าห้ามลบ **โดยไม่สร้างคืนในไฟล์เดียวกัน**
   (กับดักข้อ 14ษ — v07_checker_states ลบ qf_v07 ทิ้งทุกครั้งที่รัน)
7. reset pg_stat_statements ตอนต้นแล้วยิง query ทดสอบ **แต่ไม่ล้างท้ายไฟล์**
   (กับดักข้อ 14ษ — ทำให้ Q02 ค้าง DETECTED ไม่ตรงกับสภาพสะอาดที่บันทึกไว้)

รัน
---
    python scripts/sweep_sql.py          # ต้องต่อ docker ได้ ถึงจะเช็คข้อ 1
    python scripts/sweep_sql.py --no-db  # ข้ามข้อ 1

exit 0 = ไม่มีข้อสังเกต · exit 1 = มี

⚠️ ข้อ 3 **คาดว่าจะเจอเยอะและไม่ต้องแก้** — CLAUDE.md ระบุไว้ว่าไฟล์เก่ากว่า
   30 จุดยังเขียนสูตรเองอยู่ และตั้งใจไม่แก้ เพราะเป็นสคริปต์ที่ผ่านการตรวจแล้ว
   audit.py มีหัวข้อ "นิยาม fingerprint ตรงกันทุกที่" กันการเคลื่อนอยู่แล้ว
   จึงรายงานเป็น "ทราบแล้ว" ไม่นับเป็นข้อสังเกต
"""
import io, os, re, sys, glob, subprocess

sys.stdout.reconfigure(encoding="utf-8")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# ตารางที่เอกสารระบุว่าห้ามลบ — ลบแล้วผลการทดลองหรือ verdict เปลี่ยน
KEEP_EXACT = {
    "qf_corpus", "qf_queries", "qf_truth", "qf_manifest", "qf_centroids",
    "qf_real", "qf_real_q", "qf_real_truth", "qf_real_sanity",
    "qf_real2", "qf_real2_q", "qf_real2_truth", "qf_real2_sanity",
    "qf_v07", "qf_v07r", "qf_v07r2",
}
# ตารางบันทึกผล — CLAUDE.md ระบุว่าขนาด kB ไม่ต้องเก็บกวาด
RESULT_MAX_BYTES = 2 * 1024 * 1024
LOCKED = ("qf_corpus", "qf_real", "qf_real2")
# ตัวสร้างฐานที่ล็อกไว้ — ดูเหตุผลที่ข้อ 6
BASE_BUILDER = re.compile(r"^qf1\d_")


def live_tables():
    try:
        r = subprocess.run(
            ["docker", "compose", "exec", "-T", "db", "psql", "-U", "lab",
             "-d", "faultlab", "-tAc",
             "SELECT relname||'|'||pg_total_relation_size(oid) FROM pg_class "
             "WHERE relkind='r' AND relname LIKE 'qf_%'"],
            capture_output=True, text=True, encoding="utf-8", timeout=120)
        if r.returncode != 0:
            return None
        out = {}
        for line in r.stdout.split("\n"):
            if "|" in line:
                n, b = line.strip().split("|")
                out[n] = int(b)
        return out
    except Exception:
        return None


def main():
    use_db = "--no-db" not in sys.argv
    size = live_tables() if use_db else None
    if use_db and size is None:
        print("⚠️  ต่อฐานข้อมูลไม่ได้ — ข้ามข้อ 1 (ตารางค้าง)\n")

    issues, known_fp = [], []
    files = sorted(glob.glob("sql/*.sql"))
    for f in files:
        s = io.open(f, encoding="utf-8").read()
        base = os.path.basename(f)
        flags = []

        # ---- 1. ตารางค้าง ----
        if size is not None:
            created = set(re.findall(
                r"CREATE TABLE(?:\s+IF NOT EXISTS)?\s+(qf_\w+)", s))
            half = len(s) // 2
            dropped = set(re.findall(
                r"DROP TABLE(?: IF EXISTS)?\s+(qf_\w+)", s[half:]))
            leaks = []
            for t in sorted(created - dropped):
                if t not in size or t in KEEP_EXACT:
                    continue
                if size[t] < RESULT_MAX_BYTES:
                    continue          # ตารางบันทึกผลขนาดเล็ก
                leaks.append("%s (%.0f MB)" % (t, size[t] / 1048576))
            if leaks:
                flags.append("ทิ้งตารางค้าง: " + ", ".join(leaks))

        # ---- 2. index บนตารางที่ล็อกไว้ ----
        idx = re.search(r"CREATE INDEX\s+\S+\s+ON\s+(%s)\b" % "|".join(LOCKED), s)
        if idx and "ไฟล์นี้สร้าง index **บน" not in s:
            flags.append("สร้าง index บน %s โดยไม่มีคำเตือน" % idx.group(1))

        # ---- 3. fingerprint (ทราบแล้ว ไม่นับเป็นข้อสังเกต) ----
        if "md5(string_agg" in s and "qf_fingerprint(" not in s:
            known_fp.append(base)

        # ---- 4. assertion เงียบ ----
        if ("client_min_messages = warning" in s
                and "RAISE NOTICE" in s
                and not re.search(r"\\echo.*(✅|assertion)", s)):
            flags.append("assertion ที่ผ่านแล้วไม่มีอะไรยืนยันให้เห็น")

        # ---- 5. พิสูจน์การพลิกโดยไม่ตรวจ verdict ----
        # ยิง score.sql ตั้งแต่ 2 รอบขึ้นไป = ตั้งใจแสดงการพลิก
        # ถ้าไม่มีอะไรบังคับผล ไฟล์ผลจะถูก commit เป็นหลักฐานไม่ว่าข้างในเขียนอะไร
        n_score = len(re.findall(r"\\i\s+/sql/score\.sql", s))
        has_enforce = ("states_assert.sql" in s
                       or "RAISE EXCEPTION" in s
                       or re.search(r"\bASSERT\b", s))
        if n_score >= 2 and not has_enforce:
            flags.append("ยิง score.sql %d รอบเพื่อแสดงการพลิก "
                         "แต่ไม่มีอะไรตรวจ verdict (สูตรข้อ 6)" % n_score)

        # ---- 6. ทำลายตารางที่ห้ามลบ โดยไม่สร้างคืน ----
        #
        # ยกเว้นชุด qf1x_* — **มันคือตัวสร้างฐานที่ล็อกไว้เอง** ไม่ใช่ผู้ใช้ฐาน
        # CLAUDE.md ระบุลำดับไว้ว่า qf10 -> qf11 -> qf12 -> qf13 คือวิธีสร้างใหม่
        # การ TRUNCATE แล้วเติมข้ามไฟล์จึงเป็นการออกแบบ ไม่ใช่ข้อบกพร่อง
        # (เขียนเป็นข้อยกเว้นที่มีเหตุผลกำกับ ไม่ใช่ปิดเสียงเฉยๆ)
        for t in (() if BASE_BUILDER.match(base) else sorted(KEEP_EXACT)):
            hit = re.search(r"(DROP TABLE(?: IF EXISTS)?|DELETE FROM|TRUNCATE)\s+%s\b" % t, s)
            if not hit:
                continue
            after = s[hit.end():]
            # สร้างคืนนับได้ 3 ทาง: CREATE ใหม่ · INSERT เติมกลับ · \i ตัวฉีดตัวจริง
            restored = (re.search(r"CREATE TABLE(?: IF NOT EXISTS)?\s+%s\b" % t, after)
                        or re.search(r"INSERT INTO\s+%s\b" % t, after)
                        or re.search(r"\\i\s+/sql/\w+\.sql", after))
            if not restored:
                flags.append("ทำลาย %s (%s) โดยไม่สร้างคืน — "
                             "เอกสารระบุว่าห้ามลบ" % (t, hit.group(1)))

        # ---- 7. reset สถิติตอนต้นอย่างเดียว ----
        resets = [m.start() for m in re.finditer(r"pg_stat_statements_reset\(\)", s)]
        if resets and resets[-1] < len(s) * 0.6 and "score.sql" in s:
            flags.append("reset pg_stat_statements แต่ไม่ล้างท้ายไฟล์ "
                         "-> Q02 ค้างไม่ตรงสภาพสะอาด")

        if flags:
            issues.append((base, flags))

    print("=" * 74)
    print("กวาด sql/ — %d ไฟล์" % len(files))
    print("=" * 74)
    if issues:
        print("\n🔴 ข้อสังเกต %d ไฟล์\n" % len(issues))
        for b, fl in issues:
            print("  %s" % b)
            for x in fl:
                print("      - %s" % x)
    else:
        print("\n✅ ไม่มีข้อสังเกต")

    if known_fp:
        print("\n📌 เขียนสูตร fingerprint เอง %d ไฟล์ — **ทราบแล้ว ตั้งใจไม่แก้**"
              % len(known_fp))
        print("   (CLAUDE.md · E40 · audit.py มีหัวข้อกันการเคลื่อนอยู่แล้ว)")

    print()
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
