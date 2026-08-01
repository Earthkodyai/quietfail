# RQ3 — ข้อความมอบหมายงาน แยกแชทละข้อ

**หนึ่งบล็อก = หนึ่งแชท** · วางทั้งบล็อก ไม่ต้องเพิ่มอะไร ไม่ต้องถามต่อ
เอา SQL ที่ได้มาเป็นไฟล์ `rq3/answers/<ชื่อโมเดล>/P0X.sql`

**ห้าม** ให้เห็น repo นี้ · **ห้าม** ถามย้ำว่าแน่ใจไหม · ถ้าให้มาหลายทางเลือก เอาอันที่มันแนะนำเป็นหลัก

## 🔴 กฎการเก็บ — อ่านก่อนเริ่ม (เพิ่ม 2026-08-02)

**1. ต้องเก็บ 2 รอบต่อโมเดล · รอบเดียวใช้ไม่ได้**

พิสูจน์แล้วว่าไม่นิ่ง — Opus 5 ได้ **5/10 กับ 7/10** บนโจทย์ชุดเดียวกันทุกตัวอักษร
แชทใหม่ ไม่มีอะไรต่างเลย · และรอบสองเปลี่ยนข้อสรุปของงานจริง (E38)
เดิมสรุปว่า *"เขียนจนปิด index เป็นลักษณะเฉพาะเจ้า"* ซึ่งรอบสองหักล้าง

> ⚠️ **ChatGPT ในชุดที่เก็บแล้ว มีรอบเดียว** จึงยังไม่ทราบว่า 10/10 นิ่งไหม
> ทุกที่ที่ยกตัวเลขนั้นไปใช้ต้องกำกับข้อนี้ · ดู `rq3/README.md`

**2. ห้ามให้โมเดลเห็น repo นี้ — รวมถึงผู้ช่วย AI ที่ทำงานในโปรเจคนี้ด้วย**

ทดสอบแล้ว 2026-07-28: subagent เห็น `CLAUDE.md` ทั้งไฟล์ใน system prompt
และตอบเองว่าความรู้เรื่อง `ef_search=40` มาจาก context ไม่ใช่จาก training
**`isolation: worktree` ก็ไม่ช่วย** เพราะคัดลอก `CLAUDE.md` ไปด้วย (E37)
→ ต้องเป็นแชทใหม่กับโมเดลที่ไม่เห็น repo เท่านั้น

**3. เก็บกวาดหลังให้คะแนนทุกครั้ง**

```bash
docker compose exec -T db psql -U lab -d faultlab -f /sql/rq3_setup.sql
python scripts/rq3_score.py rq3/answers/<ชื่อชุด>
docker compose exec -T db psql -U lab -d faultlab -f /sql/rq3_teardown.sql
```

ถ้าปล่อย index ของ RQ3 ค้าง `scripts/audit.py` จะฟ้องทุกครั้ง และแยกไม่ออกว่า
เป็นของ RQ3 หรือรอบทดลองที่ตายกลางคัน

**4. ตัวเลขที่ได้ตอบเป็น "รูปแบบ" ไม่ใช่ "อัตรา"**

โจทย์ 10 ข้อนี้**ออกแบบมาเล็งกับดักที่รู้อยู่แล้ว** ตัวหารจึงเป็นจำนวนโจทย์ที่เลือกเอง
ไม่ใช่โอกาสที่เกิดในงานจริง · **เพิ่มโจทย์ไม่ช่วย** เพราะปัญหาอยู่ที่วิธีเลือก (D20)

---

## P01

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 10 เอกสารที่เนื้อหาใกล้เคียงกับ search_queries id = 1 มากที่สุด

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P02

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 10 เอกสารในหมวด archive ที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P03

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 100 เอกสารที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P04

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 20 เอกสารในหมวด legal ที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P05

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หาเอกสารที่ระยะ cosine ห่างจาก search_queries id = 1 น้อยกว่า 0.5
เรียงจากใกล้ที่สุด เอามาแค่ 10 อันดับแรก

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P06

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

การค้นหาบนตาราง documents ช้ามาก ช่วยเขียน SQL ที่ทำให้เร็วขึ้นหน่อยครับ
ระบบใช้ cosine distance

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P07

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 50 เอกสารในหมวด finance ที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P08

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 10 เอกสารใกล้เคียงกับ search_queries id = 1
โดยต้องได้ครบ 10 แถวเสมอไม่ว่าจะกรองด้วยหมวดไหน ลองใช้หมวด archive เป็นตัวอย่าง

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P09

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL ตรวจว่าตาราง documents มีแถวไหนที่ embedding ใช้งานไม่ได้บ้าง

ตอบเป็น SQL อย่างเดียวพอครับ
```

## P10

```
ผมใช้ PostgreSQL 17 + pgvector

CREATE TABLE documents (
    id        int PRIMARY KEY,
    category  text NOT NULL,
    title     text NOT NULL,
    embedding vector(384)
);
CREATE TABLE search_queries (
    id        int PRIMARY KEY,
    embedding vector(384)
);

documents มี 100,000 แถว · เทียบความคล้ายด้วย cosine
category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

เขียน SQL หา 10 เอกสารที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด
แต่เอาเฉพาะหมวด support และ product

ตอบเป็น SQL อย่างเดียวพอครับ
```
