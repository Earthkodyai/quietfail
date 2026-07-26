-- =============================================================
-- สร้างข้อมูลทดลอง
--
-- รัน:  psql ... -f sql/seed.sql              (ค่าเริ่มต้น 2,000,000 orders)
--      psql ... -v rows=200000 -f sql/seed.sql   (รอบทดสอบเร็ว)
--
-- ทำไมถึง generate เอง ไม่ใช้ข้อมูลจริง:
--   fault injection ต้องรู้ ground truth 100% และต้องคุมการกระจายตัวได้
--   ข้อมูลจริงคุมความเบ้ไม่ได้ → พิสูจน์ไม่ได้ว่า planner พลาดเพราะอะไร
--   (ข้อมูลจริงยังต้องมี แต่ไปอยู่ชั้นการค้นหาภาษาไทย ไม่ใช่ชั้นนี้)
-- =============================================================

\if :{?rows}
\else
\set rows 2000000
\endif

\set merchants 5000
\set customers 200000

\timing on

TRUNCATE payments, merchant_embeddings, orders, customers, merchants
    RESTART IDENTITY CASCADE;

-- ---------- merchants: ชื่อไทยแบบสกปรกจงใจ ----------
INSERT INTO merchants (name_th, name_en, district)
SELECT
    (ARRAY['ร้าน','ครัว','ก๋วยเตี๋ยว','ข้าวมันไก่','ส้มตำ','กาแฟ','เบเกอรี่','ชาบู'])[1 + (g % 8)]
    -- เว้นวรรคไม่นิ่ง: บางร้านเว้นสองเคาะ บางร้านไม่เว้นเลย
    || CASE WHEN g % 11 = 0 THEN '  ' WHEN g % 17 = 0 THEN '' ELSE ' ' END
    || (ARRAY['ป้าแดง','ลุงหนวด','เจ๊หมวย','บ้านสวน','ริมคลอง','นายฮ้อย','แม่ศรี','ต้นมะขาม'])[1 + ((g / 8) % 8)]
    || CASE WHEN g % 13 = 0 THEN ' สาขา ' || (g % 20)::text ELSE '' END,

    (ARRAY['Pa Daeng','PA DAENG','Lung Nuad','Jae Muay','Baan Suan','Rim Klong'])[1 + (g % 6)],

    -- เขียนชื่อเขตหลายแบบ: วัตถุดิบของโจทย์ entity resolution
    CASE WHEN g % 3 = 0 THEN 'เขต' ELSE '' END
    || (ARRAY['บางรัก','ปทุมวัน','จตุจักร','ห้วยขวาง','ลาดพร้าว','คลองเตย','บางกะปิ','ดินแดง'])[1 + (g % 8)]
FROM generate_series(1, :merchants) AS g;

-- ---------- customers ----------
INSERT INTO customers (email, phone)
SELECT
    'user' || g || '@example.com',
    '08' || lpad((g % 100000000)::text, 8, '0')
FROM generate_series(1, :customers) AS g;

-- ---------- orders: ตัวหลัก มีความเบ้จงใจ ----------
-- power(random(), 4) ดันให้ merchant_id ต่ำๆ ได้ order เกือบทั้งหมด
-- เลียนแบบของจริง: ร้านดังไม่กี่ร้านกินยอดส่วนใหญ่
-- ความเบ้นี้คือสิ่งที่ทำให้ planner ประมาณ rows ผิด ซึ่งคือหัวใจของ F10
INSERT INTO orders (customer_id, merchant_id, status,
                    total_satang, total_float,
                    created_at, created_at_naive)
SELECT
    1 + floor(random() * :customers)::bigint,
    1 + floor(power(random(), 4) * :merchants)::bigint,
    (ARRAY['paid','pending','shipped','cancelled'])[1 + floor(power(random(), 3) * 4)::int],
    r.amt,
    r.amt / 100.0,                            -- F08: ปัดเศษหายทีละนิดในทุกแถว
    r.ts,
    r.ts AT TIME ZONE 'Asia/Bangkok'          -- F09: ทิ้ง timezone ตรงนี้
FROM generate_series(1, :rows) AS g,
-- ⚠️ ต้องมี g อยู่ใน subquery นี้ ห้ามเอาออก
--
-- LATERAL ที่ไม่อ้างถึงคอลัมน์ของ g เลย ไม่ถือว่า correlated
-- planner จึงยกไปคำนวณครั้งเดียวแล้วใช้ค่าเดิมซ้ำทุกแถว
-- ผลคือ created_at และ total_satang มีค่าเดียวทั้ง 200,000 แถว
-- โดยไม่มี error และจำนวนแถวถูกต้องทุกประการ (ดู E17)
--
-- ต้องเก็บ amt ไว้ใน subquery เดียว เพราะ total_satang กับ total_float
-- ต้องมาจาก **ค่าเดียวกัน** ไม่งั้น F08 (float drift) วัดไม่ได้
LATERAL (
    SELECT
        (5000 + floor(random() * 400000))::bigint AS amt,
        now() - (random() * interval '540 days') AS ts,
        g AS _force_correlated
) AS r;

-- ---------- payments: ประมาณ 5% ของ orders ----------
INSERT INTO payments (order_id, idempotency_key, amount_satang)
SELECT o.id, 'seed-' || o.id, o.total_satang
FROM orders o
WHERE o.id % 20 = 0 AND o.status = 'paid';

-- ANALYZE ตรงนี้เพื่อให้จุดเริ่มต้นสะอาด
-- F10 (statistics เก่า) จะไปทำ bulk insert ของตัวเองแล้วจงใจไม่ ANALYZE
ANALYZE;

-- =============================================================
-- assertion — เพิ่มหลังโดนบั๊กจริง (E17)
--
-- บั๊กเดิมทำให้ created_at และ total_satang มีค่าเดียวทั้งตาราง
-- โดยที่ **จำนวนแถวถูกต้อง ชนิดถูกต้อง ไม่มี error**
-- ตรวจแค่ count(*) จึงจับไม่ได้ ต้องตรวจว่าค่ามันหลากหลายจริง
-- =============================================================
DO $$
DECLARE
    n_ts   bigint;
    n_amt  bigint;
    n_mer  bigint;
    n_rows bigint;
BEGIN
    SELECT count(*),
           count(DISTINCT created_at),
           count(DISTINCT total_satang),
           count(DISTINCT merchant_id)
      INTO n_rows, n_ts, n_amt, n_mer
    FROM orders;

    -- เกณฑ์หลวมๆ พอที่จะจับ "ค่าเดียวทั้งตาราง" ได้แน่นอน
    -- แต่ไม่ผูกกับตัวเลขที่ยังไม่ได้วัด (กฎเหล็กข้อ 2)
    IF n_ts < greatest(1000, n_rows / 100) THEN
        RAISE EXCEPTION
            'created_at มีค่าไม่ซ้ำแค่ % จาก % แถว — LATERAL ถูกยกไปคำนวณครั้งเดียวหรือเปล่า (ดู E17)',
            n_ts, n_rows;
    END IF;

    IF n_amt < 1000 THEN
        RAISE EXCEPTION
            'total_satang มีค่าไม่ซ้ำแค่ % จาก % แถว — ดู E17', n_amt, n_rows;
    END IF;

    IF n_mer < 100 THEN
        RAISE EXCEPTION
            'merchant_id มีค่าไม่ซ้ำแค่ % — ความเบ้ที่ F10 ต้องใช้หายไป', n_mer;
    END IF;

    RAISE NOTICE
        'assertion ผ่าน: % แถว · created_at ไม่ซ้ำ % · total_satang ไม่ซ้ำ % · merchant_id ไม่ซ้ำ %',
        n_rows, n_ts, n_amt, n_mer;
END $$;

-- ---------- สรุปให้ดูว่าได้อะไรมา ----------
SELECT 'merchants' AS t, count(*) FROM merchants
UNION ALL SELECT 'customers', count(*) FROM customers
UNION ALL SELECT 'orders',    count(*) FROM orders
UNION ALL SELECT 'payments',  count(*) FROM payments;

-- ยืนยันว่าความเบ้เกิดขึ้นจริง: 1% ของร้านควรกินสัดส่วนใหญ่มาก
SELECT
    round(100.0 * sum(c) FILTER (WHERE rn <= :merchants / 100) / sum(c), 1)
        AS pct_orders_from_top_1pct_merchants
FROM (
    SELECT count(*) AS c, row_number() OVER (ORDER BY count(*) DESC) AS rn
    FROM orders GROUP BY merchant_id
) s;

-- ยืนยันว่า float ทำเงินเพี้ยนจริง (F08)
SELECT
    sum(total_satang) / 100.0        AS correct_baht,
    sum(total_float)::numeric        AS float_baht,
    sum(total_satang) / 100.0 - sum(total_float)::numeric AS drift
FROM orders;
