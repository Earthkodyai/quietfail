-- เก็บ verdict ของ fault ที่กำลังพิสูจน์ จาก score_result ที่ score.sql เพิ่งสร้าง
-- ต้องเรียก **ทันที** หลัง \i /sql/score.sql เพราะ score.sql drop ตารางนั้นทิ้งทุกครั้ง
-- ต้องตั้ง :note ไว้ก่อน (ข้อความอธิบายสถานะ ใช้ตอนรายงานว่าข้อไหนพลาด)
INSERT INTO qf_states_log (fault, verdict, note)
SELECT fault_id, verdict, :'note'
FROM score_result
WHERE fault_id = upper(:'fault');

-- ถ้าไม่ได้อะไรเลย แปลว่า score.sql ไม่รู้จัก fault นี้ = ตรวจไม่ได้ ไม่ใช่ผ่าน
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM qf_states_log) THEN
        RAISE EXCEPTION 'score.sql ไม่ได้ให้ verdict ของ fault นี้เลย — ตรวจไม่ได้ (กฎเหล็กข้อ 10)';
    END IF;
END $$;
