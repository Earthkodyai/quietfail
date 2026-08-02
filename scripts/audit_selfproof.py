# -*- coding: utf-8 -*-
"""
พิสูจน์ว่าหัวข้อของ audit.py ตอบลบได้จริง — สูตรข้อ 6 กับตัว audit เอง

ทำไมต้องมี
----------
`results/audit_selfcoverage.txt` บันทึกไว้ว่ามีหลักฐานการพลิกราว **1 ใน 3**
ของหัวข้อทั้งหมด ที่เหลือ *"เชื่อได้แค่ว่ามันไม่ได้ error"*

และ CLAUDE.md เขียนไว้เองว่า **`audit.py` เป็นตัวเดียวที่บังคับสูตรข้อ 6
กับคนอื่น แต่ยังไม่ผ่านกฎนี้เอง** · สคริปต์นี้ปิดช่องว่างนั้น

วิธี
----
แก้เงื่อนไขให้ผิดทีละข้อ → รัน audit → ดูว่า**หัวข้อนั้น**เปลี่ยนจาก ok
เป็น FAIL/CANNOT ไหม → คืนไฟล์เดิมเสมอ

⚠️ เก็บเนื้อไฟล์ไว้ในหน่วยความจำแล้วเขียนคืน · **ห้ามใช้ `git checkout`**
   (กับดักข้อ 13 — เคยลบงานที่ยังไม่ commit ทิ้งมาแล้วจริง)

⚠️ ระหว่างรัน หัวข้อ "working tree สะอาด" จะ FAIL เป็นธรรมดา เพราะไฟล์ถูกแก้
   จึงดูเฉพาะสถานะของ**หัวข้อที่กำลังพิสูจน์** ไม่ใช่ exit code รวม

⚠️ หัวข้อที่ค่าจริงมาจากฐานข้อมูล (จำนวนแถว · มิติ · เวอร์ชัน) พิสูจน์ด้วยการ
   แก้ **baseline** ไม่ใช่แก้ฐานข้อมูล — เพราะฐานถูกล็อกไว้และการแตะมันเสี่ยง
   กว่าประโยชน์มาก · สิ่งที่พิสูจน์ได้คือ **การเทียบทำงานและรายงานความต่าง**
   ซึ่งเป็นกลไกเดียวกับที่จะจับได้ถ้าค่าจริงเปลี่ยน

รัน
---
    python scripts/audit_selfproof.py            # ทุกข้อ
    python scripts/audit_selfproof.py --only 17  # เฉพาะข้อที่ระบุ

exit 0 = พลิกได้ครบทุกข้อที่ทดสอบ · exit 1 = มีข้อที่ไม่พลิก
"""
import io
import json
import os
import re
import glob
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

BASELINE = "scripts/audit_baseline.json"


# ---------------------------------------------------------------- ตัวช่วย
def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def run_audit():
    """คืน dict {ชื่อหัวข้อ: สถานะ}"""
    r = subprocess.run([sys.executable, "scripts/audit.py"],
                       capture_output=True, text=True, encoding="utf-8",
                       timeout=1800)
    out = {}
    for line in (r.stdout or "").split("\n"):
        m = re.match(r"^\s*(ok|FAIL|CANNOT)\s+(\S.*)$", line)
        if not m:
            continue
        # ปกติชื่อหัวข้อกับรายละเอียดคั่นด้วยช่องว่าง >= 2 ช่อง
        # 🔴 แต่ชื่อที่ยาวจะกินความกว้างคอลัมน์จนเหลือช่องเดียว
        #    (เจอกับ "มีไฟล์ *_checker_states.sql ตามที่ baseline กำหนด")
        #    รอบแรกบังคับ \s{2,} แล้วหัวข้อนั้น **หายไปเงียบๆ จากการพิสูจน์**
        #    ตัวสคริปต์รายงานว่า "ข้าม" ซึ่งเห็นได้ แต่ถ้าไม่มีบรรทัดนั้นก็จะไม่รู้เลย
        rest = m.group(2)
        parts = re.split(r"\s{2,}", rest, 1)
        out[parts[0].strip()] = m.group(1)
        if len(parts) == 1:                 # ไม่มีตัวคั่น — เก็บทั้งบรรทัดไว้ด้วย
            out[rest.strip()] = m.group(1)
    return out


def bl_patch(fn):
    """แก้ baseline ด้วยฟังก์ชันที่รับ/คืน dict"""
    def mutate():
        d = json.loads(read(BASELINE))
        fn(d)
        write(BASELINE, json.dumps(d, ensure_ascii=False, indent=2))
    return mutate



def _sql(stmt):
    """รัน SQL ในคอนเทนเนอร์ — ใช้กับเคสที่ค่าจริงอยู่ในฐานข้อมูล"""
    subprocess.run(["docker", "compose", "exec", "-T", "db", "psql", "-U", "lab",
                    "-d", "faultlab", "-q", "-c", stmt],
                   capture_output=True, text=True, encoding="utf-8", timeout=300)


def _restore_fingerprint():
    """คืนนิยามกลางจากไฟล์ต้นทาง — ห้ามพิมพ์สูตรซ้ำที่นี่ (E40)"""
    body = read("init/03_fingerprint.sql")
    subprocess.run(["docker", "compose", "exec", "-T", "db", "psql", "-U", "lab",
                    "-d", "faultlab", "-q"], input=body,
                   capture_output=True, text=True, encoding="utf-8", timeout=300)


# ------------------------------------------------- รายการที่จะพิสูจน์
# (คำในชื่อหัวข้อ, ไฟล์ที่จะถูกแก้, ฟังก์ชันแก้, คำอธิบาย)
def _gt(name):
    return "groundtruth/%s.json" % name


CASES = [
    ("parse ได้ทุกไฟล์", [_gt("v07")],
     lambda: write(_gt("v07"), read(_gt("v07")) + "\n{ พัง"),
     "ทำให้ JSON ของ groundtruth พังหนึ่งไฟล์"),

    ("มี evidence_expectation", [_gt("v07")],
     lambda: write(_gt("v07"),
                   read(_gt("v07")).replace('"evidence_expectation"',
                                            '"evidence_expectation_ถอด"', 1)),
     "ถอดช่อง evidence_expectation ออก"),

    ("ไฟล์ที่ reproduce ชี้ไปมีจริง", [_gt("v07")],
     lambda: write(_gt("v07"),
                   re.sub(r'("reproduce"\s*:\s*")', r'\1ไม่มีไฟล์นี้/',
                          read(_gt("v07")), count=1)),
     "ชี้ reproduce ไปยังไฟล์ที่ไม่มีอยู่"),

    ("จำนวน assertion ตรงกับสคริปต์จริง", [BASELINE],
     bl_patch(lambda d: d["reproduce"]["V07"].update(assertions=99)),
     "ตั้งจำนวน assertion ใน baseline ให้ผิด"),

    ("สูตรข้อ 6", [_gt("v07")],
     lambda: write(_gt("v07"),
                   read(_gt("v07")).replace("checker_states_verified",
                                            "checker_states_ถอด", 1)
                                   .replace("scorer_states_verified",
                                            "scorer_states_ถอด", 1)),
     "ถอดหลักฐานว่าตัวตรวจพลิกได้ออกจาก groundtruth",),

    # ⚠️ ตัวตรวจวน `for fid in faults_done` แล้วค่อยถามว่า fid อยู่ใน
    #    checker_states_file_required ไหม · การใส่ชื่อใหม่ลงใน required
    #    เฉยๆ จึง **ไม่มีผล** ถ้าชื่อนั้นไม่ได้อยู่ใน faults_done ด้วย
    #
    #    📌 ข้อสังเกตของ audit เอง: ถ้าใครเพิ่มชื่อลง required แล้วลืมเพิ่ม
    #       ลง faults_done ข้อบังคับนั้นจะถูกมองข้ามเงียบๆ
    #       (ความเสี่ยงต่ำ เพราะ faults_done เป็นรายการหลักที่ทุกหมวดใช้
    #        และหัวข้อ "สถานะใน CLAUDE.md ตรงกับ baseline" จับความไม่ตรงอยู่แล้ว)
    #
    #    วิธีพิสูจน์ที่ตรงกลไก: ซ่อนไฟล์ของ fault ที่อยู่ในทั้งสองรายการ
    ("มีไฟล์ *_checker_states.sql", ["sql/v07_checker_states.sql"],
     lambda: os.rename("sql/v07_checker_states.sql",
                       "sql/v07_checker_states.sql.ซ่อนชั่วคราว"),
     "ซ่อนไฟล์ v07_checker_states.sql ชั่วคราว"),

    ("E/D ที่ถูกอ้างมีนิยาม", ["README.md"],
     lambda: write("README.md", read("README.md") + "\n\nอ้างถึง E99 ที่ไม่มีนิยาม\n"),
     "อ้าง E99 ซึ่งไม่มีนิยามใน DECISIONS.md"),

    ("สถานะใน CLAUDE.md ตรงกับ baseline", [BASELINE],
     bl_patch(lambda d: d.setdefault("faults_remaining", []).append("V07")),
     "ย้าย V07 ไปอยู่ในรายการที่ยังไม่เสร็จ"),

    # ⚠️ deliverables เป็น dict ของ dict ไม่ใช่ dict ของ bool
    #    รอบแรกเขียน `not d[...]` ซึ่งแทนทั้ง dict ด้วย False แล้ว audit ไม่ฟ้อง
    #    -> **ตัวทดสอบผิด ไม่ใช่ audit ผิด**
    ("ตารางของส่งมอบใน CLAUDE.md", [BASELINE],
     bl_patch(lambda d: d["deliverables"][list(d["deliverables"])[0]]
              .__setitem__("done", False)),
     "ตั้งของส่งมอบข้อแรกใน baseline ให้เป็นยังไม่เสร็จ"),

    # ⚠️ ตัวตรวจมองหารูปแบบ `Q05 ✅` ใน **CLAUDE.md** เท่านั้น
    #    รอบแรกเติมลง README.md ด้วยรูปแบบอื่น จึงไม่โดน — ตัวทดสอบผิด
    #    📌 ข้อสังเกตที่ยังจริง: การตรวจนี้ **แคบ** ถ้า Q05 กลับมาโดยไม่มี ✅
    #       หรือกลับมาในไฟล์อื่น จะไม่ถูกจับ · ตั้งใจได้เพราะเจตนาคือ
    #       "ไม่กลับมาเป็นข้อที่ทำเสร็จแล้ว" แต่ต้องรู้ขอบเขตไว้
    ("fault ที่ตัดแล้วไม่กลับมา", ["CLAUDE.md"],
     lambda: write("CLAUDE.md", read("CLAUDE.md") + "\n\nQ05 ✅ เสร็จแล้ว\n"),
     "ใส่ Q05 ✅ กลับเข้า CLAUDE.md"),

    ("เลข H/U ในทะเบียนบัคไม่ซ้ำกัน", ["FAULTS.md"],
     lambda: write("FAULTS.md", read("FAULTS.md") + "\n\n| **H01** | ซ้ำโดยตั้งใจ | - |\n"),
     "ใส่แถว | **H01** | ซ้ำเข้าไปในทะเบียน"),
    #    ⚠️ ตัวตรวจนับเฉพาะ **แถวในตาราง** ที่ขึ้นต้นด้วย `| **Hnn**`
    #       ไม่นับการอ้างถึงในเนื้อความ (ตั้งใจ ไม่งั้นจะฟ้องผิดทุกครั้งที่พูดถึง H01)
    #       รอบแรกผมเติม `| H01 |` แบบไม่มีตัวหนา จึงไม่โดน — ตัวทดสอบผิด

    ("เลข E/D ไม่ซ้ำกัน", ["DECISIONS.md"],
     lambda: write("DECISIONS.md", read("DECISIONS.md") + "\n\n## E01 ซ้ำโดยตั้งใจ\n"),
     "ใส่หัวข้อ E01 ซ้ำเข้าไป"),

    # ตัวนี้ค่าจริงมาจาก **ฟังก์ชันในฐานข้อมูล** ไม่ใช่ไฟล์ จึงต้องแก้ที่ฐาน
    # แล้วคืนด้วย init/03_fingerprint.sql ซึ่งเป็นนิยามกลางตัวจริง (E40)
    ("ฟังก์ชันกลาง qf_fingerprint()", [],
     lambda: _sql("CREATE OR REPLACE FUNCTION qf_fingerprint(p_table text, "
                  "p_rows int DEFAULT 5000) RETURNS text LANGUAGE sql AS "
                  "$f$ SELECT 'สูตรที่ถูกแก้ให้ผิด' $f$;"),
     "แก้สูตรของฟังก์ชันกลางในฐานข้อมูล"),

    ("รันจบไม่มี error", ["sql/score.sql"],
     lambda: write("sql/score.sql",
                   read("sql/score.sql") + "\nSELECT ไม่มีคอลัมน์นี้ FROM ไม่มีตารางนี้;\n"),
     "เติมคำสั่งที่ต้อง error ต่อท้าย score.sql"),

    # ⚠️ ตัวตรวจเทียบ `faults_done` กับ verdict ที่ score.sql ตอบจริง
    #    **ไม่ได้ใช้ `score_expected_rows`** (ค่านั้นโผล่แค่ในข้อความ)
    #    รอบแรกผมแก้ score_expected_rows จึงไม่มีผล — ตัวทดสอบผิด
    ("ทุก fault มีสาขาที่ตอบได้", [BASELINE],
     bl_patch(lambda d: d["faults_done"].append("ZZ99")),
     "ใส่ fault ที่ score.sql ไม่มีสาขาให้ ลงใน faults_done"),

    ("qf_corpus จำนวนแถว", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("corpus_rows", 12345)),
     "ตั้งจำนวนแถวที่คาดหวังให้ผิด"),

    ("qf_corpus มิติ", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("corpus_dim", 999)),
     "ตั้งมิติที่คาดหวังให้ผิด"),

    ("qf_corpus fingerprint", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("corpus_fingerprint_first5k",
                                            "0" * 32)),
     "ตั้ง fingerprint ที่คาดหวังให้ผิด"),

    ("qf_truth จำนวนแถว", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("truth_rows", 4321)),
     "ตั้งจำนวนแถวเฉลยที่คาดหวังให้ผิด"),

    ("orders จำนวนแถว", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("orders_rows", 1)),
     "ตั้งจำนวนแถว orders ที่คาดหวังให้ผิด"),

    ("maintenance_work_mem", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("maintenance_work_mem", "7MB")),
     "ตั้งค่า mwm ที่คาดหวังให้ผิด"),

    ("PostgreSQL เวอร์ชัน", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("postgres_version_like", "9.9%")),
     "ตั้งเวอร์ชัน PostgreSQL ที่คาดหวังให้ผิด"),

    ("pgvector เวอร์ชัน", [BASELINE],
     bl_patch(lambda d: d["db"].__setitem__("pgvector_version", "9.9.9")),
     "ตั้งเวอร์ชัน pgvector ที่คาดหวังให้ผิด"),
]


def main():
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]

    print("=" * 78)
    print("audit.py ตรวจตัวเองด้วยสูตรข้อ 6 — แก้เงื่อนไขให้ผิดทีละข้อ")
    print("=" * 78)
    print()

    base = run_audit()
    print("สถานะตั้งต้น: ผ่าน %d หัวข้อ\n"
          % sum(1 for v in base.values() if v == "ok"))

    ok = flipped = 0
    failed = []
    for key, files, mutate, desc in CASES:
        if only and only not in key:
            continue
        target = [k for k in base if key in k]
        if not target:
            print("  ⚠️  ข้าม '%s' — ไม่พบหัวข้อนี้ในผล audit" % key)
            continue
        t = target[0]

        saved = {f: read(f) for f in files}      # เก็บไว้ในหน่วยความจำ
        # เคสที่ใช้ os.rename ไฟล์จะหายไป การเขียนคืนจาก saved จึงสร้างกลับได้เอง
        # แต่ต้องลบไฟล์ที่ถูก rename ออกไปด้วย ไม่งั้นเหลือขยะใน sql/
        try:
            mutate()
            after = run_audit()
            # 🔴 ชื่อหัวข้ออาจเปลี่ยนรูประหว่างตั้งต้นกับหลังแก้ เพราะความกว้าง
            #    คอลัมน์ขึ้นกับความยาวของ "รายละเอียด" ที่เปลี่ยนไปด้วย
            #    ค้นแบบตรงตัวก่อน แล้วค่อยถอยไปหาแบบขึ้นต้นตรงกัน
            got = after.get(t)
            if got is None:
                cand = [v for k, v in after.items()
                        if k.startswith(key) or key in k]
                got = cand[0] if cand else "(หาย)"
        finally:
            for f, sv in saved.items():          # คืนเสมอ แม้ระเบิดกลางทาง
                write(f, sv)
            if not files:                        # เคสที่แก้ฐานข้อมูล ไม่ใช่ไฟล์
                _restore_fingerprint()
            for junk in glob.glob("sql/*.ซ่อนชั่วคราว"):
                os.remove(junk)

        ok += 1
        if got in ("FAIL", "CANNOT"):
            flipped += 1
            print("  ✅ %-46s %s" % (t[:46], got))
            print("       %s" % desc)
        else:
            failed.append(t)
            print("  🔴 %-46s ยังตอบ %s" % (t[:46], got))
            print("       %s  <- ไม่พลิก" % desc)
    print()
    print("=" * 78)
    print("พิสูจน์ %d ข้อ · พลิกได้ %d · ไม่พลิก %d" % (ok, flipped, len(failed)))
    if failed:
        print("\n🔴 ไม่พลิก:")
        for t in failed:
            print("   %s" % t)
    print("=" * 78)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
