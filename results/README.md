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

## การตั้งชื่อ

```
exp<NN><ตัวอักษร>_<ชื่อสั้น>.txt
```

ตัวอักษรต่อท้ายใช้เมื่อเป็นการทดลองต่อยอดจากอันเดิม
เช่น `exp01b` คือการแก้ข้อบกพร่องของ `exp01`
