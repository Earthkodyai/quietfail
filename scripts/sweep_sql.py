# -*- coding: utf-8 -*-
"""
กวาด sql/ ทั้งโฟลเดอร์ด้วยเกณฑ์ที่ได้จากการทวนทีละไฟล์ (2026-08-02)

ทำไมต้องมี
----------
การทวน sql/ ทีละไฟล์เจอรูปแบบเดิมซ้ำ **9 ไฟล์ติดกัน** — ทุกครั้งเป็นเรื่อง
เดียวกันไม่กี่เรื่อง แต่ไม่มีอะไรตรวจให้ จึงหลุดมาเรื่อยๆ จนต้องมีคนไล่อ่านเอง
สคริปต์นี้ทำให้การทวนนั้น **รันซ้ำได้ในไม่กี่วินาที**

ตรวจ 4 ข้อ
----------
1. ตารางที่สร้างแล้วไม่ถูก DROP ในครึ่งหลังของไฟล์ **และยังค้างอยู่ในฐานจริง**
   (กับดักข้อ 14ฐ — DROP ที่ต้นไฟล์กันรอบถัดไป ไม่ได้เก็บของรอบนี้)
2. สร้าง index บนตารางที่ล็อกไว้ (qf_corpus · qf_real · qf_real2)
   โดยไม่มีคำเตือนในไฟล์ (กับดักข้อ 14ธ)
3. เขียนสูตร fingerprint เองแทนที่จะเรียก qf_fingerprint() (E40)
4. ตั้ง client_min_messages = warning จน RAISE NOTICE ที่ยืนยันว่า assertion
   ผ่านไม่โผล่ (กับดักข้อ 14ฑ — "เงียบ = ผ่าน" คือรูปแบบที่โครงงานนี้ศึกษาอยู่)

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
