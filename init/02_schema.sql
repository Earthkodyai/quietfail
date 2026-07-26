-- =============================================================
-- Schema ห้องทดลอง
--
-- ทุกจุดที่เขียนว่า [ผิดโดยตั้งใจ] คือของที่ใส่ไว้ให้ fault เกิด
-- ห้ามแก้จนกว่าจะเก็บผล baseline เสร็จ แล้วค่อยทำเวอร์ชันที่แก้แล้ว
-- มาเทียบกัน
-- =============================================================

CREATE TABLE merchants (
    id          bigserial PRIMARY KEY,
    name_th     text NOT NULL,   -- ตั้งใจให้เว้นวรรคไม่นิ่ง / มีสาขาต่อท้าย
    name_en     text,
    district    text NOT NULL,   -- ตั้งใจให้เขียนหลายแบบ (เขตบางรัก / บางรัก)
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE customers (
    id          bigserial PRIMARY KEY,
    email       text NOT NULL,   -- [ผิดโดยตั้งใจ] ไม่มี UNIQUE
    phone       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id            bigserial PRIMARY KEY,
    customer_id   bigint NOT NULL REFERENCES customers(id),
    merchant_id   bigint NOT NULL REFERENCES merchants(id),
    status        text   NOT NULL,

    total_satang  bigint NOT NULL,            -- ถูกต้อง: เก็บเป็นจำนวนเต็มสตางค์
    total_float   double precision NOT NULL,  -- [ผิดโดยตั้งใจ] F08 เงินเป็น float

    created_at       timestamptz NOT NULL,    -- ถูกต้อง
    created_at_naive timestamp   NOT NULL     -- [ผิดโดยตั้งใจ] F09 ไม่มี timezone
);

-- [ผิดโดยตั้งใจ] ไม่สร้าง index บน merchant_id และ customer_id
-- PostgreSQL ไม่สร้าง index ให้ foreign key อัตโนมัติ (ต่างจาก MySQL/InnoDB)
-- นี่คือหนึ่งในข้อที่ AI พลาดบ่อยที่สุดเพราะมันมองไม่เห็น query pattern จริง
-- ใช้กับ F11 และเป็นตัวเร่งของ F06

CREATE INDEX orders_created_at_idx ON orders (created_at);

CREATE TABLE payments (
    id              bigserial PRIMARY KEY,
    order_id        bigint NOT NULL REFERENCES orders(id),
    idempotency_key text   NOT NULL,  -- [ผิดโดยตั้งใจ] ไม่มี UNIQUE → F07
    amount_satang   bigint NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- ตารางว่างสำหรับส่วน AI / clustering
-- มิติของ vector ต้องตรงกับโมเดลที่คุณเลือกจริง อย่าลอกเลขนี้ไปใช้เฉยๆ
-- (384 = ขนาดของ sentence-transformer ตระกูล MiniLM ซึ่งเป็นแค่ค่าเริ่มต้นให้ลอง)
CREATE TABLE merchant_embeddings (
    merchant_id bigint PRIMARY KEY REFERENCES merchants(id),
    model       text NOT NULL,
    embedding   vector(384),
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ยังไม่สร้าง vector index ตอนนี้
-- เพราะพารามิเตอร์ของ HNSW/IVFFlat ต้องวัดกับข้อมูลจริงเท่านั้น
-- การเดาค่าแล้วใส่ไว้เฉยๆ คือสิ่งที่ทำให้โปรเจคดูไม่น่าเชื่อถือ

-- ------------------- สิทธิ์ -------------------
GRANT USAGE ON SCHEMA public TO app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO app;

GRANT USAGE ON SCHEMA public TO observer;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO observer;
