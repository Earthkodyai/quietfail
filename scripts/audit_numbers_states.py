# -*- coding: utf-8 -*-
"""พิสูจน์ว่าหมวด 6 ของ audit.py พลิกสถานะได้จริง — ไม่ใช่ตัวตรวจที่ตอบ ok อย่างเดียว"""
import io, os, re, subprocess, sys
sys.stdout.reconfigure(encoding='utf-8')
# อยู่ใน scripts/ จึงต้องขึ้นไปหนึ่งชั้นให้ path ของเอกสารเป็น root ของ repo
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CASES = [
    ("จำนวนหัวข้อของ audit",  "CLAUDE.md",  "32 หัวข้อ 6 หมวด", "33 หัวข้อ 6 หมวด"),
    ("จำนวนไฟล์ใน results/",  "REPORT.md",  "`results/` (46 ไฟล์)", "`results/` (45 ไฟล์)"),
    ("แถวทะเบียนบั๊ก H",      "REPORT.md",  "**30 รายการ**", "**29 รายการ**"),
    ("เลข H ตัวสุดท้าย",      "README.md",  "(H01–H30)", "(H01–H29)"),
    ("assertion ของ reproduce","REPORT.md", "assertion 46/46", "assertion 45/45"),
    ("เวลารวมของ reproduce",  "REPORT.md",  "32.4 นาที", "31.4 นาที"),
]

def audit_group6():
    p = subprocess.run([sys.executable, "scripts/audit.py"],
                       capture_output=True, env=dict(os.environ, PYTHONIOENCODING="utf-8"))
    out = p.stdout.decode("utf-8", "replace")
    keep, lines = False, []
    for l in out.splitlines():
        if l.startswith("── 6 "): keep = True; continue
        # ⚠️ ต้องหยุดที่บล็อกสรุปด้วย ไม่ใช่แค่หัวหมวดถัดไป
        #    รุ่นแรกหยุดแค่ที่ "──" จึงลากบรรทัดสรุป "ผ่าน 31 · ไม่ผ่าน 1" เข้ามาด้วย
        #    แล้วตัดสินว่าตัวตรวจไม่ผ่าน ทั้งที่มันจับได้ครบ 6/6 — ตัวพิสูจน์พังเอง
        if keep and (l.startswith("──") or l.startswith("=")): break
        if keep and l.strip(): lines.append(l.rstrip())
    return p.returncode, lines

def git_restore(fn):
    subprocess.run(["git", "checkout", "--", fn], capture_output=True)

rep = []
w = rep.append
w("=" * 78)
w("พิสูจน์ว่า audit หมวด 6 (ตัวเลขในเอกสาร) พลิกสถานะได้")
w("=" * 78)
w("")
w("สูตรข้อ 6: ตัวนับที่ไม่มีวันตอบลบ = ไม่ได้วัดอะไรเลย")
w("จึงต้องเห็นทั้งสถานะที่ผ่านและไม่ผ่าน ไม่ใช่แค่ผ่าน 3 รอบ")
w("")

rc, base = audit_group6()
w("── สถานะตั้งต้น (เอกสารถูกต้อง) ──")
for l in base: w(l)
n_ok = sum(1 for l in base if l.lstrip().startswith("ok"))
w("")
w("ผ่าน %d จาก %d ข้อ" % (n_ok, len(base)))
w("")

w("── ก) แก้ตัวเลขให้ผิดทีละข้อ ต้องจับได้ทุกข้อ ──")
w("")
caught = 0
for name, fn, old, new in CASES:
    s = io.open(fn, encoding="utf-8").read()
    assert old in s, "ไม่พบข้อความที่จะแก้ใน %s: %s" % (fn, old)
    io.open(fn, "w", encoding="utf-8", newline="\n").write(s.replace(old, new, 1))
    rc, lines = audit_group6()
    hit = [l for l in lines if l.lstrip().startswith("FAIL")]
    git_restore(fn)
    ok = len(hit) == 1
    caught += ok
    w("%-26s %s -> %s" % (name, old[:22], new[:22]))
    w("   %s" % ("จับได้" if ok else "🔴 ไม่จับ หรือจับเกินหนึ่งข้อ"))
    for l in hit: w("   " + l.strip())
    w("")

w("จับได้ %d จาก %d ข้อ" % (caught, len(CASES)))
w("")

w("── ข) ลบข้อความที่อ้างตัวเลขทิ้งทั้งหมด ต้องตอบ CANNOT_CHECK ไม่ใช่ ok ──")
w("")
w("นี่คือข้อที่สำคัญที่สุด — ถ้าใครเรียบเรียงประโยคใหม่จน pattern ไม่ match")
w("ตัวตรวจต้องบอกว่าตรวจไม่ได้ ไม่ใช่เงียบแล้วผ่าน (กฎเหล็กข้อ 10)")
w("")
touched = []
for fn in ["CLAUDE.md", "REPORT.md", "thesis/THESIS_TH.md"]:
    s = io.open(fn, encoding="utf-8").read()
    s2 = re.sub(r"\d+\.\d+\s*นาที", "เวลาที่วัดได้", s)
    if s2 != s:
        io.open(fn, "w", encoding="utf-8", newline="\n").write(s2); touched.append(fn)
rc, lines = audit_group6()
for fn in touched: git_restore(fn)
cant = [l for l in lines if "????" in l]
w("ลบคำว่า 'N.N นาที' ออกจาก %d ไฟล์" % len(touched))
for l in cant: w("   " + l.strip())
w("   %s" % ("ตอบ CANNOT_CHECK ถูกต้อง" if len(cant) == 1 else "🔴 ไม่ตอบ CANNOT_CHECK"))
w("")

rc, back = audit_group6()
w("── คืนสภาพแล้ว ──")
for l in back: w(l)
w("")
w("=" * 78)
verdict = (caught == len(CASES) and len(cant) == 1
           and all(l.lstrip().startswith("ok") for l in back))
w("สรุป: %s" % ("ผ่าน — หมวด 6 พลิกได้ทั้ง 3 สถานะ (ok / FAIL / CANNOT_CHECK)"
               if verdict else "🔴 ไม่ผ่าน"))
w("=" * 78)

report = "\n".join(rep) + "\n"
io.open("results/audit_numbers_states.txt", "w", encoding="utf-8", newline="\n").write(report)
print(report)
sys.exit(0 if verdict else 1)
