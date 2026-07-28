#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
QuietFail — ตัวตรวจความพร้อมของ repo ก่อนส่งงานต่อ

    python scripts/audit.py

ทำไมต้องมีไฟล์นี้
-----------------
context window เต็มบ่อย ผู้ช่วยคนถัดไปจึงต้องเชื่อ CLAUDE.md ให้ได้
โดยไม่ต้องไล่ตรวจเองทีละข้อ (ซึ่งกินพื้นที่มหาศาลและทำให้เหลือที่ทำงานจริงน้อยลง)

ไฟล์นี้ยุบการตรวจ 12 หัวข้อให้เหลือคำสั่งเดียว แล้วเขียนผลลง
results/audit_latest.txt ให้อ้างอิงได้

หลักการเดียวกับ score.sql — ตอบ 3 อย่าง ไม่ใช่ 2
    PASS          ตรวจแล้วผ่าน
    FAIL          ตรวจแล้วไม่ผ่าน
    CANNOT_CHECK  ตรวจไม่ได้ (docker ไม่ขึ้น / ไฟล์หาย)  ← ไม่นับว่าผ่าน

**CANNOT_CHECK ไม่ใช่ผ่าน** (กฎเหล็กข้อ 10) — exit code จึงไม่ใช่ 0 ด้วย

exit 0 = ผ่านหมดจริง · exit 1 = มีอย่างน้อยหนึ่งข้อที่ไม่ผ่านหรือตรวจไม่ได้

ข้อควรระวังที่ออกแบบมากันไว้แล้ว
--------------------------------
* เรียก psql ด้วย list ไม่ใช่ string → ไม่ผ่าน shell → ไม่ชนกับดักข้อ 2
  (SQL ที่มี quote ไม่ต้อง escape เพราะไม่มี shell มาตีความ)
* ไม่ใช้ 2>/dev/null ที่ไหนเลย → ไม่ชนกับดักข้อ 1 (E26)
* อ่านอย่างเดียว ไม่ INSERT/UPDATE/DROP อะไรใน qf_corpus
  (score.sql สร้างตาราง score_result ซึ่งเป็นพฤติกรรมปกติของมันอยู่แล้ว)
* ค่าที่ใช้เทียบอยู่ใน scripts/audit_baseline.json ไม่ฝังในโค้ด
"""

import io
import json
import os
import re
import subprocess
import sys
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

PASS, FAIL, CANNOT = "PASS", "FAIL", "CANNOT_CHECK"
results = []   # (หมวด, ชื่อ, สถานะ, รายละเอียด)


def check(group, name, status, detail=""):
    results.append((group, name, status, detail))


def run(args, timeout=300):
    """เรียกคำสั่งแบบไม่ผ่าน shell — คืน (rc, stdout+stderr)"""
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout)
        out = (p.stdout + p.stderr).decode("utf-8", errors="replace")
        return p.returncode, out
    except FileNotFoundError:
        return 127, "ไม่พบคำสั่ง: " + args[0]
    except subprocess.TimeoutExpired:
        return 124, "หมดเวลา"


def psql(sql, timeout=300):
    """รัน SQL หนึ่งบรรทัดแบบ -qAt — คืน (ok, ค่าที่ได้)"""
    rc, out = run(
        ["docker", "compose", "exec", "-T", "db",
         "psql", "-U", "lab", "-d", "faultlab", "-qAt", "-c", sql],
        timeout=timeout,
    )
    return rc == 0, out.strip()


def load_baseline():
    with io.open("scripts/audit_baseline.json", encoding="utf-8") as f:
        return json.load(f)


# ══════════════════════════════════════════════════════════════
# 1. git — หลักฐานถูกเก็บครบไหม
# ══════════════════════════════════════════════════════════════
def check_git(bl):
    g = "1 git"

    rc, out = run(["git", "status", "--porcelain"])
    if rc != 0:
        check(g, "working tree", CANNOT, "รัน git ไม่ได้")
    else:
        # รายงานของตัวเองมี timestamp จึงเปลี่ยนทุกครั้งที่รัน — ไม่นับเป็นไฟล์ค้าง
        # ไม่งั้นตัวตรวจจะทำให้ตัวเองไม่ผ่านตลอดกาล
        dirty = [l for l in out.strip().splitlines()
                 if l.strip() and "results/audit_latest.txt" not in l]
        if dirty:
            # porcelain มีหลายรูปแบบ (' M x', 'M  x', 'MM x', '?? x')
            # ตัดด้วยตำแหน่งคงที่แล้วชื่อไฟล์แหว่ง — ใช้ split แทน
            names = [l.strip().split(None, 1)[-1] for l in dirty[:4]]
            check(g, "working tree", FAIL,
                  "มีไฟล์ค้าง %d รายการ ยังไม่ commit: %s"
                  % (len(dirty), ", ".join(names)))
        else:
            check(g, "working tree", PASS, "สะอาด (ไม่นับรายงานของ audit เอง)")

    rc, tracked = run(["git", "ls-files", "results/"])
    if rc != 0:
        check(g, "results ถูก track", CANNOT, "รัน git ls-files ไม่ได้")
        return
    tracked_set = set(tracked.split())

    on_disk = set()
    for fn in os.listdir("results"):
        p = "results/" + fn
        if os.path.isfile(p) and (fn.endswith(".txt") or
                                  fn.endswith(".json") or fn.endswith(".md")):
            on_disk.add(p)

    intentional = set(bl["results_intentionally_untracked"])
    missing = sorted(on_disk - tracked_set - intentional)
    if missing:
        check(g, "results ถูก track", FAIL,
              "หลักฐานไม่ได้ถูก track: " + ", ".join(missing) +
              "  (results/ อยู่ใน .gitignore ต้อง git add -f)")
    else:
        check(g, "results ถูก track", PASS,
              "%d ไฟล์ · ยกเว้น csv ที่ตั้งใจไม่ track %d ไฟล์"
              % (len(tracked_set), len(intentional)))


# ══════════════════════════════════════════════════════════════
# 2. groundtruth — ครบตามสูตร 6 ข้อไหม
# ══════════════════════════════════════════════════════════════
def check_groundtruth(bl):
    g = "2 groundtruth"
    done = bl["faults_done"]
    need_file = set(bl["checker_states_file_required"])
    exempt = bl["checker_states_file_exempt"]

    bad_parse, bad_field, bad_repro, bad_checker, bad_state_file = [], [], [], [], []
    found = set()

    for fid in done:
        p = "groundtruth/%s.json" % fid.lower()
        if not os.path.exists(p):
            bad_parse.append(fid + " (ไม่มีไฟล์)")
            continue
        try:
            with io.open(p, encoding="utf-8") as f:
                d = json.load(f)
        except Exception as e:
            bad_parse.append("%s (%s)" % (fid, e.__class__.__name__))
            continue
        found.add(fid)

        v = d.get("verified_on", {})
        if "evidence_expectation" not in d or not v.get("date"):
            bad_field.append(fid)

        # สูตรข้อ 6 — ต้องมีหลักฐานว่าตัวตรวจพลิกได้
        if not (v.get("checker_states_verified") or v.get("scorer_states_verified")):
            bad_checker.append(fid)

        rp = d.get("reproduce")
        if rp and not os.path.exists(rp):
            bad_repro.append("%s -> %s" % (fid, rp))

        if fid in need_file and not os.path.exists("sql/%s_checker_states.sql" % fid.lower()):
            bad_state_file.append(fid)

    check(g, "parse ได้ทุกไฟล์", FAIL if bad_parse else PASS,
          ", ".join(bad_parse) if bad_parse else "%d ไฟล์" % len(found))
    check(g, "มี evidence_expectation + verified_on.date",
          FAIL if bad_field else PASS,
          ", ".join(bad_field) if bad_field else "ครบ %d ข้อ" % len(found))
    check(g, "ไฟล์ที่ reproduce ชี้ไปมีจริง", FAIL if bad_repro else PASS,
          ", ".join(bad_repro) if bad_repro else "ครบ %d ข้อ" % len(found))
    check(g, "สูตรข้อ 6 — พิสูจน์ว่าตัวตรวจพลิกได้",
          FAIL if bad_checker else PASS,
          ("ยังไม่มีหลักฐาน: " + ", ".join(bad_checker)) if bad_checker
          else "ครบ %d ข้อ (ยกเว้นที่ระบุใน baseline %d ข้อ)" % (len(found), len(exempt)))
    check(g, "มีไฟล์ *_checker_states.sql ตามที่ baseline กำหนด",
          FAIL if bad_state_file else PASS,
          ", ".join(bad_state_file) if bad_state_file
          else "ครบ %d ข้อ" % len(need_file))


# ══════════════════════════════════════════════════════════════
# 3. เอกสาร — สามแหล่งพูดตรงกันไหม
# ══════════════════════════════════════════════════════════════
def read(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def check_docs(bl):
    g = "3 เอกสาร"
    done = set(bl["faults_done"])
    remaining = set(bl["faults_remaining"])

    # E/D ที่ถูกอ้าง ต้องมีนิยามใน DECISIONS.md
    try:
        dec = read("DECISIONS.md")
    except IOError:
        check(g, "E/D ที่ถูกอ้างมีนิยาม", CANNOT, "อ่าน DECISIONS.md ไม่ได้")
        dec = ""
    if dec:
        defined = set(re.findall(r"^#{1,4}\s*([ED]\d{2})\b", dec, re.M))
        defined |= set(re.findall(r"^\|\s*\*{0,2}([ED]\d{2})\*{0,2}\s*\|", dec, re.M))
        used = {}
        for fn in ["CLAUDE.md", "FAULTS.md", "PROJECT.md", "EVIDENCE.md",
                   "README.md", "results/README.md"]:
            if not os.path.exists(fn):
                continue
            for r in set(re.findall(r"\b([ED]\d{2})\b", read(fn))):
                used.setdefault(r, []).append(fn)
        dangling = sorted(k for k in used if k not in defined)
        check(g, "E/D ที่ถูกอ้างมีนิยาม", FAIL if dangling else PASS,
              ("อ้างลอย: " + ", ".join(dangling)) if dangling
              else "%d ตัว อ้างครบทุกตัว" % len(defined))

        # เลข E/D ซ้ำอันตรายกว่าอ้างลอย — อ้างลอยมีคนสังเกต แต่ซ้ำจะชี้ไปผิดที่เงียบๆ
        # (เกิดจริงแล้ว: E33 ถูกใช้สองครั้ง ตอนทำ I02 กับตอนทำ L02)
        heads = re.findall(r"^#{1,4}\s*([ED]\d{2})\b", dec, re.M)
        dup = sorted({h for h in heads if heads.count(h) > 1})
        check(g, "เลข E/D ไม่ซ้ำกัน", FAIL if dup else PASS,
              ("ซ้ำ: " + ", ".join(dup) + " — การอ้างถึงจะชี้ไปผิดที่โดยไม่มีอะไรเตือน")
              if dup else "%d หัวข้อ ไม่มีเลขซ้ำ" % len(heads))

    # CLAUDE.md บรรทัดสถานะ ต้องตรงกับ baseline
    try:
        cl = read("CLAUDE.md")
    except IOError:
        check(g, "สถานะใน CLAUDE.md ตรงกับ baseline", CANNOT, "อ่าน CLAUDE.md ไม่ได้")
        return

    # ⚠️ ห้ามค้นคำว่า "เหลือ" ทั้งไฟล์ — คำนี้โผล่ในประโยคทั่วไปได้
    #    (เคยไปโดน "จนเหลือที่ทำงานจริงน้อยลง" ในย่อหน้าอื่นมาแล้ว)
    #    ต้องเกาะบรรทัด "กำลังทำ :" ในบล็อกสถานะเท่านั้น
    #    รูปแบบเดียวกับกฎเหล็กข้อ 6 — อ่านโครงสร้าง ไม่ใช่ค้นข้อความลอยๆ
    mline = re.search(r"^กำลังทำ\s*:.*$", cl, re.M)
    if not mline:
        check(g, "สถานะใน CLAUDE.md ตรงกับ baseline", CANNOT,
              "หาบรรทัดที่ขึ้นต้นด้วย 'กำลังทำ :' ในบล็อกสถานะไม่เจอ")
        return
    line = mline.group(0)
    claimed_done = set(re.findall(r"\b([IQVLF]\d{2})\s*✅", line))
    m = re.search(r"เหลือ(.+)$", line)
    claimed_left = set(re.findall(r"\b([IQVLF]\d{2})\b", m.group(1))) if m else set()

    phase3_done = {f for f in done if f[0] in "IQVL"}
    if claimed_done == phase3_done and claimed_left == remaining:
        check(g, "สถานะใน CLAUDE.md ตรงกับ baseline", PASS,
              "เสร็จ %d · เหลือ %s" % (len(claimed_done), " ".join(sorted(remaining))))
    else:
        check(g, "สถานะใน CLAUDE.md ตรงกับ baseline", FAIL,
              "CLAUDE.md บอกเสร็จ %s เหลือ %s · baseline บอกเสร็จ %s เหลือ %s"
              % (sorted(claimed_done), sorted(claimed_left),
                 sorted(phase3_done), sorted(remaining)))

    # ---- ตารางของส่งมอบใน CLAUDE.md ----
    #
    # หัวข้อนี้มีเพราะเคยพลาดจริง: บล็อกสถานะเขียนว่า "งานถัดไปคือเขียนรายงาน"
    # ทั้งที่ REPORT.md เขียนเสร็จและ commit ไปแล้ว — session ใหม่จะสร้างของซ้ำ
    #
    # ตรวจสามทาง เพราะเก่าได้สองทิศ:
    #   ก) ตาราง CLAUDE.md ตรงกับ baseline ไหม
    #   ข) ข้อที่ติ๊กว่าเสร็จ มีไฟล์ครบไหม        (ติ๊กเกินจริง)
    #   ค) ข้อที่ยังไม่ติ๊ก มีไฟล์โผล่มาแล้วไหม   (ทำเสร็จแล้วลืมอัปเดต ← เคสที่เคยเกิด)
    dl = bl.get("deliverables", {})
    if not dl:
        check(g, "ตารางของส่งมอบใน CLAUDE.md", CANNOT,
              "baseline ไม่มีหัวข้อ deliverables — เทียบไม่ได้")
    else:
        rows = dict(re.findall(r"^\|\s*(\d+)\s*\|[^|\n]*\|\s*(✅|⬜)", cl, re.M))
        if not rows:
            check(g, "ตารางของส่งมอบใน CLAUDE.md", CANNOT,
                  "หาตารางของส่งมอบใน CLAUDE.md ไม่เจอ (แถวขึ้นต้นด้วยเลขแล้วมี ✅/⬜)")
        else:
            problems = []
            for num, spec in sorted(dl.items()):
                want_done = bool(spec.get("done"))
                mark = rows.get(num)
                if mark is None:
                    problems.append("ข้อ %s ไม่มีในตาราง CLAUDE.md" % num)
                    continue
                if (mark == "✅") != want_done:
                    problems.append("ข้อ %s: CLAUDE.md ติ๊ก %s แต่ baseline บอก done=%s"
                                    % (num, mark, want_done))
                arts = spec.get("artifacts", [])
                have = [a for a in arts if os.path.exists(a)]
                if want_done and len(have) < len(arts):
                    problems.append("ข้อ %s ติ๊กว่าเสร็จ แต่ไม่มีไฟล์: %s"
                                    % (num, ", ".join(a for a in arts if a not in have)))
                if (not want_done) and have:
                    problems.append("ข้อ %s ยังไม่ติ๊กว่าเสร็จ แต่มีไฟล์แล้ว: %s "
                                    "— ทำเสร็จแล้วลืมอัปเดตหรือเปล่า" % (num, ", ".join(have)))
            check(g, "ตารางของส่งมอบใน CLAUDE.md", FAIL if problems else PASS,
                  " · ".join(problems) if problems
                  else "%d ข้อตรงกับ baseline · ไฟล์สอดคล้องทุกข้อ" % len(dl))

    # ห้ามมี fault ที่ตัดไปแล้วโผล่กลับมาเป็นข้อที่ต้องทำ
    cut = ["Q05", "L01", "V08"]
    back = [c for c in cut if re.search(r"%s\s*✅" % c, cl)]
    check(g, "fault ที่ตัดแล้วไม่กลับมา", FAIL if back else PASS,
          ("โผล่กลับ: " + ", ".join(back)) if back
          else "Q05 L01 V08 ยังถูกตัดอยู่ (D15)")


# ══════════════════════════════════════════════════════════════
# 4. ฐานข้อมูล — สภาพตรงกับที่ CLAUDE.md เขียนไว้ไหม
# ══════════════════════════════════════════════════════════════
def check_db(bl):
    g = "4 ฐานข้อมูล"
    d = bl["db"]

    ok, _ = psql("SELECT 1", timeout=60)
    if not ok:
        check(g, "เชื่อมต่อ docker/psql", CANNOT,
              "docker compose ไม่ขึ้น หรือ container db ไม่ทำงาน — ตรวจ DB ไม่ได้เลย")
        return False
    check(g, "เชื่อมต่อ docker/psql", PASS, "ต่อได้")

    def one(label, sql, want, fmt=str):
        ok, got = psql(sql)
        if not ok:
            check(g, label, CANNOT, got.splitlines()[-1] if got else "query ล้ม")
            return
        got = got.strip()
        if got == fmt(want):
            check(g, label, PASS, got)
        else:
            check(g, label, FAIL, "ได้ %s · ต้องเป็น %s" % (got, want))

    one("qf_corpus จำนวนแถว",
        "SELECT count(*) FROM %s" % d["corpus_table"], d["corpus_rows"])
    one("qf_corpus มิติ",
        "SELECT max(vector_dims(embedding)) FROM %s" % d["corpus_table"], d["corpus_dim"])
    one("qf_corpus fingerprint (5,000 แถวแรก)",
        "SELECT md5(string_agg(embedding::text,'|' ORDER BY id)) FROM "
        "(SELECT id,embedding FROM %s ORDER BY id LIMIT 5000) s" % d["corpus_table"],
        d["corpus_fingerprint_first5k"])
    one("qf_truth จำนวนแถว", "SELECT count(*) FROM qf_truth", d["truth_rows"])
    one("orders จำนวนแถว", "SELECT count(*) FROM orders", d["orders_rows"])
    one("ไม่มี vector index ค้าง",
        "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid "
        "JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat')",
        d["leftover_vector_indexes"])
    one("maintenance_work_mem",
        "SELECT current_setting('maintenance_work_mem')", d["maintenance_work_mem"])

    ok, got = psql("SELECT version()")
    if ok and d["postgres_version_like"] in got:
        check(g, "PostgreSQL เวอร์ชัน", PASS, d["postgres_version_like"])
    else:
        check(g, "PostgreSQL เวอร์ชัน", FAIL, got[:80])

    ok, got = psql("SELECT extversion FROM pg_extension WHERE extname='vector'")
    if ok and got.strip() == d["pgvector_version"]:
        check(g, "pgvector เวอร์ชัน", PASS, got.strip())
    else:
        check(g, "pgvector เวอร์ชัน", FAIL, "ได้ %s · ต้องเป็น %s"
              % (got.strip(), d["pgvector_version"]))
    return True


# ══════════════════════════════════════════════════════════════
# 5. score.sql — ตัวนับคะแนนยังรันได้ครบทุกสาขาไหม
# ══════════════════════════════════════════════════════════════
def check_scorer(bl):
    g = "5 score.sql"
    rc, out = run(
        ["docker", "compose", "exec", "-T", "db",
         "psql", "-U", "lab", "-d", "faultlab", "-v", "ON_ERROR_STOP=1",
         "-f", "/sql/score.sql"],
        timeout=600,
    )
    if rc != 0:
        tail = [l for l in out.splitlines() if l.strip()][-3:]
        check(g, "รันจบไม่มี error", FAIL, " / ".join(tail))
        return
    check(g, "รันจบไม่มี error", PASS, "exit 0")

    verdicts = {}
    for fid in bl["faults_done"]:
        m = re.search(r"^\s*%s\s*\|\s*(DETECTED|NOT_DETECTED|CANNOT_CHECK)" % fid,
                      out, re.M)
        if m:
            verdicts[fid] = m.group(1)

    missing = [f for f in bl["faults_done"] if f not in verdicts]
    if missing:
        check(g, "ทุก fault มีสาขาที่ตอบได้", FAIL,
              "ไม่มีคำตอบให้: " + ", ".join(missing))
    else:
        check(g, "ทุก fault มีสาขาที่ตอบได้", PASS,
              "%d/%d ข้อ" % (len(verdicts), bl["score_expected_rows"]))

    # ไม่ยืนยันการกระจายตัวของ verdict เป็นเงื่อนไขผ่าน
    # เพราะ Q02 อ่าน pg_stat_statements ซึ่งเปลี่ยนตามประวัติการรัน
    # รายงานไว้เฉยๆ ให้คนอ่านเทียบกับตาราง "สภาพสะอาด" ใน CLAUDE.md
    summary = " · ".join("%s=%s" % (k, v) for k, v in sorted(verdicts.items()))
    check(g, "verdict ที่ได้ตอนนี้ (ข้อมูล ไม่ใช่เกณฑ์)", PASS, summary)


# ══════════════════════════════════════════════════════════════
# รายงาน
# ══════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════
# โหมด --reproduce : รันตัวฉีดจริงซ้ำ ไม่ใช่แค่ดูว่าหลักฐานมีอยู่
#
# audit ปกติ **ไม่รัน fault ซ้ำ** — มันยืนยันว่าหลักฐานมีอยู่และครบรูปแบบ
# เท่านั้น โหมดนี้มีไว้ตอบคำถามที่ audit ปกติตอบไม่ได้:
#   "ผลที่บันทึกไว้ ยังเกิดซ้ำได้จริงไหม"
#
# แยกออกมาเพราะแพง (รวมกันเกิน 20 นาที) จึงไม่ควรรวมในการตรวจทุกครั้ง
# ══════════════════════════════════════════════════════════════
def run_reproduce(bl, want):
    rep = bl.get("reproduce", {})
    manual = bl.get("reproduce_manual_only", {})

    if want in ("", "all", None):
        targets = list(rep.keys())
    else:
        targets = [t.strip().upper() for t in want.split(",") if t.strip()]

    lines = []

    # เขียนไฟล์ใหม่ทุกครั้งที่มีบรรทัดเพิ่ม — โหมดนี้ใช้เวลาเกิน 20 นาที
    # ถ้าเขียนตอนจบอย่างเดียว จะดูความคืบหน้าไม่ได้เลยระหว่างรอ
    # และถ้าถูกตัดกลางคันจะไม่เหลือหลักฐานว่าไปถึงไหนแล้ว
    def w(s=""):
        lines.append(s)
        f = io.open("results/audit_reproduce.txt", "w",
                    encoding="utf-8", newline="\n")
        f.write("\n".join(lines) + "\n")
        f.close()

    rc_h, head = run(["git", "rev-parse", "--short", "HEAD"])
    w("=" * 78)
    w("QuietFail — รันตัวฉีดจริงซ้ำ (--reproduce)")
    w("รันเมื่อ : %s" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    w("commit  : %s" % (head.strip() if rc_h == 0 else "(อ่านไม่ได้)"))
    w("=" * 78)
    w("")
    w("โหมดนี้ตอบคำถามที่ audit ปกติตอบไม่ได้ — 'ผลยังเกิดซ้ำได้จริงไหม'")
    w("สำเร็จ = exit 0 เพราะทุกสคริปต์ใช้ ON_ERROR_STOP และ RAISE EXCEPTION เมื่อ assertion ตก")
    w("(อ่าน exit code ไม่ใช่ค้นข้อความใน output — กฎเหล็กข้อ 6)")
    w("")

    unknown = [t for t in targets if t not in rep]
    if unknown:
        w("!! ไม่รู้จัก: %s" % ", ".join(unknown))
        for u in unknown:
            if u in manual:
                w("   %s รันอัตโนมัติไม่ได้ — %s" % (u, manual[u]))
        w("")
        targets = [t for t in targets if t in rep]

    est = sum(rep[t].get("minutes", 0) for t in targets)
    w("จะรัน %d ข้อ: %s  (ประมาณ %d นาที)" % (len(targets), " ".join(targets), est))
    w("")

    ok, before = psql(
        "SELECT count(*)||'|'||md5(string_agg(embedding::text,'|' ORDER BY id)) "
        "FROM (SELECT id,embedding FROM qf_corpus ORDER BY id LIMIT 5000) s")
    if not ok:
        w("!! ต่อ DB ไม่ได้ — รันไม่ได้")
        return lines, 1
    w("qf_corpus ก่อนรัน : %s" % before)
    w("")

    n_fail = 0
    for fid in targets:
        script = rep[fid]["script"]
        w("── %s : %s ──" % (fid, script))
        t0 = datetime.now()
        rc, out = run(
            ["docker", "compose", "exec", "-T", "db", "psql", "-U", "lab",
             "-d", "faultlab", "-f", "/" + script],
            timeout=1800)
        secs = (datetime.now() - t0).total_seconds()

        # สคริปต์แต่ละข้อใช้เครื่องหมายต่างกัน (V07 ใช้ 'OK' · I04 ใช้ '✅')
        # จึงนับจากโครงสร้าง [i/n] ที่ทุกข้อใช้เหมือนกัน ไม่ใช่จากคำที่ตามหลัง
        # และตัวชี้ขาดจริงคือ exit code ไม่ใช่ตัวเลขนี้
        marks = re.findall(r"\[(\d+)/(\d+)\]", out)
        n_ok = len(marks)
        total = marks[0][1] if marks else "?"
        if rc == 0:
            w("   ok   exit 0 · assertion %s/%s ข้อ · %.0f วินาที" % (n_ok, total, secs))
        else:
            n_fail += 1
            tail = [l for l in out.splitlines() if l.strip()][-3:]
            w("   FAIL exit %s · %.0f วินาที" % (rc, secs))
            for l in tail:
                w("        %s" % l[:150])
        w("")

    ok, after = psql(
        "SELECT count(*)||'|'||md5(string_agg(embedding::text,'|' ORDER BY id)) "
        "FROM (SELECT id,embedding FROM qf_corpus ORDER BY id LIMIT 5000) s")
    ok2, idx = psql(
        "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid "
        "JOIN pg_am am ON am.oid=c.relam WHERE am.amname IN ('hnsw','ivfflat')")

    w("qf_corpus หลังรัน : %s" % after)
    if after != before:
        n_fail += 1
        w("!! 🔴 qf_corpus เปลี่ยน — ฐานของเฉลยทั้งโปรเจคเสียหาย ต้องสร้างใหม่")
    else:
        w("   ok   qf_corpus ไม่เปลี่ยน")
    if idx.strip() not in ("0", ""):
        n_fail += 1
        w("!! vector index ค้าง %s ตัว — ต้องเก็บกวาดก่อนวัดอะไรต่อ" % idx.strip())
    else:
        w("   ok   ไม่มี vector index ค้าง")

    w("")
    w("=" * 78)
    if n_fail == 0:
        w("✅ ตัวฉีดที่รัน เกิดซ้ำได้ทุกข้อ · qf_corpus ไม่ถูกแตะ")
    else:
        w("❌ มี %d ข้อที่ไม่ผ่าน — ผลที่บันทึกไว้อาจใช้ไม่ได้แล้ว" % n_fail)
    w("")
    w("ยังไม่ครอบคลุม (ต้องรันด้วยมือ เพราะต้องหลาย session หรือต้องตั้ง env):")
    for k, v in sorted(manual.items()):
        w("  %s  %s" % (k, v))
    w("=" * 78)
    return lines, (0 if n_fail == 0 else 1)


def main():
    bl = load_baseline()

    if "--reproduce" in sys.argv:
        i = sys.argv.index("--reproduce")
        want = sys.argv[i + 1] if len(sys.argv) > i + 1 else "all"
        lines, rc = run_reproduce(bl, want)
        report = "\n".join(lines) + "\n"
        out = io.open("results/audit_reproduce.txt", "w",
                      encoding="utf-8", newline="\n")
        out.write(report)
        out.close()
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
        try:
            sys.stdout.write(report)
        except UnicodeEncodeError:
            enc = sys.stdout.encoding or "ascii"
            sys.stdout.write(report.encode(enc, "replace").decode(enc, "replace"))
        return rc

    check_git(bl)
    check_groundtruth(bl)
    check_docs(bl)
    if check_db(bl):
        check_scorer(bl)
    else:
        check("5 score.sql", "รันจบไม่มี error", CANNOT, "DB ต่อไม่ได้")

    lines = []
    w = lambda s="": lines.append(s)

    rc_h, head = run(["git", "rev-parse", "--short", "HEAD"])
    head = head.strip() if rc_h == 0 else "(อ่านไม่ได้)"
    rc_s, subj = run(["git", "log", "-1", "--pretty=%s"])
    subj = subj.strip() if rc_s == 0 else ""

    w("=" * 78)
    w("QuietFail — ตรวจความพร้อมของ repo")
    w("รันเมื่อ : %s" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    w("commit  : %s  %s" % (head, subj[:52]))
    w("baseline: scripts/audit_baseline.json (_updated = %s)" % bl.get("_updated"))
    w("=" * 78)
    w()
    w("วิธีใช้รายงานนี้แทนการตรวจเอง")
    w("  1. เทียบ commit ข้างบนกับ  git rev-parse --short HEAD")
    w("  2. ตรงกัน + ข้างล่างเขียน 'ผ่านครบทุกข้อ' = เชื่อ CLAUDE.md ได้เลย ไม่ต้องตรวจซ้ำ")
    w("  3. ไม่ตรงกัน = มีอะไรเปลี่ยนหลัง audit ให้รัน  python scripts/audit.py  ใหม่")
    w()

    cur = None
    for group, name, status, detail in results:
        if group != cur:
            cur = group
            w("── %s ──" % group)
        mark = {PASS: "  ok  ", FAIL: " FAIL ", CANNOT: " ???? "}[status]
        w("%s %-46s %s" % (mark, name, detail))
    w()

    n_pass = sum(1 for r in results if r[2] == PASS)
    n_fail = sum(1 for r in results if r[2] == FAIL)
    n_cant = sum(1 for r in results if r[2] == CANNOT)

    w("=" * 78)
    w("ผ่าน %d · ไม่ผ่าน %d · ตรวจไม่ได้ %d   (รวม %d)"
      % (n_pass, n_fail, n_cant, len(results)))

    if n_fail == 0 and n_cant == 0:
        w()
        w("✅ ผ่านครบทุกข้อ — CLAUDE.md เชื่อถือได้ ณ เวลาที่รัน")
        w("   ผู้ช่วยคนถัดไปไม่ต้องไล่ตรวจซ้ำทีละข้อ")
        rc = 0
    else:
        w()
        w("❌ ยังไม่พร้อม — แก้ให้ครบก่อนถือว่า CLAUDE.md เชื่อถือได้")
        w("   'ตรวจไม่ได้' ไม่ใช่ 'ผ่าน' (กฎเหล็กข้อ 10)")
        rc = 1
    w("=" * 78)

    report = "\n".join(lines) + "\n"

    # ไฟล์เขียนเป็น UTF-8 เสมอ ไม่ขึ้นกับ codepage ของ console
    out = io.open("results/audit_latest.txt", "w", encoding="utf-8", newline="\n")
    out.write(report)
    out.close()

    # PowerShell 5.1 ใช้ codepage ระบบ (cp874 บนเครื่องไทย) เขียนไทยตรงๆ แล้ว crash
    # ตัวตรวจที่ crash เพราะภาษาของรายงานตัวเอง = ใช้ไม่ได้ตั้งแต่ต้น
    try:
        sys.stdout.reconfigure(encoding="utf-8")   # Python 3.7+
    except Exception:
        pass
    try:
        sys.stdout.write(report)
    except UnicodeEncodeError:
        enc = sys.stdout.encoding or "ascii"
        sys.stdout.write(report.encode(enc, "replace").decode(enc, "replace"))
        sys.stdout.write(
            "\n(console แสดงภาษาไทยไม่ได้ — อ่านฉบับเต็มที่ "
            "results/audit_latest.txt ซึ่งเป็น UTF-8 เสมอ)\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())
