# =============================================================
# ทางลัดสำหรับ Linux / macOS
#
# 🔴 Windows ไม่มี make — ใช้ WINDOWS.md แทน (คำสั่ง PowerShell ครบทุกอัน)
#
# ⚠️ ไฟล์นี้เคยค้างอยู่ที่เฟส 0 — มีแต่ f01 ข้อเดียวจาก 15 ข้อ และ
#    **ไม่มีเครื่องมือตรวจสักตัว** (audit.py · score.sql · quietfail_check.py)
#    ใครที่รัน `make help` บน Linux จะเข้าใจว่าโปรเจคไม่มีชั้นตรวจสอบเลย
#    ซึ่งเป็นภาพที่ผิด · ไม่มีอะไร error แค่ภาพไม่ครบ (เติมแล้ว 2026-08-02)
#
#    สาเหตุที่ค้างนาน: Makefile ไม่อยู่ใน DOC_FILES ของ audit.py จึงไม่มี
#    อะไรตรวจ — รูปแบบเดียวกับ results/README.md (กับดักข้อ 14ค)
# =============================================================
PSQL_ADMIN = PGPASSWORD=labpass psql -h localhost -p 5433 -U lab -d faultlab
# ค่าเริ่มต้นต้องเท่ากับขนาดที่ผลในรายงานใช้จริง ห้ามเปลี่ยนโดยไม่รันผลใหม่ทั้งชุด
# (เคยตั้งเป็น 2000000 ซึ่งไม่ตรงกับผลที่บันทึกไว้ — ดู E09 ใน DECISIONS.md)
ROWS ?= 200000

.PHONY: up down reset seed seed-small psql logs version f01 check \n        audit reproduce score sweep selfproof qfcheck claims cleanup help

up:            ## เปิด database
	docker compose up -d
	@echo "รอ database พร้อม..."
	@until docker compose exec -T db pg_isready -U lab -d faultlab >/dev/null 2>&1; \
	  do sleep 1; done
	@echo "พร้อมแล้ว: localhost:5433"

down:          ## ปิด (ข้อมูลยังอยู่)
	docker compose down

reset:         ## ล้างทุกอย่างแล้วเริ่มใหม่ (init scripts จะรันใหม่)
	docker compose down -v
	$(MAKE) up

seed:          ## ใส่ข้อมูล (ปรับได้: make seed ROWS=500000)
	$(PSQL_ADMIN) -v rows=$(ROWS) -f sql/seed.sql

seed-small:    ## ใส่ข้อมูลชุดเล็กไว้ทดสอบเร็ว
	$(MAKE) seed ROWS=200000

psql:          ## เข้า psql
	$(PSQL_ADMIN)

logs:          ## ดู log ของ postgres
	docker compose exec db tail -f /var/lib/postgresql/data/log/$$(docker compose exec -T db ls -t /var/lib/postgresql/data/log | head -1)

version:       ## บันทึกเวอร์ชันที่ใช้จริง — ต้องรันแล้วเก็บผลไว้ใน README
	@$(PSQL_ADMIN) -qAt -c "SELECT version()"
	@$(PSQL_ADMIN) -qAt -c "SELECT extname || ' ' || extversion FROM pg_extension ORDER BY 1"

check:         ## ตรวจว่า config เปราะถูกโหลดจริง
	@$(PSQL_ADMIN) -c "SELECT name, setting FROM pg_settings WHERE name IN \
	  ('max_connections','work_mem','deadlock_timeout','log_lock_waits', \
	   'temp_file_limit','lc_messages','shared_preload_libraries') ORDER BY name"

f01:           ## รัน fault F01
	bash faults/f01_idle_in_transaction.sh

# ---------- ชั้นตรวจสอบ (เพิ่ม 2026-08-02) ----------

audit:         ## ตรวจความพร้อมทั้ง repo — รันก่อน commit ทุกครั้ง
	python scripts/audit.py

reproduce:     ## รันตัวฉีดจริงซ้ำ 9 ข้อที่รันอัตโนมัติได้ (~32 นาที)
	python scripts/audit.py --reproduce

score:         ## ตอนนี้มี fault อะไรอยู่ (DETECTED / NOT_DETECTED / CANNOT_CHECK)
	$(PSQL_ADMIN) -f sql/score.sql

sweep:         ## กวาด sql/ ด้วยเกณฑ์ 8 ข้อที่ได้จากการทวนทีละไฟล์
	python scripts/sweep_sql.py

selfproof:     ## พิสูจน์ว่าหัวข้อของ audit ตอบลบได้จริง (สูตรข้อ 6 · ~20 นาที)
	python scripts/audit_selfproof.py

qfcheck:       ## ของส่งมอบ — ตรวจฐานข้อมูลของใครก็ได้ (ใช้ container ของ repo นี้)
	python scripts/quietfail_check.py --docker

claims:        ## ทวนว่าข้ออ้างที่ถอนแล้วไม่โผล่โดยไม่มีคำกำกับ
	python scripts/review_claims.py

cleanup:       ## ลบตารางทำงานขนาดใหญ่ที่สร้างใหม่ได้ (มี guard กัน qf_corpus)
	$(PSQL_ADMIN) -v ON_ERROR_STOP=1 -f sql/cleanup_scratch.sql

help:          ## แสดงคำสั่งทั้งหมด
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) 	  | sed 's/:.*##/	/' | sort
