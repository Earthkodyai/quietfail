#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RQ3 — ให้คะแนน SQL ที่โมเดลเขียน โดย **รันจริง** ไม่ใช่ดูรูปแบบ

    python scripts/rq3_score.py rq3/answers/<ชื่อชุด>

โครงสร้างที่ต้องมี
------------------
    rq3/answers/<ชื่อชุด>/P01.sql
    rq3/answers/<ชื่อชุด>/P02.sql   ...

ทำไมต้องรันจริง
---------------
กฎเหล็กข้อ 6 ของโปรเจคนี้: **ห้าม match ข้อความ ให้อ่านโครงสร้าง**
ตัวให้คะแนนที่ดู regex ว่า "มี ORDER BY ไหม" จะแพ้ SQL ที่เขียนถูกรูปแต่ผลยังหาย
(Q03 พิสูจน์แล้ว: `WHERE ... ORDER BY ... LIMIT 10` ถูกรูปทุกอย่าง แต่คืน 0 แถว)

จึงวัดสิ่งเดียวที่เถียงไม่ได้: **รันแล้วได้แถวครบไหม และตรงกับ exact search ไหม**

เกณฑ์ต่อข้อประกาศไว้ใน rq3/prompts.json ไม่ได้ฝังในโค้ด

⚠️ ไม่แตะ qf_corpus — ทำงานบนตาราง documents ที่ rq3_setup.sql สร้าง
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


def psql(sql, timeout=300):
    """รัน SQL แบบ -qAt · ไม่ผ่าน shell จึงไม่ต้อง escape quote (กับดักข้อ 2)"""
    p = subprocess.run(
        ["docker", "compose", "exec", "-T", "db", "psql", "-U", "lab",
         "-d", "faultlab", "-qAt", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, timeout=timeout)
    out = (p.stdout + p.stderr).decode("utf-8", errors="replace")
    return p.returncode, out.strip()


def psql_file(path, timeout=600):
    p = subprocess.run(
        ["docker", "compose", "exec", "-T", "db", "psql", "-U", "lab",
         "-d", "faultlab", "-qAt", "-v", "ON_ERROR_STOP=1", "-f", "/" + path],
        capture_output=True, timeout=timeout)
    out = (p.stdout + p.stderr).decode("utf-8", errors="replace")
    return p.returncode, out.strip()


def reference_ids(where_sql, k, qid=1):
    """เฉลย: exact search ด้วยวิธีที่เอกสาร pgvector แนะนำเอง"""
    w = ("WHERE " + where_sql) if where_sql else ""
    rc, out = psql(
        "BEGIN; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off; "
        "SELECT string_agg(id::text, ',' ORDER BY id) FROM ("
        "SELECT d.id FROM documents d %s "
        "ORDER BY d.embedding <=> (SELECT embedding FROM search_queries WHERE id = %d) "
        "LIMIT %d) s; COMMIT;" % (w, qid, k))
    if rc != 0:
        return None
    ids = [l for l in out.splitlines() if l and "," in l or (l and l.isdigit())]
    return set(ids[-1].split(",")) if ids else set()


def run_candidate(sql_text):
    """
    รัน SQL ของโมเดลใน transaction ที่ ROLLBACK เสมอ
    แล้วคืน (ok, รายการ id ที่ได้, ข้อความ error)

    ROLLBACK เพราะโจทย์บางข้อให้สร้าง index — ห้ามทิ้ง state ค้าง (กับดักข้อ 4)
    """
    # ต้องเขียนลง sql/ เพราะเป็นโฟลเดอร์เดียวที่ mount เข้า container (`./sql:/sql:ro`)
    # และเขียน path ด้วย / เสมอ — os.path.join บน Windows ให้ \ ซึ่ง psql ใน container หาไม่เจอ
    tmp = "sql/_rq3_candidate.sql"
    io.open(tmp, "w", encoding="utf-8", newline="\n").write(sql_text)
    rc, out = psql_file(tmp)
    try:
        os.remove(tmp)
    except OSError:
        pass
    return rc, out


HARNESS_ERR = ("No such file or directory", "could not open", "Permission denied")


def is_harness_error(out):
    """แยก 'ตัวให้คะแนนพัง' ออกจาก 'SQL ของโมเดลผิด'

    เคยพลาดจริง: เขียนไฟล์ผิดที่ แล้วรายงานว่าติดกับดัก 10/10
    ทั้งที่ไม่ได้รัน SQL เลยสักบรรทัด — ตัวให้คะแนนที่มั่นใจผิดอันตรายกว่าตัวที่เงียบ
    """
    return any(m in out for m in HARNESS_ERR)


def split_prelude(sql_text):
    """
    แยกคำสั่งนำหน้า (SET / CREATE INDEX / ฯลฯ) ออกจาก SELECT ตัวสุดท้าย

    จำเป็นเพราะโมเดลมักตอบเป็นหลายคำสั่ง เช่น
        SET hnsw.ef_search = 400;
        SELECT ...
    รุ่นแรกยัดทั้งก้อนใส่ `CREATE TEMP TABLE ... AS` แล้วพัง
    → ตีคำตอบที่ **ถูกต้อง** ว่าติดกับดัก ซึ่งกลับหัวจากความจริง
    """
    parts = [p.strip() for p in sql_text.split(";")]
    parts = [p for p in parts if p and not all(
        l.strip().startswith("--") or not l.strip() for l in p.splitlines())]
    if not parts:
        return "", ""
    return ";\n".join(parts[:-1]) + (";\n" if len(parts) > 1 else ""), parts[-1]


def check_rows_and_recall(spec, sql_text, where_for_ref):
    k = spec["expect_rows"]
    ref = reference_ids(where_for_ref, k)
    if ref is None:
        return CANNOT, "หาเฉลยไม่ได้", {}

    prelude, query = split_prelude(sql_text)
    if not query:
        return CANNOT, "ไฟล์คำตอบว่าง", {}
    wrapped = ("BEGIN;\n" + prelude +
               "CREATE TEMP TABLE rq3_got AS\n" + query + ";\n"
               "SELECT count(*) FROM rq3_got;\n"
               "SELECT string_agg(id::text, ',' ORDER BY id) FROM rq3_got;\n"
               "ROLLBACK;\n")
    rc, out = run_candidate(wrapped)
    if rc != 0:
        tail = [l for l in out.splitlines() if l.strip()][-1:]
        msg = tail[0][:110] if tail else "?"
        if is_harness_error(out):
            return CANNOT, "ตัวให้คะแนนเองรันไม่ได้: " + msg, {}
        return FAIL, "SQL รันไม่ผ่าน: " + msg, {"error": True}

    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        return CANNOT, "ไม่มี output", {}
    try:
        n = int(lines[0])
    except ValueError:
        return CANNOT, "อ่านจำนวนแถวไม่ได้: " + lines[0][:60], {}

    got = set(lines[1].split(",")) if len(lines) > 1 and lines[1] else set()
    hit = len(got & ref)
    recall = hit / float(k) if k else 0.0

    ok_rows = (n >= k)
    ok_recall = (recall >= spec.get("min_recall", 1.0))
    detail = "ได้ %d/%d แถว · recall %.2f (ต้อง >= %.2f)" % (
        n, k, recall, spec.get("min_recall", 1.0))
    return (PASS if (ok_rows and ok_recall) else FAIL), detail, {
        "rows": n, "expect": k, "recall": round(recall, 4)}


def vector_indexes():
    rc, out = psql(
        "SELECT coalesce(string_agg(c.relname || '=' || o.opcname, ','), '') "
        "FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid "
        "JOIN pg_class t ON t.oid = i.indrelid JOIN pg_am am ON am.oid = c.relam "
        "JOIN pg_opclass o ON o.oid = i.indclass[0] "
        "WHERE t.relname = 'documents' AND am.amname IN ('hnsw','ivfflat');")
    return set(x for x in out.strip().split(",") if x) if rc == 0 else set()


def check_index_created(spec, sql_text):
    """
    โจทย์ P06 — ให้สร้าง index เอง · ตรวจ opclass จาก catalog ไม่ใช่จากข้อความ

    ⚠️ ต้องดูเฉพาะ index ที่ **โมเดลสร้างใหม่** ไม่ใช่ทุก index บนตาราง
    เพราะแอปมี index cosine อยู่ก่อนแล้ว ถ้านับรวมมันจะบัง opclass ผิดของโมเดล
    แล้วรายงานว่าผ่านทั้งที่ตก (เจอตอนพิสูจน์ตัวให้คะแนน)

    ⚠️ และต้อง **คืน index ของแอปกลับ** หลังเก็บกวาด
    รุ่นแรกลบทิ้งหมด ทำให้โจทย์ข้อถัดๆ ไปรันแบบไม่มี index แล้วผ่านหมดโดยไม่มีอะไรเตือน
    """
    before = vector_indexes()
    rc, out = run_candidate(sql_text)
    if rc != 0:
        tail = [l for l in out.splitlines() if l.strip()][-1:]
        msg = tail[0][:110] if tail else "?"
        if is_harness_error(out):
            return CANNOT, "ตัวให้คะแนนเองรันไม่ได้: " + msg, {}
        return FAIL, "SQL รันไม่ผ่าน: " + msg, {"error": True}

    after = vector_indexes()
    created = after - before
    want = spec["expect_opclass"]
    opcs = sorted(x.split("=")[1] for x in created)
    ok = bool(created) and all(o == want for o in opcs)

    # เก็บกวาดเฉพาะที่โมเดลสร้าง — ห้ามแตะ index ของแอป (กับดักข้อ 4)
    for x in created:
        psql("DROP INDEX IF EXISTS " + x.split("=")[0] + ";")

    if not created:
        detail = "ไม่ได้สร้าง vector index เลย"
    else:
        detail = "สร้างใหม่ %d ตัว opclass = %s (ต้องเป็น %s)" % (
            len(created), ",".join(opcs), want)
    return (PASS if ok else FAIL), detail, {"opclass": opcs}


def check_null_zero_guard(spec, sql_text):
    """
    โจทย์ P09 — ต้องจับทั้ง NULL และ zero vector
    วิธีวัด: ใส่แถวเสียเข้าไปชั่วคราว แล้วดูว่า SQL ของโมเดลนับเจอครบไหม
    ทุกอย่างอยู่ใน transaction ที่ ROLLBACK
    """
    wrapped = (
        "BEGIN;\n"
        "INSERT INTO documents (id, category, title, embedding) VALUES\n"
        "  (9000001, 'general', 'bad-null', NULL),\n"
        "  (9000002, 'general', 'bad-zero', array_fill(0, ARRAY[384])::vector);\n"
        + split_prelude(sql_text)[0] +
        "CREATE TEMP TABLE rq3_got AS\n" + split_prelude(sql_text)[1] + ";\n"
        "SELECT count(*) FROM rq3_got;\n"
        "ROLLBACK;\n")
    rc, out = run_candidate(wrapped)
    if rc != 0:
        tail = [l for l in out.splitlines() if l.strip()][-1:]
        msg = tail[0][:110] if tail else "?"
        if is_harness_error(out):
            return CANNOT, "ตัวให้คะแนนเองรันไม่ได้: " + msg, {}
        return FAIL, "SQL รันไม่ผ่าน: " + msg, {"error": True}
    lines = [l for l in out.splitlines() if l.strip()]
    try:
        n = int(lines[0])
    except (ValueError, IndexError):
        return CANNOT, "อ่านผลไม่ได้", {}
    # ต้องเจอ 2 แถว: NULL หนึ่ง zero หนึ่ง · เจอ 1 = จับได้แค่ NULL
    return (PASS if n >= 2 else FAIL), \
           "จับแถวเสียได้ %d จาก 2 (NULL + zero)" % n, {"caught": n}


WHERE_FOR = {
    "P01": "", "P02": "d.category = 'archive'", "P03": "",
    "P04": "d.category = 'legal'", "P05": "", "P07": "d.category = 'finance'",
    "P08": "d.category = 'archive'", "P10": "d.category IN ('support','product')",
}


def main():
    if len(sys.argv) < 2:
        print("ใช้: python scripts/rq3_score.py rq3/answers/<ชื่อชุด>")
        return 2
    adir = sys.argv[1].rstrip("/\\")
    label = os.path.basename(adir)

    with io.open("rq3/prompts.json", encoding="utf-8") as f:
        prompts = json.load(f)["prompts"]

    rc, _ = psql("SELECT 1 FROM documents LIMIT 1;")
    if rc != 0:
        print("ตาราง documents ไม่มี — รัน sql/rq3_setup.sql ก่อน")
        return 1

    # 🔴 ด่านสำคัญที่สุดของไฟล์นี้
    #
    # ถ้าไม่มี index ทุก query จะเป็น exact search แล้วได้ผลถูกหมด
    # → ตัวให้คะแนนจะรายงานว่า "ไม่ติดกับดักเลย" ซึ่งเป็นข่าวดีที่ผิด
    #
    # เกิดขึ้นจริงแล้วครั้งหนึ่ง: การเก็บกวาดของ P06 ลบ index ของแอปทิ้ง
    # แล้วรอบถัดมาให้คะแนนผ่านหมดโดยไม่มีอะไรเตือน
    # ตระกูลเดียวกับ E35 — ตัวตรวจวัดคนละอย่างกับที่ตั้งใจ แล้วเงียบ
    if not vector_indexes():
        print("🔴 ตาราง documents ไม่มี vector index — ให้คะแนนไม่ได้")
        print("   ถ้ารันต่อ ทุก query จะเป็น exact search แล้วผ่านหมดโดยไม่มีความหมาย")
        print("   แก้: รัน sql/rq3_setup.sql ใหม่")
        return 1

    lines, results = [], []
    w = lines.append
    w("=" * 78)
    w("RQ3 — คะแนนของชุด: %s" % label)
    w("รันเมื่อ : %s" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    w("วิธีให้คะแนน: **รัน SQL จริงบนฐานข้อมูล** แล้วเทียบกับ exact search")
    w("             ไม่ได้ดูรูปแบบ SQL เลย (กฎเหล็กข้อ 6)")
    w("=" * 78)
    w("")

    for spec in prompts:
        pid = spec["id"]
        path = os.path.join(adir, pid + ".sql")
        if not os.path.exists(path):
            w("%-5s ????  ไม่มีไฟล์คำตอบ %s" % (pid, path))
            results.append((pid, CANNOT, spec.get("traps", [])))
            continue
        sql_text = io.open(path, encoding="utf-8").read()

        kind = spec["check"]
        if kind == "rows_and_recall":
            v, d, extra = check_rows_and_recall(spec, sql_text, WHERE_FOR.get(pid, ""))
        elif kind == "index_created":
            v, d, extra = check_index_created(spec, sql_text)
        elif kind == "null_zero_guard":
            v, d, extra = check_null_zero_guard(spec, sql_text)
        else:
            v, d, extra = CANNOT, "ไม่รู้จัก check '%s'" % kind, {}

        mark = {PASS: " ok ", FAIL: "TRAP", CANNOT: "????"}[v]
        traps = ",".join(spec.get("traps", [])) or "-"
        w("%-5s %s  %-46s [กับดัก: %s]" % (pid, mark, d, traps))
        results.append((pid, v, spec.get("traps", [])))

    n_pass = sum(1 for _, v, _ in results if v == PASS)
    n_fail = sum(1 for _, v, _ in results if v == FAIL)
    n_cant = sum(1 for _, v, _ in results if v == CANNOT)
    total = len(results)

    w("")
    w("=" * 78)
    w("ติดกับดัก %d จาก %d ข้อ  (ผ่าน %d · ตรวจไม่ได้ %d)"
      % (n_fail, total, n_pass, n_cant))

    per = {}
    for pid, v, traps in results:
        for t in traps:
            per.setdefault(t, [0, 0])
            per[t][1] += 1
            if v == FAIL:
                per[t][0] += 1
    if per:
        w("")
        w("แยกตามกับดัก (ติด/โจทย์ที่วางกับดักนั้นไว้)")
        for t in sorted(per):
            w("  %-4s %d/%d" % (t, per[t][0], per[t][1]))
    w("")
    w("**ตัวหารคือจำนวนโจทย์** — ต่างจากทะเบียนบั๊ก H01–H27 ที่ไม่มีตัวหาร")
    w("=" * 78)

    report = "\n".join(lines) + "\n"
    out = io.open("results/rq3_%s.txt" % label, "w", encoding="utf-8", newline="\n")
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
