PSQL_ADMIN = PGPASSWORD=labpass psql -h localhost -p 5433 -U lab -d faultlab
ROWS ?= 2000000

.PHONY: up down reset seed seed-small psql logs version f01 check

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
