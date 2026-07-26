# ทะเบียน fault

> **ไฟล์นี้คือแหล่งอ้างอิงเดียวของนิยาม fault ทั้งหมด**
> ถ้า `PROJECT.md` หรือ `EVIDENCE.md` ขัดกับไฟล์นี้ ให้เชื่อไฟล์นี้
>
> ทุก fault ต้องมีครบ 5 อย่าง: อาการ · ต้นเหตุ · วิธีฉีด · ground truth · assertion
> ถ้าข้อไหนขาด แปลว่ายังนิยามไม่เสร็จ ห้ามนับว่าพร้อมทำ

**รวม 16 fault** = core 4 ข้อ (F) + vector 12 ข้อ (I/Q/V/L)

---

# ชุด core — 4 ข้อ (เกณฑ์ผ่านเฟส 1)

มีไว้แสดงว่ากลไกวัดผลชุดเดียวกันใช้ได้ทั้งกับปัญหา DB ทั่วไปและปัญหาเฉพาะของ vector
ทั้ง 4 ข้อเป็นแบบ **"error ชี้ไปผิดที่"** ซึ่งเป็นแกนของ QuietFail

---

## F01 — connection หมด เพราะ transaction ค้าง

| | |
|---|---|
| **อาการที่เห็น** | `FATAL: sorry, too many clients already` (SQLSTATE 53300) |
| **คนมักแก้ผิด** | เพิ่ม `max_connections` → กิน RAM มากขึ้น แล้วเต็มอีกอยู่ดี |
| **ต้นเหตุจริง** | โค้ดเปิด transaction แล้วไม่ commit/rollback |
| **ทำไม dev ไม่เจอ** | dev มี connection เดียว ไม่มีวันเต็ม |

**วิธีฉีด** — เปิด N connection แต่ละอันสั่ง `BEGIN; SELECT 1;` แล้วปล่อยค้าง
โดยที่ท่อ stdin ยังเปิดอยู่

> ⚠️ ห้ามใช้ `pg_sleep()` เพราะทำให้ state เป็น `active` ซึ่งคนละเรื่อง
> ⚠️ ต้องยิงด้วย role `app` ไม่ใช่ `lab` เพราะ `superuser_reserved_connections`
> ทำให้ superuser ต่อได้เสมอ → fault จะไม่มีวันเกิด

**ground truth**
```sql
SELECT pid, usename, state, now() - state_change AS stuck_for, query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY state_change ASC;
```

**assertion** — ต้องผ่านทั้ง 3 ข้อ ไม่งั้น exit ด้วย error
1. connection ใหม่ได้ error ที่มีข้อความ `too many clients already`
2. `pg_stat_activity` มี `state = 'idle in transaction'` ≥ 10 session
3. session ที่ค้างนานสุด ค้างเกิน 2 วินาที

**สถานะ:** สคริปต์เขียนแล้ว (`faults/f01_idle_in_transaction.sh`) · **ยังไม่เคยรันจริง**
`groundtruth/f01.json` มี `verified_on: null` ทั้งสามช่อง ต้องเติมหลังรันครั้งแรก

---

## F03 — statement timeout ที่ไม่ได้ช้า แต่รอ lock ⭐

**นี่คือข้อที่พิสูจน์วิทยานิพนธ์ของโปรเจคทั้งหมด** เพราะต้องทำคู่กับ F03b
ซึ่งให้ **ข้อความ error เหมือนกันเป๊ะ แต่คนละสาเหตุ**

| | F03 | F03b |
|---|---|---|
| **อาการที่เห็น** | `ERROR: canceling statement due to statement timeout` | **เหมือนกันทุกตัวอักษร** |
| **ต้นเหตุจริง** | รอ row lock จาก transaction อื่น | query ช้าจริง (ไม่มี index) |
| **คนมักแก้ผิด** | เพิ่ม timeout · ไล่ optimize query ที่ไม่ได้ช้า | เพิ่ม timeout |
| **ทางแก้ที่ถูก** | ไล่หา transaction ที่ถือ lock | สร้าง index |

**วิธีฉีด F03**
```
session A:  BEGIN; UPDATE orders SET status='x' WHERE id=1;   (ค้างไว้)
session B:  SET statement_timeout = '2s';
            UPDATE orders SET status='y' WHERE id=1;          → timeout
```

**วิธีฉีด F03b**
```
session เดียว: SET statement_timeout = '2s';
               SELECT count(*) FROM orders WHERE created_at_naive < '2020-01-01';
               (คอลัมน์ไม่มี index บนตารางใหญ่)
```

**ground truth — ตัวแยกคือบรรทัดเดียวนี้**
```sql
SELECT pid, pg_blocking_pids(pid) AS blocked_by, state, query
FROM pg_stat_activity WHERE pid = <victim>;
```

| | `pg_blocking_pids` |
|---|---|
| F03 | **ไม่ว่าง** — มี pid ที่บล็อกอยู่ |
| F03b | **ว่าง** — ไม่มีใครบล็อก แค่ช้าเอง |

**assertion**
1. ทั้ง F03 และ F03b ต้องได้ข้อความ error **เหมือนกัน** (ถ้าต่างกัน = ออกแบบผิด ต้อง exit)
2. F03: `pg_blocking_pids()` ต้องไม่ว่าง
3. F03b: `pg_blocking_pids()` ต้องว่าง
4. ถ้าข้อ 2 หรือ 3 ไม่เป็นจริง = fault ไม่ได้เกิดตามที่ตั้งใจ ต้อง exit

**ทำไมข้อนี้สำคัญที่สุด:** LLM ที่เห็นแค่ข้อความ error แยกสองกรณีนี้ไม่ออกเลย
ต้องดูสถานะจริงของ DB เท่านั้น — นี่คือช่องว่างที่ `quietfail-check` จะเข้าไปเติม
และเป็นข้อที่ใช้เทียบกับ baseline "โยน error ให้ LLM อธิบายลอยๆ" ได้ตรงที่สุด

**สถานะ:** ยังไม่มีสคริปต์

---

## F05 — อ่านข้อมูลก็ค้าง เพราะ migration ที่ยังไม่ได้เริ่ม

| | |
|---|---|
| **อาการที่เห็น** | `SELECT` ธรรมดา timeout ทั้งที่ query เบามาก |
| **คนมักแก้ผิด** | โทษ network · โทษ DB ช้า · restart แอป |
| **ต้นเหตุจริง** | `ALTER TABLE` รออยู่ในคิว lock แล้ว**คิวบล็อกทุกคนที่มาทีหลัง** |
| **ทำไม dev ไม่เจอ** | ต้องมี 3 session เรียงกันพอดี |

**จุดที่หลอกที่สุด:** `ALTER TABLE` ยัง**ไม่ได้เริ่มทำงานเลย** มันแค่รอ
แต่การรอของมันทำให้ SELECT ที่ควรเสร็จใน 1ms ค้างไปด้วย

**วิธีฉีด**
```
session A:  BEGIN; SELECT * FROM orders LIMIT 1;        (ค้างไว้ ไม่ commit)
session B:  ALTER TABLE orders ADD COLUMN tmp int;      (จะรอ A)
session C:  SELECT * FROM orders LIMIT 1;               (ค้าง! ทั้งที่ควรได้ทันที)
```

**ground truth**
```sql
SELECT l.pid, l.granted, l.mode, a.state, a.query
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'orders'::regclass
ORDER BY l.granted DESC, a.query_start;
```

**assertion**
1. session C ต้องค้างเกิน 2 วินาที (query ที่ปกติเสร็จใน < 10ms)
2. `pg_locks` ต้องมีแถวที่ `granted = false` อย่างน้อย 2 แถว
3. ต้องไล่ห่วงโซ่ได้ว่า C ถูกบล็อกโดย B และ B ถูกบล็อกโดย A

**ต่อยอด:** I03 (`CREATE INDEX` บน vector column ไม่ใช้ `CONCURRENTLY`)
ใช้กลไกเดียวกันทุกประการ ทำ F05 เสร็จแล้ว I03 แทบไม่ต้องเขียนใหม่

**สถานะ:** ยังไม่มีสคริปต์

---

## F10 — statistics เก่า ทำให้ planner เลือกผิด

| | |
|---|---|
| **อาการที่เห็น** | query เดิม โค้ดเดิม แต่ช้าลงหลายสิบเท่า **ไม่มี error** |
| **คนมักแก้ผิด** | rewrite query · เพิ่ม index ที่ไม่จำเป็น |
| **ต้นเหตุจริง** | สถิติไม่ทันข้อมูล planner จึงประมาณจำนวนแถวผิด |
| **ทำไม dev ไม่เจอ** | dev ไม่ได้ bulk insert แล้ว query ทันที |

**วิธีฉีด**
```sql
ALTER TABLE orders SET (autovacuum_enabled = off);   -- กัน autovacuum มาช่วย
-- insert 1M แถวรวดเดียว โดยเอียงไปที่ merchant_id ค่าใหม่
-- query ทันทีโดยไม่ ANALYZE
```

**ground truth — ปิดวงจรได้ในตัว**
```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;   -- เทียบ rows= กับ actual rows=
ANALYZE orders;
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;   -- ต้องกลับมาเร็ว
```

ถ้าสั่ง `ANALYZE` แล้วหาย = ยืนยันสาเหตุแบบเถียงไม่ได้

**assertion**
1. ก่อน ANALYZE: `rows` ต่างจาก `actual rows` **≥ 10 เท่า**
2. หลัง ANALYZE: อัตราส่วนลดลงเหลือ ≤ 2 เท่า
3. buffers หลัง ANALYZE ต้องน้อยกว่าก่อน อย่างน้อย 5 เท่า
4. ถ้าข้อ 1 ไม่เป็นจริง = autovacuum แอบมาทำงาน ต้อง exit ไม่ใช่ปล่อยผ่าน

**ข้อมูลที่วัดไว้แล้ว (EXP01b Phase D) — ใช้เป็นฐานเปรียบเทียบ**
```
MCV ติดตาม 100 จาก n_distinct 4,677 = 2.1% ของค่าทั้งหมด
ค่าใน MCV   → เดาคลาด 0.6%
ค่านอก MCV  → เดาคลาด 50%
```
ความคลาด **แย่ที่สุดตรงค่าที่พบน้อย** ซึ่งเป็นจุดที่การเลือก plan สำคัญที่สุด
สถิติเก่าจะทำให้ตัวเลขนี้แย่ลงไปอีก

**สถานะ:** ยังไม่มีสคริปต์ · มีข้อมูลฐานจาก EXP01b แล้ว

---

# ชุด vector — 12 ข้อ (ล็อกแล้ว)

## ชั้น I — ติดตั้งและสร้าง index

| ID | fault | หลักฐาน |
|---|---|---|
| **I01** | opclass ตอนสร้างไม่ตรงกับ operator ตอน query → index ไม่เคยถูกใช้ | ✅ เอกสาร |
| **I02** | สร้าง IVFFlat ตอนตารางยังเล็ก → กลุ่มไม่สะท้อนข้อมูลจริง | ✅ เอกสาร |
| **I03** | `CREATE INDEX` ไม่ใช้ `CONCURRENTLY` → ล็อกตาราง (กลไกเดียวกับ F05) | ✅ เอกสาร |
| **I04** | k-means ของ IVFFlat สุ่ม → สร้างใหม่ได้คำตอบไม่เหมือนเดิม | ⚠️ ต้องพิสูจน์เอง |
| **I05** | `maintenance_work_mem` ต่ำ → build ช้าผิดปกติ | ✅ มีข้อความ NOTICE |

## ชั้น Q — เรียกใช้

| ID | fault | หลักฐาน |
|---|---|---|
| **Q01** ⭐ | recall collapse — เร็วขึ้นมาก ผลดูดี แต่ของที่ควรเจอหายไป | ✅ เอกสารเขียนเอง |
| **Q02** | เขียน `WHERE distance < x` แทน `ORDER BY ... LIMIT` | ✅ เอกสาร |
| **Q03** | filter ทำงานหลังสแกน index → ขอ 40 ได้ 4 | ✅ มีตัวเลขในเอกสาร |
| **Q04** | ใช้ค่า default โดยไม่เคยวัด (`probes = 1`) | ✅ วัดเองแล้ว |
| **Q06** | `LIMIT` มากกว่า `ef_search` (40) | ✅ FAQ ทางการ |

## ชั้น V — คุณภาพข้อมูล

| ID | fault | หลักฐาน |
|---|---|---|
| **V07** | NULL vector และ zero vector ไม่ถูก index → แถวหายถาวรเงียบสนิท | ✅ เอกสาร |

## ชั้น L — เสื่อมตามเวลา

| ID | fault | หลักฐาน |
|---|---|---|
| **L02** | dead tuple สะสม → index บวม recall ตก | ✅ FAQ ทางการ |

---

# ที่พิจารณาแล้วไม่รับเข้าชุด

**เลขที่หายไปคือข้อมูล ไม่ใช่ความผิดพลาด** — มันบอกว่าเคยพิจารณาแล้วตัดออก
**ห้ามเรียงเลขใหม่** เพราะไฟล์อื่นอ้างเลขเหล่านี้ไปแล้ว

| ID | fault | เหตุผลที่ตัด |
|---|---|---|
| F02 | deadlock จากลำดับ lock ไม่ตรงกัน | ซ้อนทับกับ F03 · เก็บไว้ถ้าเหลือเวลา |
| F04 | serialization failure ถูกแก้ผิดทาง | ต้องอธิบาย isolation level ยาว ต้นทุนสูง |
| F06 | temp file ระเบิดเพราะไม่มี index | ซ้อนทับกับ F10 |
| F07 | check-then-act ทำให้ข้อมูลซ้ำ | ไม่เกี่ยวกับ vector · ใช้เวลาสร้าง load test นาน |
| F08 | เงินเพี้ยนเพราะใช้ float | schema เตรียมไว้แล้ว แต่เป็น static check ล้วน ไม่ต้องฉีด |
| F09 | เวลาเพี้ยนเพราะ timestamp ไม่มี timezone | เหมือน F08 |
| F11 | มี index แต่ใช้ไม่ได้ | ซ้อนทับกับ I01 |
| F12 | ตารางบวมเพราะ transaction ค้าง | ซ้อนทับกับ L02 |
| Q05 | สลับ cosine กับ inner product | ยืนยันได้แค่บางส่วน · ซ้อนทับกับ I01 |
| L01 | พารามิเตอร์ไม่ scale ตามขนาดข้อมูล | ต้องมีข้อมูล 4 ขนาด ต้นทุนสูง |
| V08 | index ร่วมกันหลาย tenant กระทบ recall กัน | ต้องสร้างระบบหลาย tenant ก่อน |

> `init/02_schema.sql` มีคอมเมนต์อ้าง F06–F09, F11 อยู่
> เป็นเศษของแผนเดิม ไม่ใช่ข้อผิดพลาด — schema เตรียมของไว้แล้ว
> ถ้าอนาคตรับเข้าชุดก็ทำได้ทันที

---

# ผู้สมัครที่ยังไม่ตัดสิน

## F13 (เสนอ) — index ทำให้ query ช้าลง เพราะ lossy bitmap

**ค้นพบเองจาก EXP01b ไม่ได้อยู่ในแผนเดิม** ดู `DECISIONS.md` E08

| | |
|---|---|
| **อาการ** | เพิ่ม index แล้วช้าลง 27% **ไม่มี error** |
| **ต้นเหตุ** | `work_mem` เล็กเกิน → bitmap ลดชั้นเป็น lossy → อ่านทั้งหน้าแล้วคัดใหม่ |
| **จุดสำคัญ** | **planner เลือกเอง** — cost บอกถูกกว่า 4.5% แต่จริงแพงกว่า 27% |

**ยังไม่รับเข้าชุด** เพราะจะเกิน 12 ข้อ ซึ่งขัดกฎเหล็กข้อ 4

**เงื่อนไขที่ต้องตอบก่อนตัดสิน:** รัน EXP01b ซ้ำบนโปรไฟล์ `realistic` (`work_mem=4MB`)
- ถ้า lossy **หายไป** → เป็น "ปัญหาที่ config กลบไว้" คุณค่าลดลง อาจเก็บเป็นเชิงอรรถ
- ถ้า **ยังอยู่** → เป็น fault เต็มตัว ควรรับเข้าแทนข้อที่อ่อนกว่า

---

# สรุปสถานะการเขียนสคริปต์

| fault | นิยาม | สคริปต์ฉีด | groundtruth | รันจริงแล้ว |
|---|---|---|---|---|
| F01 | ✅ | ✅ | ⚠️ `verified_on: null` | ❌ |
| F03 + F03b | ✅ | ❌ | ❌ | ❌ |
| F05 | ✅ | ❌ | ❌ | ❌ |
| F10 | ✅ | ❌ | ❌ | ❌ |
| I01–L02 (12 ข้อ) | ตาราง | ❌ | ❌ | ❌ |

**เฟส 1 ผ่านเมื่อ:** F01, F03, F05, F10 มีครบทั้ง 4 คอลัมน์ และฉีดซ้ำได้ 3 ครั้งติด
