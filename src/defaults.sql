
INSERT OR IGNORE INTO
currencies (name, day_opened, divisor)
VALUES
('USD', CAST(JULIANDAY('1792-04-02') AS INT), 100);

