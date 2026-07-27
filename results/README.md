# results/

ผลการทดลองดิบ **ห้ามแก้ด้วยมือ** — ทุกไฟล์ต้องมาจากการรันสคริปต์เท่านั้น

## กฎ

- ทุกไฟล์ต้องมีหัวข้อ environment (version + วันที่) อยู่ข้างใน
  ถ้าไม่มี = ใช้อ้างอิงไม่ได้ ให้รันใหม่
- ไฟล์ในโฟลเดอร์นี้ถูก gitignore โดยค่าเริ่มต้น เพราะรันบ่อยแล้วจะรก
- ผลที่จะ**อ้างอิงในรายงาน** ต้อง force add เก็บเป็นหลักฐาน:

```powershell
git add -f results/ชื่อไฟล์.txt
```

## ไฟล์ที่เก็บเป็นหลักฐานแล้ว

| ไฟล์ | เนื้อหา | วันที่ |
|---|---|---|
| `exp00_default_guc.txt` | ค่า default ของ pgvector 0.8.5 | 2026-07-26 |
| `exp01_index_selectivity.txt` | index selectivity, count(*) | 2026-07-26 |
| `exp01b_heap_access.txt` | index selectivity, บังคับอ่าน heap | 2026-07-26 |
| `qf00_phase0_gate.txt` | หลักฐานปิดเฟส 0: ชุด query + corpus + recall = 1.0 ตอนไม่มี index | 2026-07-26 |
| `exp01b_realistic.txt` | EXP01b ซ้ำบนโปรไฟล์ realistic — lossy หายไป | 2026-07-26 |
| `exp01c_work_mem_threshold.txt` | หา work_mem ที่ lossy เริ่มเกิด + buffers มองไม่เห็น fault นี้ | 2026-07-26 |
| `f01_phase1_cycle.txt` | F01 ครบวงจร ฉีด→วินิจฉัย→นับคะแนน 3 รอบติด | 2026-07-26 |
| `f05_phase1_cycle.txt` | F05 ครบวงจร + ห่วงโซ่ lock 3 รอบติด | 2026-07-26 |
| `f03_phase1_cycle.txt` | F03+F03b ข้อความ error เดียวกัน สองสาเหตุ 3 รอบติด | 2026-07-26 |
| `f10_phase1_cycle.txt` | F10 สถิติเก่า → buffers ต่างกัน 323 เท่า 3 รอบติด | 2026-07-27 |
| `q01_recall_collapse_100k.txt` | **Q01 ตัวชูโรง** — เร็วขึ้น 44.6× recall@10 เหลือ 0.787 | 2026-07-27 |
| `q01_recall_collapse_500k.txt` | **Q01 ที่ 500k** — HNSW เร็วขึ้น 117× แต่ recall@10 เหลือ 0.589 | 2026-07-27 |
| `q01_qdrant_cross_engine.txt` | **เฟส 2.5** — Q01 บน Qdrant ด้วยเฉลยชุดเดียวกัน | 2026-07-27 |
| `i01_phase3_cycle.txt` | **I01** — opclass ผิด จ่าย 195 MB ได้ศูนย์ · ตัวตรวจ static 3 สถานะ | 2026-07-27 |
| `i05_phase3_cycle.txt` | **I05** — build ช้าลง 3 เท่า · NOTICE นิ่ง 0.03% · ตัวตรวจทำนายจุด spill ได้ | 2026-07-27 |
| `i03_phase3_cycle.txt` | **I03** — CREATE INDEX บล็อกการเขียน แต่การอ่านปกติ · ตัวนับพลิก 3 สถานะ | 2026-07-27 |
| `q06_phase3_cycle.txt` | **Q06** — ขอ 100 ได้ 40 · หน้าผาที่ k = ef+1 · ไม่มี error | 2026-07-27 |

## การตั้งชื่อ

```
exp<NN><ตัวอักษร>_<ชื่อสั้น>.txt
```

ตัวอักษรต่อท้ายใช้เมื่อเป็นการทดลองต่อยอดจากอันเดิม
เช่น `exp01b` คือการแก้ข้อบกพร่องของ `exp01`
