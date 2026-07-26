# คำสั่งสำหรับ Windows PowerShell

Windows ไม่มี `make` ใช้ตารางนี้แทนได้ทุกคำสั่ง
**ทุกคำสั่งต้องรันจากในโฟลเดอร์ที่มี `docker-compose.yml`**

---

## ก่อนอื่น: ย้ายโฟลเดอร์ออกจาก OneDrive

```powershell
mkdir C:\dev
Move-Item "C:\Users\DELL\OneDrive\เดสก์ท็อป\finalproject" C:\dev\pg-fault-lab
cd C:\dev\pg-fault-lab
dir     # ต้องเห็น docker-compose.yml
```

เหตุผล: OneDrive อาจเก็บไฟล์ไว้บนคลาวด์แทนที่จะเป็นไฟล์จริง และ path
ภาษาไทยเคยมีปัญหากับการ mount ของ Docker บน Windows
ทั้งสองอย่างทำให้เกิด error ที่ไล่หาสาเหตุยากมาก

---

## ตารางแปลงคำสั่ง

| Makefile | PowerShell |
|---|---|
| `make up` | `docker compose up -d` |
| `make down` | `docker compose down` |
| `make reset` | `docker compose down -v` แล้ว `docker compose up -d` |
| `make version` | ดูหัวข้อ "จดเวอร์ชัน" ข้างล่าง |
| `make check` | ดูหัวข้อ "เช็ค config" ข้างล่าง |
| `make seed-small` | ดูหัวข้อ "ใส่ข้อมูล" ข้างล่าง |
| `make seed` | ดูหัวข้อ "ใส่ข้อมูล" ข้างล่าง |
| `make psql` | `docker compose exec db psql -U lab -d faultlab` |
| `make f01` | ดูหัวข้อ "รัน fault" ข้างล่าง |

---

## เปิด database

```powershell
docker compose up -d
docker compose ps
```

ต้องเห็นสถานะ `Up` หรือ `healthy`
ถ้าเห็น `Exit 1` ให้ดู log:

```powershell
docker compose logs db
```

บรรทัดสำคัญอยู่ **ท้ายสุด** มองหา `FATAL` หรือ `ERROR`

---

## จดเวอร์ชัน (คำสั่งแรกที่ต้องรัน)

```powershell
docker compose exec db psql -U lab -d faultlab -c "SELECT version()"
docker compose exec db psql -U lab -d faultlab -c "SELECT extname, extversion FROM pg_extension ORDER BY 1"
```

เอาผลไปเติมใน README ทันที พร้อมวันที่

---

## เช็ค config

```powershell
docker compose exec db psql -U lab -d faultlab -c "SELECT name, setting FROM pg_settings WHERE name IN ('max_connections','work_mem','deadlock_timeout','log_lock_waits','temp_file_limit','lc_messages','shared_preload_libraries') ORDER BY name"
```

**ต้องได้ `max_connections` = 20**
ถ้าได้ 100 แปลว่าไฟล์ config ไม่ถูก mount → fault จะไม่มีทางเกิด

---

## ใส่ข้อมูล

ชุดเล็กก่อนเสมอ:

```powershell
docker compose exec db psql -U lab -d faultlab -v rows=200000 -f /sql/seed.sql
```

ชุดใหญ่ (หลายนาที):

```powershell
docker compose exec db psql -U lab -d faultlab -f /sql/seed.sql
```

ดูสองบรรทัดสุดท้ายที่พิมพ์ออกมา:
- `pct_orders_from_top_1pct_merchants` ต้องเป็นเลขสูง
- `drift` ต้อง **ไม่เป็น 0**

---

## เข้า psql

```powershell
docker compose exec db psql -U lab -d faultlab
```

คำสั่งที่ต้องรู้: `\dt` `\d orders` `\di` `\x` `\timing` `\q`

---

## รัน fault

รันข้างใน container เพื่อเลี่ยงปัญหา `.sh` บน Windows ทั้งหมด
คำสั่ง `tr -d '\r'` คือตัวลบ line ending แบบ Windows ทิ้ง

```powershell
docker compose exec db bash -c "tr -d '\r' < /faults/f01_idle_in_transaction.sh > /tmp/f01.sh && PGPORT=5432 bash /tmp/f01.sh"
```

ถ้า fault ไม่เกิด ให้เพิ่มจำนวน session:

```powershell
docker compose exec db bash -c "tr -d '\r' < /faults/f01_idle_in_transaction.sh > /tmp/f01.sh && PGPORT=5432 LEAKS=20 bash /tmp/f01.sh"
```

> `PGPORT=5432` เพราะข้างใน container ใช้พอร์ตจริง ส่วน 5433 คือพอร์ตที่เห็นจาก Windows

---

## กฎการล้างข้อมูล (จำให้แม่น)

| แก้อะไร | ต้องทำอะไร |
|---|---|
| `config/` | `docker compose up -d --force-recreate` |
| `sql/seed.sql` | รันคำสั่ง seed ใหม่ |
| **`init/`** | **`docker compose down -v` แล้ว `docker compose up -d`** |

`init/` รันครั้งเดียวตอนสร้าง database ครั้งแรกเท่านั้น
แก้แล้ว restart เฉยๆ ไม่มีผลอะไรเลย — คนติดตรงนี้กันเยอะที่สุด
