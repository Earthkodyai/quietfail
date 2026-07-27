#!/usr/bin/env python3
"""
เฟส 2.5 — รัน Q01 บน Qdrant ด้วยข้อมูลชุดเดียวกับ pgvector

ทำไมต้องมี: ถ้าวัดแค่ pgvector ตัวเดียว คำถามแรกที่จะโดนคือ
"นี่มันบั๊กของ pgvector หรือเปล่า" (PROJECT.md ข้อ 5 · D04)

หลักการที่ห้ามละเมิด:
  1. **corpus และชุด query ต้องเป็นชุดเดียวกันเป๊ะ** — ส่งออกจาก Postgres
     ไม่ได้สร้างใหม่ ไม่งั้นเทียบกันไม่ได้
  2. **เฉลยใช้ของเดิม** — qf_truth ที่มาจาก exact search ของ Postgres
  3. **ไม่จูนอะไรทั้งสิ้น** — สร้าง collection ด้วยค่าเริ่มต้นของ Qdrant
     เหมือนที่ฝั่ง pgvector ไม่ระบุ m / ef_construction

ใช้แค่ stdlib เพราะ image python:3.12-slim ไม่มีอะไรติดมา
และไม่อยาก pip install ให้ผลการทดลองขึ้นกับเวอร์ชันของ library
"""
import csv, json, sys, time, urllib.request, urllib.error

QDRANT = "http://qdrant:6333"
COLL = "qf_corpus"
DIM = 384

CORPUS_CSV = "/results/qdrant_corpus.csv"
QUERIES_CSV = "/results/qdrant_queries.csv"
OUT_CSV = "/results/qdrant_search_results.csv"
EXPECT_POINTS = 100000

csv.field_size_limit(10_000_000)


def call(method, path, body=None, timeout=600):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        QDRANT + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} {method} {path}\n{e.read().decode()[:800]}")


def parse_vec(text):
    # pgvector คืนมาเป็น "[0.1,0.2,...]"
    v = [float(x) for x in text.strip()[1:-1].split(",")]
    if len(v) != DIM:
        sys.exit(f"มิติไม่ตรง: ได้ {len(v)} ต้องเป็น {DIM}")
    return v


def coll_info():
    return call("GET", f"/collections/{COLL}")["result"]


def wait_indexed(expect, label):
    """รอจน Qdrant สร้าง HNSW ครบจริง

    ⚠️ ห้ามรอแค่ status == "green"
    เคยพลาดมาแล้ว: หลังอัปโหลดเสร็จ status เป็น green ทันทีทั้งที่
    indexed_vectors_count ยังเป็น 0 — แปลว่าไม่มี HNSW เลย
    แล้วการค้นทุกครั้งจะเป็น brute force ซึ่งให้ recall = 1.0 เสมอ
    ถ้าไม่ตรวจ จะรายงานว่า "Qdrant ไม่มีปัญหา recall" ทั้งที่ไม่ได้วัด ANN เลย
    (ดู E24)
    """
    t0 = time.time()
    while True:
        info = coll_info()
        st, idx = info["status"], info.get("indexed_vectors_count", 0) or 0
        if st == "green" and idx >= expect:
            print(f"   {label}: green · indexed={idx}/{expect} · {time.time()-t0:.1f}s", flush=True)
            return time.time() - t0, idx
        if time.time() - t0 > 3600:
            sys.exit(f"รอ index นานเกิน 1 ชม. (status={st} indexed={idx}/{expect})")
        time.sleep(2)


def main():
    # ข้ามการอัปโหลดถ้า collection เดิมพร้อมใช้อยู่แล้ว (ประหยัดเวลาตอนรันซ้ำ)
    try:
        info0 = coll_info()
        if (info0.get("points_count") == EXPECT_POINTS
                and (info0.get("indexed_vectors_count") or 0) >= EXPECT_POINTS):
            print(f">>> ใช้ collection เดิม ({EXPECT_POINTS} จุด · index ครบแล้ว) ข้ามการอัปโหลด", flush=True)
            return run_searches(EXPECT_POINTS, coll_info()["config"], 0.0, 0.0,
                                info0.get("indexed_vectors_count"), True)
    except SystemExit:
        pass

    print(">>> 1) ลบ collection เดิมถ้ามี แล้วสร้างใหม่ด้วยค่าเริ่มต้นทั้งหมด")
    try:
        call("DELETE", f"/collections/{COLL}")
    except SystemExit:
        pass
    # ไม่ระบุ hnsw_config เลย = ใช้ค่าเริ่มต้นของ Qdrant
    call("PUT", f"/collections/{COLL}",
         {"vectors": {"size": DIM, "distance": "Cosine"}})

    cfg = call("GET", f"/collections/{COLL}")["result"]["config"]
    print("   hnsw_config (ค่าเริ่มต้นของ Qdrant):",
          json.dumps(cfg.get("hnsw_config", {}), ensure_ascii=False))
    print("   optimizer indexing_threshold:",
          cfg.get("optimizer_config", {}).get("indexing_threshold"))

    print(">>> 2) อัปโหลด corpus (ชุดเดียวกับที่ pgvector ใช้)")
    t0 = time.time()
    batch, n = [], 0
    with open(CORPUS_CSV, newline="") as f:
        for row in csv.reader(f):
            batch.append({"id": int(row[0]), "vector": parse_vec(row[1])})
            if len(batch) >= 1000:
                call("PUT", f"/collections/{COLL}/points?wait=true", {"points": batch})
                n += len(batch); batch = []
                if n % 20000 == 0:
                    print(f"   อัปโหลดแล้ว {n}")
    if batch:
        call("PUT", f"/collections/{COLL}/points?wait=true", {"points": batch})
        n += len(batch)
    upload_s = time.time() - t0
    print(f"   อัปโหลดครบ {n} จุด · {upload_s:.1f}s")

    print(">>> 3) ตรวจว่าค่าเริ่มต้นล้วนๆ สร้าง HNSW ให้หรือเปล่า", flush=True)
    time.sleep(15)   # ให้ optimizer มีโอกาสทำงาน
    info = coll_info()
    idx_default = info.get("indexed_vectors_count", 0) or 0
    segs = info.get("segments_count")
    print(f"   หลังอัปโหลด: status={info['status']} indexed={idx_default} segments={segs}", flush=True)

    default_gave_index = idx_default > 0
    if not default_gave_index:
        # ⚠️ นี่คือผลการทดลองข้อหนึ่ง ไม่ใช่ปัญหาทางเทคนิคที่ต้องซ่อน
        #
        # Qdrant แตกข้อมูลเป็นหลาย segment แล้วตัดสินใจสร้าง HNSW
        # ต่อ segment โดยเทียบกับ indexing_threshold ซึ่งมีหน่วยเป็น KB
        # ที่ 100,000 จุด · 384 มิติ · float32 แตกเป็น 8 segment
        #   100000/8 = 12,500 จุด → 12500*384*4 = 18,750 KB
        #   ต่ำกว่า threshold 20,000 KB อยู่นิดเดียว → ไม่สร้าง index เลย
        #
        # ผลคือ "ใส่ vector database แล้วค้นได้เร็ว" ทั้งที่เป็น brute force
        # และ status ยังขึ้นเขียวว่าปกติดี
        print("   >>> ค่าเริ่มต้นล้วนๆ **ไม่ได้สร้าง HNSW เลย** — บันทึกเป็นผลการทดลอง", flush=True)
        print("   >>> บังคับสร้าง index โดยลด indexing_threshold อย่างเดียว", flush=True)
        print("   >>> m และ ef_construct ยังเป็นค่าเริ่มต้น (16 / 100) ไม่แตะ", flush=True)
        call("PATCH", f"/collections/{COLL}",
             {"optimizers_config": {"indexing_threshold": 1}})

    print(">>> 3b) รอให้สร้าง HNSW ครบทุกจุด", flush=True)
    build_s, indexed = wait_indexed(n, "build")

    cnt = coll_info()["points_count"]
    if cnt != n:
        sys.exit(f"จำนวนจุดไม่ตรง: อัปโหลด {n} แต่ Qdrant มี {cnt}")

    return run_searches(n, cfg, upload_s, build_s, indexed, default_gave_index)


def run_searches(n, cfg, upload_s, build_s, indexed, default_gave_index):
    queries = []
    with open(QUERIES_CSV, newline="") as f:
        for row in csv.reader(f):
            queries.append((int(row[0]), parse_vec(row[1])))
    print(f">>> 4) ยิง query {len(queries)} ข้อ", flush=True)
    if len(queries) != 200:
        sys.exit(f"ชุด query ต้องมี 200 ข้อ แต่ได้ {len(queries)}")

    # สามโหมด:
    #   exact     — ตัวสอบทาน ต้องตรงกับเฉลยของ PostgreSQL 100%
    #   hnsw      — ค่าเริ่มต้นของ Qdrant เอง
    #   hnsw_ef40 — **ตั้งความพยายามค้นหาให้เท่ากับ pgvector (ef_search=40)**
    #
    # ต้องมีโหมดที่สามเพราะเทียบที่ "ค่าเริ่มต้นของแต่ละเจ้า" ตอบได้แค่
    # "ค่าเริ่มต้นของใครปลอดภัยกว่า" ไม่ได้ตอบว่ากลไกเหมือนกันหรือเปล่า
    # ซึ่งเป็นคำถามจริงของเฟส 2.5
    modes = (
        ("exact",     {"exact": True}),
        ("hnsw",      None),
        ("hnsw_ef40", {"hnsw_ef": 40}),
    )
    rows, timing = [], {}
    for mode, params in modes:
        t0 = time.time()
        for k in (10, 100):
            for qid, vec in queries:
                body = {"vector": vec, "limit": k, "with_payload": False}
                if params:
                    body["params"] = params
                res = call("POST", f"/collections/{COLL}/points/search", body)["result"]
                rows.append([mode, qid, k, ",".join(str(p["id"]) for p in res)])
        timing[mode] = time.time() - t0
        print(f"   {mode}: {timing[mode]*1000:.1f} ms (k=10 และ k=100)", flush=True)

    with open(OUT_CSV, "w", newline="") as f:
        csv.writer(f).writerows(rows)
    print(f">>> 5) เขียนผล {len(rows)} แถวลง {OUT_CSV}", flush=True)

    meta = {
        "qdrant_version": call("GET", "/")["version"],
        "points": n,
        "indexed_vectors_count": indexed,
        "default_config_built_index": default_gave_index,
        "hnsw_config": cfg.get("hnsw_config", {}),
        "indexing_threshold": cfg.get("optimizer_config", {}).get("indexing_threshold"),
        "upload_seconds": round(upload_s, 1),
        "index_build_seconds": round(build_s, 1),
        "search_seconds": {m: round(v, 3) for m, v in timing.items()},
    }
    with open("/results/qdrant_meta.json", "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print(">>> DONE", json.dumps(meta, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
