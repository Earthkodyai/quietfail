# RQ3 — โจทย์ 10 ข้อ สำหรับ copy ไปวาง

## กติกาก่อนเริ่ม — สำคัญกว่าตัวโจทย์

1. **ห้ามให้โมเดลเห็น repo นี้** ไม่ว่าทางไหน — `CLAUDE.md` ระบุกับดักทุกข้อพร้อมทางแก้
2. **เปิดแชทใหม่ทุกข้อ** ถ้าทำได้ · ถ้าถามต่อกันในแชทเดียว โมเดลจะจับทางได้ว่า
   กำลังถูกทดสอบเรื่อง vector index แล้วตอบระวังเป็นพิเศษตั้งแต่ข้อที่ 3–4
3. **ห้ามใบ้** อย่าถามย้ำว่า "แน่ใจนะ" หรือ "ลืมอะไรหรือเปล่า" — คำตอบแรกคือคำตอบ
4. **เอา SQL ล้วน** ถ้าโมเดลอธิบายยาว เอาเฉพาะบล็อก SQL · ถ้าให้มาหลายทางเลือก
   **เอาอันที่มันแนะนำเป็นหลัก** ไม่ใช่อันที่ดีที่สุด
5. เก็บเป็นไฟล์ `rq3/answers/<ชื่อโมเดล>/P01.sql` … `P10.sql`

---

## บล็อกที่ต้องวางก่อนทุกข้อ

```
ผมใช้ PostgreSQL 17 กับ pgvector มีตารางแบบนี้

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

documents มี 100,000 แถว · ระบบเทียบความคล้ายด้วย cosine
สัดส่วน category: general 44% · product 20% · support 20% · finance 10% · legal 5% · archive 1%

ตอบเป็น SQL อย่างเดียวพอครับ
```

---

## P01

```
เขียน SQL หา 10 เอกสารที่เนื้อหาใกล้เคียงกับ search_queries id = 1 มากที่สุด
```

## P02

```
เขียน SQL หา 10 เอกสารในหมวด archive ที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด
```

## P03

```
เขียน SQL หา 100 เอกสารที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด
```

## P04

```
เขียน SQL หา 20 เอกสารในหมวด legal ที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด
```

## P05

```
เขียน SQL หาเอกสารที่ระยะ cosine ห่างจาก search_queries id = 1 น้อยกว่า 0.5
เรียงจากใกล้ที่สุด เอามาแค่ 10 อันดับแรก
```

## P06

```
การค้นหาบนตาราง documents ช้ามาก ช่วยเขียน SQL ที่ทำให้เร็วขึ้นหน่อยครับ
ระบบใช้ cosine distance
```

## P07

```
เขียน SQL หา 50 เอกสารในหมวด finance ที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด
```

## P08

```
เขียน SQL หา 10 เอกสารใกล้เคียงกับ search_queries id = 1
โดยต้องได้ครบ 10 แถวเสมอไม่ว่าจะกรองด้วยหมวดไหน ลองใช้หมวด archive เป็นตัวอย่าง
```

## P09

```
เขียน SQL ตรวจว่าตาราง documents มีแถวไหนที่ embedding ใช้งานไม่ได้บ้าง
```

## P10

```
เขียน SQL หา 10 เอกสารที่ใกล้เคียงกับ search_queries id = 1 มากที่สุด
แต่เอาเฉพาะหมวด support และ product
```

---

## ฉบับภาษาอังกฤษ

ใช้เมื่ออยากให้คนอื่นทำซ้ำได้กว้างกว่า · ความหมายตรงกับฉบับไทยทุกข้อ

**บล็อกนำ**

```
I'm using PostgreSQL 17 with pgvector. My schema:

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

documents has 100,000 rows. Similarity uses cosine.
category distribution: general 44%, product 20%, support 20%, finance 10%, legal 5%, archive 1%

Just give me the SQL.
```

| # | prompt |
|---|---|
| P01 | Write SQL to find the 10 documents most similar to search_queries id = 1. |
| P02 | Write SQL to find the 10 documents in category `archive` most similar to search_queries id = 1. |
| P03 | Write SQL to find the 100 documents most similar to search_queries id = 1. |
| P04 | Write SQL to find the 20 documents in category `legal` most similar to search_queries id = 1. |
| P05 | Write SQL to find documents whose cosine distance from search_queries id = 1 is below 0.5, ordered nearest first, top 10 only. |
| P06 | Search on the documents table is very slow. Write SQL to make it faster. The system uses cosine distance. |
| P07 | Write SQL to find the 50 documents in category `finance` most similar to search_queries id = 1. |
| P08 | Write SQL to find 10 documents similar to search_queries id = 1, and it must always return all 10 rows no matter which category is filtered. Use category `archive` as the example. |
| P09 | Write SQL to check whether the documents table has any rows with an unusable embedding. |
| P10 | Write SQL to find the 10 documents most similar to search_queries id = 1, but only from categories `support` and `product`. |

---

## กับดักที่แต่ละข้อวางไว้ — **อย่าเปิดให้โมเดลเห็น**

ตารางนี้มีไว้ให้คุณอ่านหลังเก็บคำตอบครบแล้ว

| # | กับดัก | คำตอบที่ถือว่าผ่าน |
|---|---|---|
| P01 | — (กลุ่มควบคุม) | ได้ครบ 10 แถว |
| P02 | **Q03** filter 1% | ได้ครบ 10 แถว — ต้องเปิด `iterative_scan` **และ**เพิ่ม `work_mem` |
| P03 | **Q06** k > ef_search | ได้ครบ 100 แถว — ต้องเพิ่ม `ef_search` |
| P04 | **Q03** filter 5% | ได้ครบ 20 แถว |
| P05 | **Q02** รูปแบบ query | ได้ 10 แถวที่**ถูกตัว** — ต้องมี `ORDER BY` + `LIMIT` ไม่ใช่ `WHERE` อย่างเดียว |
| P06 | **I01** opclass · **Q04** ค่า default | สร้าง index ด้วย `vector_cosine_ops` |
| P07 | **Q03** + **Q06** พร้อมกัน | ได้ครบ 50 แถว |
| P08 | **Q03** โจทย์บอกเงื่อนไขตรงๆ | ได้ครบ 10 แถว |
| P09 | **V07** | จับทั้ง `NULL` **และ** zero vector — จับแค่ `NULL` ถือว่าตก |
| P10 | — (กลุ่มควบคุม filter 40%) | ได้ครบ 10 แถว |

**P01 กับ P10 เป็นกลุ่มควบคุม** ถ้าสองข้อนี้ตก แปลว่าโจทย์หรือตัวให้คะแนนมีปัญหา
ไม่ใช่โมเดลแย่

---

## เสร็จแล้วทำอะไรต่อ

```bash
docker compose exec -T db psql -U lab -d faultlab -f /sql/rq3_setup.sql
python scripts/rq3_score.py rq3/answers/<ชื่อโมเดล>
docker compose exec -T db psql -U lab -d faultlab -f /sql/rq3_teardown.sql
```

**ต้อง teardown ทุกครั้ง** ไม่งั้น `scripts/audit.py` จะฟ้องว่ามี vector index ค้าง
