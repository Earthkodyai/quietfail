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


def _strip_comments(stmt):
    return "\n".join(l for l in stmt.splitlines()
                     if l.strip() and not l.strip().startswith("--")).strip()


def split_prelude(sql_text):
    """
    แยกคำสั่งนำหน้า ออกจาก **query ที่เป็นคำตอบ**

    กติกา: query ที่ให้คะแนนคือ `SELECT`/`WITH` **ตัวแรก**
           ทุกอย่างก่อนหน้านั้นคือ prelude (SET / CREATE INDEX / ANALYZE)
           ทุกอย่างหลังจากนั้นทิ้ง

    ทำไมต้องเป็น "ตัวแรก" ไม่ใช่ "ตัวสุดท้าย":
      คำตอบจริงจากโมเดลวาง `CREATE INDEX` ไว้ **หลัง** SELECT บ่อยมาก
      (P07 · P10 ของ opus5-high) รุ่นแรกที่เอาคำสั่งสุดท้ายจึงไปให้คะแนน
      `CREATE INDEX` แทน query แล้วรายงานว่าติดกับดัก
      และบางข้อมีหลาย SELECT (ทางเลือก A/B) — ตรงกับกติกาเก็บคำตอบที่เขียนไว้เองว่า
      **เอาอันที่มันแนะนำเป็นหลัก** ไม่ใช่อันที่ดีที่สุด
    """
    parts = [_strip_comments(p) for p in sql_text.split(";")]
    parts = [p for p in parts if p]
    if not parts:
        return "", ""
    for i, p in enumerate(parts):
        head = p.lstrip().upper()
        if head.startswith("SELECT") or head.startswith("WITH"):
            prelude = ";\n".join(parts[:i]) + (";\n" if i else "")
            return prelude, p
    # ไม่มี SELECT เลย — คืนคำสั่งสุดท้ายไว้ให้ไปพังอย่างเปิดเผย ดีกว่าเงียบ
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

    # ── ตรวจว่า query ใช้ vector index จริงไหม ───────────────────────
    #
    # ⚠️ เพิ่มหลังเจอของจริง: ChatGPT เขียน CROSS JOIN แล้ว ORDER BY คอลัมน์
    #    จากตารางที่ join มา → pgvector ใช้ index ไม่ได้ กลายเป็น Seq Scan
    #    ผลที่ได้ **ถูกต้องสมบูรณ์ recall 1.00 ทุกข้อ** เพราะสแกนทั้งตาราง
    #
    #    ตัวให้คะแนนรุ่นแรกวัดแค่จำนวนแถวกับ recall จึงให้ผ่านหมด —
    #    **จุดบอดแบบเดียวกับ fault ที่โปรเจคนี้ศึกษาอยู่พอดี** (ดู H29)
    #
    #    บนข้อมูล 100k นี่คือความล้มเหลวจริง: index ถูกข้ามเงียบๆ
    #    ผลไม่ผิด แต่ช้าลงเป็นสิบเท่า และไม่มีอะไรแจ้ง = กับดัก Q02
    uses_idx, buf = explain_uses_vector_index(prelude, query)
    extra = {"rows": n, "expect": k, "recall": round(recall, 4),
             "uses_index": uses_idx, "buffers": buf}

    if uses_idx is False:
        return FAIL, (detail + " · **แต่ไม่ได้ใช้ vector index เลย** "
                      "(Seq Scan · อ่าน %s block) — ผลถูกเพราะสแกนทั้งตาราง = กับดัก Q02"
                      % (buf if buf is not None else "?")), extra
    if not (ok_rows and ok_recall):
        return FAIL, detail, extra
    return PASS, detail + (" · ใช้ index (%s block)" % buf if buf is not None else ""), extra


def explain_uses_vector_index(prelude, query):
    """
    คืน (ใช้ vector index ไหม, buffers) — อ่านจาก **โครงสร้าง plan**
    ไม่ใช่ค้นคำในข้อความ (กฎเหล็กข้อ 6)

    คืน None ถ้าตรวจไม่ได้ — ห้ามเดาว่า "ใช้" หรือ "ไม่ใช้"
    """
    # ต้องอยู่ใน sql/ เพราะเป็นโฟลเดอร์เดียวที่ mount เข้า container
    # (เขียนลง rq3/ แล้ว psql หาไฟล์ไม่เจอ → คืน None เงียบๆ → ตัวตรวจ index ไม่ทำงานเลย)
    # ⚠️ ต้องถาม catalog **ในทรานแซกชันเดียวกัน หลัง prelude** เพราะโมเดลอาจ
    #    สร้าง index เองใน prelude · ถ้า snapshot ไว้ก่อนจะมองไม่เห็น index ตัวนั้น
    tmp = "sql/_rq3_explain.sql"
    io.open(tmp, "w", encoding="utf-8", newline="\n").write(
        "BEGIN;\n" + prelude +
        "SELECT '@@VIDX@@' || coalesce(string_agg(c.relname, ','), '') "
        "FROM pg_class c JOIN pg_am am ON am.oid = c.relam "
        "WHERE am.amname IN ('hnsw','ivfflat');\n" +
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)\n" + query + ";\n" +
        "ROLLBACK;\n")
    rc, out = psql_file(tmp)
    try:
        os.remove(tmp)
    except OSError:
        pass
    if rc != 0:
        return None, None

    m = re.search(r"\[\s*\{.*\}\s*\]", out, re.S)
    if not m:
        return None, None
    try:
        plan = json.loads(m.group(0))[0]
    except Exception:
        return None, None

    buf = None
    p = plan.get("Plan", {})
    buf = (p.get("Shared Hit Blocks", 0) or 0) + (p.get("Shared Read Blocks", 0) or 0)

    # รายชื่อ vector index ที่มีอยู่จริง ณ ขณะนั้น — อ่านจาก catalog
    #
    # 🔴 รุ่นก่อนตัดสินจาก **ชื่อ** index (ต้องขึ้นต้น "documents_" และมีคำว่า
    #    "embedding") ซึ่งเป็นการเดาจากข้อความ ขัดกับกฎเหล็กข้อ 6 ที่บังคับ
    #    ให้อ่านโครงสร้าง · โมเดลตั้งชื่อ index เองได้อิสระ และในคำตอบที่เก็บ
    #    ไว้จริงมีทั้ง "idx_documents_embedding_hnsw" (ไม่ขึ้นต้นตามที่กำหนด)
    #    และ "documents_emb_cos_idx" (ไม่มีคำว่า embedding) ซึ่งจะถูกตัดสิน
    #    ว่า "ไม่ได้ใช้ index" ทั้งที่ใช้อยู่ = **ผลลบลวงที่ทำให้จำนวนกับดัก
    #    สูงเกินจริง** · ตรวจแล้วว่ายังไม่กระทบคะแนนชุดที่เก็บไว้ เพราะชื่อของ
    #    ข้อที่ผ่านทางนี้บังเอิญตรงพอดี แต่พังทันทีที่เก็บโมเดลใหม่ (แก้ 2026-08-02)
    vidx = set()
    mv = re.search(r"@@VIDX@@(\S*)", out)
    if mv:
        vidx = set(x for x in mv.group(1).split(",") if x)

    # เดินต้นไม้ plan หา Index Scan ที่ใช้ vector index ตัวใดตัวหนึ่ง
    found = [False]

    def walk(node):
        if node.get("Node Type", "").endswith("Index Scan"):
            if node.get("Index Name", "") in vidx:
                found[0] = True
        for child in node.get("Plans", []) or []:
            walk(child)

    walk(p)
    return found[0], buf


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

    # ⚠️ ต้องเก็บกวาด **ก่อน return ทุกทาง** — รุ่นแรก return ตอน rc != 0
    #    โดยไม่เก็บกวาด ทำให้ index ที่โมเดลสร้างสำเร็จก่อนจะพังค้างอยู่
    #    รอบถัดไปจึงล้มด้วย "relation already exists" ซึ่งเป็นคนละเรื่องกับความผิดของโมเดล
    #    = ตัวให้คะแนนสร้างความล้มเหลวปลอมให้ตัวเอง (ดู H30)
    def cleanup():
        for x in vector_indexes() - before:
            psql("DROP INDEX IF EXISTS " + x.split("=")[0] + ";")

    if rc != 0:
        tail = [l for l in out.splitlines() if l.strip()][-1:]
        msg = tail[0][:110] if tail else "?"
        cleanup()
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
    # ⚠️ ห้าม hardcode ช่วงเลข H — รุ่นก่อนเขียน "H01–H27" ไว้ตรงๆ แล้วผุเงียบ
    #    เมื่อทะเบียนโตเป็น H32 · ตัวเลขผิดจะถูกพิมพ์ลงไฟล์ผลทุกครั้งที่ให้คะแนน
    #    เป็นบั๊กชนิดเดียวกับกับดักข้อ 14 (แก้ 2026-08-02)
    try:
        fa = io.open(os.path.join(ROOT, "FAULTS.md"), encoding="utf-8").read()
        hs = [int(x) for x in re.findall(r"^\|\s*\*\*H(\d{2})\*\*", fa, re.M)]
        hrange = "H01–H%02d" % max(hs) if hs else "ทะเบียนบั๊ก H"
    except IOError:
        hrange = "ทะเบียนบั๊ก H"
    w("**ตัวหารคือจำนวนโจทย์** — ต่างจากทะเบียนบั๊ก %s ที่ไม่มีตัวหาร" % hrange)
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
