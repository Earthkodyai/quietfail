# -*- coding: utf-8 -*-
"""
สร้าง corpus จาก **embedding จริง** เพื่อทดสอบว่าข้อสรุปของโปรเจคนี้
รอดบนเรขาคณิตของเวกเตอร์จริงหรือไม่ — ไม่ใช่แค่บน corpus สังเคราะห์

ทำไมต้องมี
----------
เล่มวิทยานิพนธ์ยอมรับเองใน 5.2 ข้อ 2 ว่า **ผลของ I02 ผูกกับคุณสมบัติเชิงโครงสร้าง
ของ corpus สังเคราะห์โดยตรง** (50 กลุ่มที่ออกแบบไว้ · id เรียงสลับกลุ่ม)
สคริปต์นี้สร้างชุดเทียบที่ **คุมทุกอย่างให้เท่าเดิม เปลี่ยนแค่ที่มาของเวกเตอร์**

    เท่าเดิม : 100,000 แถว · 384 มิติ · 200 query · cosine · index setting เดียวกัน
    ต่างกัน  : เวกเตอร์มาจากโมเดลจริง ไม่ใช่ Gaussian ที่เราปั้นเอง

ข้อมูล
------
BEIR / Quora (Thakur et al., NeurIPS 2021 Datasets & Benchmarks)
คำถามจริงจาก Quora — เป็นชุดมาตรฐานของงาน retrieval จึงอ้างอิงในเล่มได้
โมเดล: sentence-transformers/all-MiniLM-L6-v2 → **384 มิติพอดีกับ schema เดิม**

⚠️ ไม่แตะ qf_corpus เด็ดขาด — ตารางใหม่ทั้งหมดขึ้นต้นด้วย qf_real
⚠️ ต้องรันด้วย PYTHONIOENCODING=utf-8 ไม่งั้น console ไทย (cp874) พังตอน print
"""

import hashlib
import io
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

SCRATCH = os.environ.get(
    "QF_SCRATCH",
    r"C:\Users\DELL\AppData\Local\Temp\claude\C--dev-pg-fault-lab"
    r"\23780dd6-988f-4dde-884e-5937cb3d7707\scratchpad")

URL = "https://public.ukp.informatik.tu-darmstadt.de/thakur/BEIR/datasets/quora.zip"
# รับจาก env เพื่อให้ทดสอบโมเดลที่สองได้โดยไม่ต้องแก้ไฟล์ (เล่ม 6.5 ข้อ 2)
#   QF_MODEL=sentence-transformers/all-mpnet-base-v2 QF_DIM=768 QF_TAG=2
MODEL = os.environ.get("QF_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
TAG = os.environ.get("QF_TAG", "")        # ต่อท้ายชื่อไฟล์ TSV เช่น _real2_corpus.tsv

N_CORPUS = 100000    # เท่ากับ qf_corpus เป๊ะ เพื่อให้เทียบกันได้
N_QUERY = 200        # เท่ากับ qf_queries เป๊ะ
DIM = int(os.environ.get("QF_DIM", "384"))


def say(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def download():
    """โหลด zip ของ BEIR — urllib ใช้ไม่ได้กับ host นี้ (cert chain) ต้องใช้ requests"""
    import requests
    path = os.path.join(SCRATCH, "quora.zip")
    if os.path.exists(path) and os.path.getsize(path) > 10_000_000:
        say("zip มีอยู่แล้ว ข้ามการโหลด")
        return path
    if not os.path.isdir(SCRATCH):
        os.makedirs(SCRATCH)
    say("กำลังโหลด BEIR/quora ...")
    r = requests.get(URL, timeout=300, stream=True,
                     headers={"User-Agent": "quietfail-research"})
    r.raise_for_status()
    with open(path, "wb") as f:
        for chunk in r.iter_content(1 << 20):
            f.write(chunk)
    say("โหลดเสร็จ %.1f MB" % (os.path.getsize(path) / 1e6))
    return path


def clean(t):
    """TSV ห้ามมี tab/newline — แทนด้วยช่องว่าง (ไม่กระทบ embedding เพราะฝังไปแล้ว)"""
    return " ".join(t.replace("\t", " ").replace("\r", " ").split())


def pick(zip_path):
    """
    เลือกข้อมูลแบบ **กำหนดได้แน่นอน** — เรียงตาม _id แล้วตัดหัว
    ห้ามสุ่มโดยไม่มี seed ไม่งั้นรันซ้ำได้คนละชุดแล้วเทียบกันไม่ได้
    """
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        cpath = [n for n in names if n.endswith("corpus.jsonl")][0]
        qpath = [n for n in names if n.endswith("queries.jsonl")][0]

        docs = []
        with z.open(cpath) as f:
            for line in io.TextIOWrapper(f, encoding="utf-8"):
                d = json.loads(line)
                txt = clean((d.get("title", "") + " " + d.get("text", "")).strip())
                if txt:
                    docs.append((d["_id"], txt))
        queries = []
        with z.open(qpath) as f:
            for line in io.TextIOWrapper(f, encoding="utf-8"):
                d = json.loads(line)
                txt = clean(d.get("text", ""))
                if txt:
                    queries.append((d["_id"], txt))

    say("ในชุดข้อมูลมี doc %d · query %d" % (len(docs), len(queries)))
    docs.sort(key=lambda x: int(x[0]) if x[0].isdigit() else 10 ** 12)
    queries.sort(key=lambda x: int(x[0]) if x[0].isdigit() else 10 ** 12)

    if len(docs) < N_CORPUS:
        raise SystemExit("doc ไม่พอ: มี %d ต้องการ %d" % (len(docs), N_CORPUS))
    docs = docs[:N_CORPUS]

    # query ต้อง **ไม่อยู่ใน corpus** — Quora ใช้ id คนละชุดอยู่แล้ว แต่กันไว้
    ids = set(d[0] for d in docs)
    queries = [q for q in queries if q[0] not in ids][:N_QUERY]
    if len(queries) < N_QUERY:
        raise SystemExit("query ไม่พอ: มี %d" % len(queries))
    return docs, queries


def embed(texts, tag):
    from sentence_transformers import SentenceTransformer
    say("โหลดโมเดล %s ..." % MODEL)
    m = SentenceTransformer(MODEL)
    got = m.get_sentence_embedding_dimension()
    if got != DIM:
        raise SystemExit("มิติไม่ตรง: โมเดลให้ %d ต้องการ %d" % (got, DIM))
    say("กำลังฝัง %s %d ข้อความ ..." % (tag, len(texts)))
    # normalize เพราะวัดด้วย cosine — ให้ระยะขึ้นกับทิศทางล้วน
    return m.encode(texts, batch_size=256, show_progress_bar=True,
                    normalize_embeddings=True, convert_to_numpy=True)


def write_tsv(path, rows, vecs):
    """เขียนไฟล์ให้ postgres อ่านผ่าน COPY — ./sql ถูก mount เข้า container"""
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        for i, ((_id, txt), v) in enumerate(zip(rows, vecs)):
            lit = "[" + ",".join("%.6f" % x for x in v) + "]"
            f.write("%d\t%s\t%s\n" % (i, txt, lit))
    say("เขียน %s (%d แถว · %.0f MB)"
        % (path, len(rows), os.path.getsize(path) / 1e6))


def fingerprint(vecs, n=5000):
    """ลายนิ้วมือแบบเดียวกับ qf_corpus — ไว้ยืนยันว่าเป็นชุดเดิมจริง"""
    h = hashlib.md5()
    for v in vecs[:n]:
        h.update(("[" + ",".join("%.6f" % x for x in v) + "]").encode())
    return h.hexdigest()


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    zip_path = download()
    docs, queries = pick(zip_path)
    say("เลือกแล้ว: corpus %d · query %d" % (len(docs), len(queries)))

    dv = embed([d[1] for d in docs], "corpus")
    qv = embed([q[1] for q in queries], "query")

    write_tsv("sql/_real%s_corpus.tsv" % TAG, docs, dv)
    write_tsv("sql/_real%s_queries.tsv" % TAG, queries, qv)

    fp = fingerprint(dv)
    meta = {
        "dataset": "BEIR/quora (Thakur et al. 2021)",
        "model": MODEL,
        "dim": DIM,
        "corpus_rows": len(docs),
        "query_rows": len(queries),
        "normalized": True,
        "corpus_fingerprint_first5k": fp,
        "selection": "เรียงตาม _id แล้วตัดหัว — กำหนดได้แน่นอน ไม่ได้สุ่ม",
    }
    with io.open("sql/_real%s_meta.json" % TAG, "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    say("")
    say("fingerprint (5,000 แถวแรก) = %s" % fp)
    say("เสร็จ — ขั้นต่อไป: psql -f /sql/real_load.sql")


if __name__ == "__main__":
    main()
