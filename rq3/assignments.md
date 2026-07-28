# RQ3 — ข้อความมอบหมายงาน แยกแชทละข้อ

**หนึ่งบล็อก = หนึ่งแชท** · วางทั้งบล็อก ไม่ต้องเพิ่มอะไร ไม่ต้องถามต่อ
เอา SQL ที่ได้มาเป็นไฟล์ `rq3/answers/<ชื่อโมเดล>/P0X.sql`

**ห้าม** ให้เห็น repo นี้ · **ห้าม** ถามย้ำว่าแน่ใจไหม · ถ้าให้มาหลายทางเลือก เอาอันที่มันแนะนำเป็นหลัก

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
