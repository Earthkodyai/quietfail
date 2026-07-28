#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quietfail-check — ตรวจฐานข้อมูล PostgreSQL + pgvector หา "ความล้มเหลวเงียบ"
                  ก่อนโค้ดขึ้น production

    python scripts/quietfail_check.py --dsn "postgresql://user:pw@host/db"
    python scripts/quietfail_check.py --docker            # ใช้ container ของ repo นี้

ต่างจาก sql/score.sql อย่างไร
------------------------------
`score.sql` เป็นตัวนับคะแนน**ของงานวิจัย** — อ่านไฟล์เฉลยจาก /groundtruth
ด้วย pg_read_file() จึงรันได้เฉพาะบน container ของ repo นี้

ไฟล์นี้คือ**ของส่งมอบ** — ตรวจฐานข้อมูล**ของใครก็ได้** ไม่ต้องมีไฟล์เฉลย
ไม่ต้องมี superuser ไม่ต้องรู้จัก schema ล่วงหน้า (ค้นหาคอลัมน์ vector เอง)

ตรวจอะไรบ้าง — เฉพาะข้อที่ยกไปใช้กับฐานข้อมูลอื่นได้จริง
--------------------------------------------------------
    I01  opclass ของ index ไม่ตรงกับ operator ที่โค้ดใช้จริง
    Q04  ivfflat.probes ต่ำกว่า sqrt(lists) ที่เอกสารแนะนำ
    Q06  hnsw.ef_search ต่ำกว่า LIMIT ที่โค้ดใช้  (ต้องระบุ --max-limit)
    I05  maintenance_work_mem ไม่พอสำหรับจำนวนแถวที่มี
    V07  มีแถวที่ embedding เป็น NULL หรือ zero vector
    Q02  มี query ที่ใช้ vector operator แต่รูปแบบทำให้ index ใช้ไม่ได้

Q03 และ L02 ไม่รวมอยู่ในนี้ เพราะต้องยิง query ทดสอบด้วย vector จริง
ซึ่งเลือกให้อัตโนมัติไม่ได้โดยไม่เดาเจตนาของแอป — ดู REPORT.md หัวข้อ 3

exit code
---------
    0  ตรวจครบ ไม่พบปัญหา
    1  **พบปัญหา** (DETECTED) — ควร fail build
    2  ไม่พบปัญหา แต่มีข้อที่ **ตรวจไม่ได้** (CANNOT_CHECK)
       ใส่ --allow-unknown เพื่อให้ผ่าน

    ทำไม exit 2 ถึงไม่ใช่ 0 โดยปริยาย: เครื่องมือที่บอกว่า "ปลอดภัย"
    ทั้งที่ไม่ได้ตรวจอะไรเลย อันตรายกว่าไม่มีเครื่องมือ (กฎเหล็กข้อ 10)
"""

import argparse
import json
import os
import re
import subprocess
import sys

DETECTED, NOT_DETECTED, CANNOT = "DETECTED", "NOT_DETECTED", "CANNOT_CHECK"

# operator ของ pgvector -> opclass ที่ต้องใช้คู่กัน
OPERATOR_OPCLASS = {
    "<=>": ("vector_cosine_ops", "cosine distance"),
    "<->": ("vector_l2_ops", "L2 distance"),
    "<#>": ("vector_ip_ops", "inner product"),
}

# ความจุที่ **วัดเอง** ที่ 384 มิติ (ดู groundtruth/i05.json) — ไม่ใช่สูตรจากเอกสาร
TUPLES_PER_MB_384 = 443


class Db:
    """เรียก psql แบบไม่ผ่าน shell — SQL ที่มี quote จึงไม่ต้อง escape"""

    def __init__(self, dsn=None, use_docker=False):
        self.dsn, self.use_docker = dsn, use_docker

    # ⚠ ห้ามใช้ \x1f เป็นตัวคั่น — Python ถือว่า 0x1C–0x1F เป็น whitespace
    #    out.strip() จึงกินตัวคั่นตัวสุดท้ายทิ้ง แถวที่ field ท้ายว่างหายไปหนึ่งคอลัมน์
    #    **เงียบสนิท** แล้วไปพังที่จุดอื่นซึ่งไม่ชี้กลับมาที่ต้นเหตุเลย (ดู H28)
    SEP = "\x01"

    def _argv(self, sql):
        common = ["-qAt", "-F", self.SEP, "-v", "ON_ERROR_STOP=1", "-c", sql]
        if self.use_docker:
            return ["docker", "compose", "exec", "-T", "db",
                    "psql", "-U", "lab", "-d", "faultlab"] + common
        return ["psql"] + common + ([self.dsn] if self.dsn else [])

    def rows(self, sql, timeout=60):
        """คืน (ok, list ของ tuple) — ok=False เมื่อ query ล้ม"""
        try:
            p = subprocess.run(self._argv(sql), capture_output=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, [("psql error: %s" % e,)]
        out = p.stdout.decode("utf-8", errors="replace").strip("\r\n")
        if p.returncode != 0:
            err = p.stderr.decode("utf-8", errors="replace").strip().splitlines()
            return False, [(err[-1] if err else "psql exit %d" % p.returncode,)]
        if not out:
            return True, []
        return True, [tuple(l.split(self.SEP)) for l in out.splitlines()]

    def one(self, sql, default=None):
        ok, r = self.rows(sql)
        if not ok or not r or not r[0]:
            return default
        return r[0][0]


class Report:
    def __init__(self, gh_annotations=False):
        self.items, self.gh = [], gh_annotations

    def add(self, fid, verdict, detail, fix=None):
        self.items.append((fid, verdict, detail, fix))
        if self.gh and verdict == DETECTED:
            # GitHub Actions แสดงเป็น annotation สีแดงในหน้า PR
            print("::error title=QuietFail %s::%s" % (fid, detail.replace("\n", " ")))
        elif self.gh and verdict == CANNOT:
            print("::warning title=QuietFail %s::%s" % (fid, detail.replace("\n", " ")))

    def counts(self):
        c = {DETECTED: 0, NOT_DETECTED: 0, CANNOT: 0}
        for _, v, _, _ in self.items:
            c[v] += 1
        return c


# ══════════════════════════════════════════════════════════════
# การค้นหาโครงสร้าง — ไม่ต้องรู้ schema ล่วงหน้า
# ══════════════════════════════════════════════════════════════
def vector_columns(db):
    ok, r = db.rows("""
        SELECT n.nspname, c.relname, a.attname
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_type t      ON t.oid = a.atttypid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE t.typname = 'vector' AND c.relkind = 'r' AND a.attnum > 0
          AND NOT a.attisdropped
          AND n.nspname NOT IN ('pg_catalog','information_schema')
        ORDER BY 1,2,3""")
    return r if ok else []


def vector_indexes(db):
    ok, r = db.rows("""
        SELECT n.nspname, t.relname, c.relname, am.amname, o.opcname,
               coalesce(array_to_string(c.reloptions, ','), '')
        FROM pg_index i
        JOIN pg_class c     ON c.oid = i.indexrelid
        JOIN pg_class t     ON t.oid = i.indrelid
        JOIN pg_am am       ON am.oid = c.relam
        JOIN pg_opclass o   ON o.oid = i.indclass[0]
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE am.amname IN ('hnsw','ivfflat')
        ORDER BY 2,3""")
    return r if ok else []


def has_pgss(db):
    return db.one("SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'", "0") == "1"


def operators_used(db):
    """หา operator ของ pgvector ที่โค้ดเคยใช้จริง จากประวัติ query"""
    if not has_pgss(db):
        return None
    ok, r = db.rows("""
        SELECT DISTINCT
          CASE WHEN query LIKE '%<=>%' THEN '<=>'
               WHEN query LIKE '%<->%' THEN '<->'
               WHEN query LIKE '%<#>%' THEN '<#>' END AS op
        FROM pg_stat_statements
        WHERE query LIKE '%<=>%' OR query LIKE '%<->%' OR query LIKE '%<#>%'""")
    return [x[0] for x in r if x and x[0]] if ok else []


# ══════════════════════════════════════════════════════════════
# ตัวตรวจ
# ══════════════════════════════════════════════════════════════
def check_i01(db, rep, idxs):
    """opclass ของ index ต้องตรงกับ operator ที่โค้ดใช้"""
    if not idxs:
        rep.add("I01", CANNOT, "ไม่มี vector index ในฐานข้อมูลนี้ — ไม่มี opclass ให้ตรวจ")
        return
    ops = operators_used(db)
    if ops is None:
        rep.add("I01", CANNOT,
                "ไม่มี extension pg_stat_statements จึงไม่รู้ว่าโค้ดใช้ operator ตัวไหน "
                "— ติดตั้งก่อน หรือระบุด้วย --operator")
        return
    if not ops:
        rep.add("I01", CANNOT, "ยังไม่มี query ที่ใช้ vector operator ในประวัติ — ให้แอปทำงานสักพักก่อน")
        return

    wanted = {OPERATOR_OPCLASS[o][0] for o in ops if o in OPERATOR_OPCLASS}
    bad = [(t, i, opc) for _, t, i, _, opc, _ in idxs if opc not in wanted]
    if bad:
        rep.add("I01", DETECTED,
                "index %s บนตาราง %s ใช้ opclass %s แต่โค้ดค้นด้วย %s (ต้องใช้ %s) "
                "— index จะถูกข้ามไปเงียบๆ" % (
                    bad[0][1], bad[0][0], bad[0][2], " ".join(ops), " หรือ ".join(sorted(wanted))),
                "สร้าง index ใหม่ด้วย opclass ที่ตรงกับ operator ที่ใช้จริง")
    else:
        rep.add("I01", NOT_DETECTED,
                "vector index %d ตัว ใช้ opclass ตรงกับ operator ที่โค้ดใช้ (%s)"
                % (len(idxs), " ".join(ops)))


def check_q04(db, rep, idxs):
    """ivfflat.probes ต้องไม่ต่ำกว่า sqrt(lists)"""
    ivf = [(t, i, opts) for _, t, i, am, _, opts in idxs if am == "ivfflat"]
    if not ivf:
        rep.add("Q04", CANNOT, "ไม่มี ivfflat index — ไม่มี lists ให้เทียบ")
        return
    lists = None
    for _, _, opts in ivf:
        m = re.search(r"lists=(\d+)", opts)
        if m:
            lists = max(lists or 0, int(m.group(1)))
    if lists is None:
        rep.add("Q04", CANNOT, "ivfflat index ไม่ได้ระบุ lists ใน reloptions")
        return
    probes = int(db.one("SELECT current_setting('ivfflat.probes')", "1"))
    rec = int(lists ** 0.5 + 0.999)
    if probes < rec:
        rep.add("Q04", DETECTED,
                "ivfflat.probes = %d แต่ index ตั้ง lists = %d → เอกสารแนะนำ sqrt(lists) = %d "
                "· ค้นแค่ %d จาก %d กลุ่ม ผลที่เหลือหายเงียบๆ" % (probes, lists, rec, probes, lists),
                "SET ivfflat.probes ให้พอ แล้ววัด recall จริงกับข้อมูลของคุณเอง "
                "— ค่าที่เหมาะสมมาจากการวัด ไม่ใช่จากสูตร")
    else:
        rep.add("Q04", NOT_DETECTED, "ivfflat.probes = %d >= sqrt(lists) = %d" % (probes, rec))


def check_q06(db, rep, idxs, max_limit=None):
    """
    hnsw.ef_search ต้องไม่ต่ำกว่า LIMIT ที่โค้ดใช้

    ⚠️ ตัวเลข LIMIT **อ่านจาก pg_stat_statements ไม่ได้**
       มันทำ normalization แทนค่าคงที่ทุกตัวด้วย $n ก่อนเก็บ
       `LIMIT 100` จึงถูกเก็บเป็น `LIMIT $2` — ตัวเลขหายตั้งแต่ต้นทาง
       (พบตอนทดสอบตัวตรวจนี้เอง · ดู U06 ใน FAULTS.md)

       รุ่นแรกพยายาม regex เอาตัวเลขออกมา แล้วได้ CANNOT_CHECK ตลอดกาล
       โดยข้อความไม่บอกว่าทำไม — แย่กว่าไม่มีตัวตรวจ เพราะคนอ่านจะคิดว่า
       "ยังไม่มี query" ทั้งที่ความจริงคือ "อ่านค่านี้ไม่ได้เลยตลอดกาล"
    """
    if not any(am == "hnsw" for _, _, _, am, _, _ in idxs):
        rep.add("Q06", CANNOT, "ไม่มี hnsw index — เพดาน ef_search ไม่มีผล")
        return
    ef = int(db.one("SELECT current_setting('hnsw.ef_search')", "40"))
    top = max_limit
    if top is None:
        rep.add("Q06", CANNOT,
                "hnsw.ef_search = %d → คืนผลได้ไม่เกิน %d แถวต่อ query "
                "· ตัวเลข LIMIT ที่โค้ดใช้อ่านจากฐานข้อมูลไม่ได้ "
                "(pg_stat_statements แทนค่าคงที่ด้วย $n) — ระบุเองด้วย --max-limit N" % (ef, ef))
        return
    if top > ef:
        rep.add("Q06", DETECTED,
                "hnsw.ef_search = %d แต่โค้ดขอ LIMIT ถึง %d → คืนได้ไม่เกิน %d แถว "
                "ขาดไป %d โดยไม่มี error" % (ef, top, ef, top - ef),
                "ตั้ง hnsw.ef_search ให้ >= LIMIT ที่ใหญ่ที่สุด "
                "· ได้แถวครบไม่ได้แปลว่าถูกครบ ต้องวัด recall ต่างหาก")
    else:
        rep.add("Q06", NOT_DETECTED, "hnsw.ef_search = %d >= LIMIT สูงสุดที่ระบุ (%d)" % (ef, top))


def check_i05(db, rep, cols):
    """maintenance_work_mem พอสำหรับ build index ไหม"""
    if not cols:
        rep.add("I05", CANNOT, "ไม่พบคอลัมน์ชนิด vector ในฐานข้อมูลนี้")
        return
    mwm = db.one("SELECT pg_size_bytes(current_setting('maintenance_work_mem'))/1024/1024")
    if mwm is None:
        rep.add("I05", CANNOT, "อ่าน maintenance_work_mem ไม่ได้")
        return
    mwm = int(mwm)
    worst = None
    for sch, tbl, col in cols:
        dim = db.one('SELECT max(vector_dims(%s)) FROM %s.%s' % (q(col), q(sch), q(tbl)))
        n = db.one('SELECT count(*) FROM %s.%s' % (q(sch), q(tbl)), "0")
        if dim is None or not str(dim).isdigit():
            continue
        if int(dim) != 384:
            # ความจุ calibrate ที่ 384 มิติเท่านั้น — มิติอื่นห้ามเดา (กฎเหล็กข้อ 10)
            continue
        cap = mwm * TUPLES_PER_MB_384
        if int(n) > cap and (worst is None or int(n) > worst[1]):
            worst = ("%s.%s" % (tbl, col), int(n), cap)
    if worst:
        rep.add("I05", DETECTED,
                "maintenance_work_mem = %d MB รับได้ราว %d tuples แต่ %s มี %d แถว "
                "→ build index จะ spill ลงดิสก์และช้าขึ้นราว 3 เท่า"
                % (mwm, worst[2], worst[0], worst[1]),
                "เพิ่ม maintenance_work_mem เฉพาะตอน build "
                "· ระวังอย่าให้เกิน /dev/shm ของ container ไม่งั้น build ล้มด้วย error ที่ชี้ไปที่ดิสก์")
    else:
        has384 = any(str(db.one('SELECT max(vector_dims(%s)) FROM %s.%s'
                                % (q(c), q(s), q(t)))) == "384" for s, t, c in cols)
        if has384:
            rep.add("I05", NOT_DETECTED, "maintenance_work_mem = %d MB พอสำหรับทุกตารางที่ตรวจได้" % mwm)
        else:
            rep.add("I05", CANNOT,
                    "ค่าความจุ calibrate ไว้ที่ 384 มิติเท่านั้น ตารางที่พบเป็นมิติอื่น "
                    "— ต้องวัดใหม่ก่อนถึงจะตรวจได้ ห้ามเดา")


def check_v07(db, rep, cols):
    """NULL / zero vector หายจากผลค้นถาวร"""
    if not cols:
        rep.add("V07", CANNOT, "ไม่พบคอลัมน์ชนิด vector ในฐานข้อมูลนี้")
        return
    bad = []
    for sch, tbl, col in cols:
        r = db.one("""SELECT count(*) FILTER (WHERE %s IS NULL)
                           + count(*) FILTER (WHERE %s IS NOT NULL AND vector_norm(%s) = 0)
                      FROM %s.%s""" % (q(col), q(col), q(col), q(sch), q(tbl)))
        if r and r.isdigit() and int(r) > 0:
            bad.append(("%s.%s" % (tbl, col), int(r)))
    if bad:
        tot = sum(n for _, n in bad)
        rep.add("V07", DETECTED,
                "พบ %d แถวที่ embedding เป็น NULL หรือ zero vector (%s) "
                "→ แถวเหล่านี้จะไม่โผล่ในผลค้นเลยตลอดกาล"
                % (tot, ", ".join("%s: %d" % b for b in bad[:3])),
                "แก้ที่ pipeline — อย่าใส่ศูนย์แทนเมื่อสร้าง embedding ล้มเหลว "
                "ให้โยน error หรือกันแถวนั้นออก")
    else:
        rep.add("V07", NOT_DETECTED, "ไม่พบ NULL หรือ zero vector ใน %d คอลัมน์" % len(cols))


def check_q02(db, rep):
    """รูปแบบ query ที่ทำให้ index ใช้ไม่ได้"""
    if not has_pgss(db):
        rep.add("Q02", CANNOT, "ไม่มี pg_stat_statements จึงอ่านรูปแบบ query ที่เคยรันไม่ได้")
        return
    ok, r = db.rows("""
        SELECT count(*) FILTER (WHERE NOT (query ILIKE '%%order by%%' AND query ILIKE '%%limit%%')),
               count(*) FILTER (WHERE query ~* 'order by[^;]*desc'),
               count(*)
        FROM pg_stat_statements
        WHERE (query LIKE '%%<=>%%' OR query LIKE '%%<->%%' OR query LIKE '%%<#>%%')
          AND query ILIKE 'select%%'""")
    if not ok or not r:
        rep.add("Q02", CANNOT, "อ่าน pg_stat_statements ไม่ได้")
        return
    no_ol, desc, total = (int(x) for x in r[0])
    if total == 0:
        rep.add("Q02", CANNOT, "ยังไม่มี query ที่ใช้ vector operator ในประวัติ")
        return
    if no_ol or desc:
        rep.add("Q02", DETECTED,
                "จาก %d query ที่ใช้ vector operator: ขาด ORDER BY หรือ LIMIT %d · เรียง DESC %d "
                "→ index ถูกข้ามไปเงียบๆ" % (total, no_ol, desc),
                "เขียนเป็น ORDER BY <distance operator> ASC + LIMIT k "
                "โดยไม่ห่อ operator ด้วยนิพจน์ใดๆ")
    else:
        rep.add("Q02", NOT_DETECTED, "query ทั้ง %d แบบมี ORDER BY + LIMIT และเรียงจากน้อยไปมาก" % total)


def q(ident):
    """quote identifier กัน SQL injection จากชื่อตาราง/คอลัมน์ที่อ่านมาจาก catalog"""
    return '"%s"' % ident.replace('"', '""')


# ══════════════════════════════════════════════════════════════
def main():
    ap = argparse.ArgumentParser(
        description="quietfail-check — ตรวจความล้มเหลวเงียบของ vector search")
    ap.add_argument("--dsn", help="connection string ของ PostgreSQL")
    ap.add_argument("--docker", action="store_true",
                    help="ใช้ container ของ repo นี้แทน --dsn")
    ap.add_argument("--max-limit", type=int, metavar="N",
                    help="LIMIT ที่ใหญ่ที่สุดที่โค้ดของคุณใช้ — จำเป็นสำหรับ Q06 "
                         "เพราะ pg_stat_statements ไม่เก็บตัวเลขนี้ไว้")
    ap.add_argument("--allow-unknown", action="store_true",
                    help="ให้ CANNOT_CHECK ไม่ทำให้ build ล้ม (ค่าปริยาย: ล้ม)")
    ap.add_argument("--github", action="store_true",
                    help="พิมพ์ annotation ของ GitHub Actions ด้วย")
    ap.add_argument("--json", metavar="FILE", help="เขียนผลเป็น JSON")
    a = ap.parse_args()

    if not a.dsn and not a.docker:
        a.docker = True

    db = Db(a.dsn, a.docker)
    if db.one("SELECT 1") != "1":
        print("ต่อฐานข้อมูลไม่ได้ — ตรวจ --dsn หรือว่า container ทำงานอยู่ไหม")
        return 2
    if db.one("SELECT count(*) FROM pg_extension WHERE extname='vector'", "0") != "1":
        print("ฐานข้อมูลนี้ไม่มี extension 'vector' — ไม่มีอะไรให้ตรวจ")
        return 2
    db.rows("LOAD 'vector'")   # กฎเหล็กข้อ 9 — ไม่โหลดแล้ว GUC จะอ่านไม่เจอ

    rep = Report(a.github)
    cols, idxs = vector_columns(db), vector_indexes(db)

    check_i01(db, rep, idxs)
    check_q02(db, rep)
    check_q04(db, rep, idxs)
    check_q06(db, rep, idxs, a.max_limit)
    check_i05(db, rep, cols)
    check_v07(db, rep, cols)

    mark = {DETECTED: "FAIL", NOT_DETECTED: " ok ", CANNOT: "????"}
    print("\nquietfail-check — ตรวจความล้มเหลวเงียบของ vector search")
    print("คอลัมน์ vector %d · vector index %d" % (len(cols), len(idxs)))
    print("-" * 78)
    for fid, v, detail, fix in rep.items:
        print(" %s  %-4s %s" % (mark[v], fid, detail))
        if fix and v == DETECTED:
            print("            แก้: %s" % fix)
    print("-" * 78)

    c = rep.counts()
    print("พบปัญหา %d · ไม่พบ %d · ตรวจไม่ได้ %d"
          % (c[DETECTED], c[NOT_DETECTED], c[CANNOT]))

    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"summary": c,
                       "items": [{"id": i, "verdict": v, "detail": d, "fix": x}
                                 for i, v, d, x in rep.items]},
                      f, ensure_ascii=False, indent=2)

    if c[DETECTED]:
        print("\nผลลัพธ์บางส่วนกำลังหายไปเงียบๆ — ดูรายละเอียดข้างบน")
        return 1
    if c[CANNOT] and not a.allow_unknown:
        print("\nไม่พบปัญหา แต่มี %d ข้อที่ **ตรวจไม่ได้** — ไม่ใช่ใบรับรองว่าปลอดภัย"
              % c[CANNOT])
        print("ใส่ --allow-unknown ถ้ายอมรับได้")
        return 2
    print("\nตรวจครบ ไม่พบความล้มเหลวเงียบ")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    sys.exit(main())
