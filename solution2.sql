-- Q2 - University Fee Payments
-- (a) Tables

CREATE TABLE IF NOT EXISTS students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(10,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE IF NOT EXISTS payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(10,2) NOT NULL,
    logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) Function: fee balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_fee NUMERIC(10,2);
    v_paid NUMERIC(10,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_fee - v_paid;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: receive payment
-- Does NOT change fee_due. Rejects NULL/zero/negative and overpayment.
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
AS $$
DECLARE
    v_balance NUMERIC(10,2);
BEGIN
    IF p_student_id IS NULL OR p_amount IS NULL OR p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Student, amount and date must not be NULL';
    END IF;
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than zero';
    END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;
    INSERT INTO payments(student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: auto audit, procedure must NOT insert audit
CREATE OR REPLACE FUNCTION trg_payment_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit(payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payment_audit ON payments;
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit_fn();

-- (a) Seed data: 3 students, 6 payments, student 3 has no payments initially
INSERT INTO students(student_number, full_name, fee_due) VALUES
('STU001', 'Chanda Mwila', 5000.00),
('STU002', 'Grace Banda', 3000.00),
('STU003', 'Peter Phiri', 4000.00)
ON CONFLICT (student_number) DO NOTHING;

CALL pr_receive_payment(1, 1000.00, '2026-01-05');
CALL pr_receive_payment(1, 1500.00, '2026-01-12');
CALL pr_receive_payment(2, 500.00, '2026-01-06');
CALL pr_receive_payment(2, 500.00, '2026-01-10');
CALL pr_receive_payment(2, 500.00, '2026-01-15');
CALL pr_receive_payment(2, 1000.00, '2026-01-20');

-- (e) View: only students who still owe
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

-- (f) Index: composite for student + date range
-- Justification: Equality on student_id + range on paid_on matches the
-- WHERE student_id = ? AND paid_on BETWEEN ? AND ? query exactly,
-- so Postgres can seek instead of scanning all payments.
CREATE INDEX IF NOT EXISTS idx_payments_student_paidon
ON payments(student_id, paid_on);

-- Matching query + plan (run this in Postgres to show plan):
-- EXPLAIN SELECT * FROM payments
-- WHERE student_id = 1 AND paid_on BETWEEN '2026-01-01' AND '2026-01-31';
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN '2026-01-01' AND '2026-01-31';

-- (g) Scheduled job: refresh daily collections
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
AS $$
BEGIN
    INSERT INTO daily_collections(collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$ LANGUAGE plpgsql;

-- Test refresh:
CALL pr_refresh_collections('2026-01-05');

-- Schedule daily at 01:00 for previous day (pg_cron):
-- SELECT cron.schedule('refresh-collections-daily', '0 1 * * *',
--   $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);

-- Checks:
SELECT * FROM v_fee_balances;
SELECT fn_fee_balance(3);
SELECT * FROM payment_audit;
SELECT * FROM daily_collections;