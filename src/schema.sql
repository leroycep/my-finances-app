PRAGMA foreign_keys=ON;

CREATE TABLE currencies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    day_opened INTEGER NOT NULL,
    divisor INTEGER NOT NULL
) STRICT;

CREATE TABLE ofx_financial_institutions (
    fid TEXT NOT NULL PRIMARY KEY,
    org TEXT NOT NULL
) STRICT;

CREATE TABLE ofx_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash TEXT NOT NULL UNIQUE,
    fiid TEXT NOT NULL,

    FOREIGN KEY (fiid) REFERENCES ofx_financial_institutions(fid)
) STRICT;

CREATE TABLE ofx_account_names (
    account_id INTEGER NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,

    FOREIGN KEY (account_id) REFERENCES ofx_accounts(id)
) STRICT;

CREATE TABLE ofx_transactions (
    account_id INTEGER NOT NULL,
    id TEXT NOT NULL,
    day_posted INTEGER NOT NULL,
    amount INTEGER NOT NULL,
    currency_id INTEGER NOT NULL,
    description TEXT NOT NULL,
    
    FOREIGN KEY (account_id) REFERENCES ofx_accounts(id),
    FOREIGN KEY (currency_id) REFERENCES currencies(id),
    PRIMARY KEY (account_id, id)
) STRICT;
CREATE INDEX index_ofx_transactions_account ON ofx_transactions (account_id);
CREATE INDEX index_ofx_transactions_day_posted ON ofx_transactions (day_posted);

CREATE TABLE ofx_ledger_balance (
    account_id INTEGER NOT NULL,
    day_posted INTEGER NOT NULL,
    amount INTEGER NOT NULL,
    currency_id INTEGER NOT NULL,

    FOREIGN KEY (account_id) REFERENCES ofx_accounts(id),
    FOREIGN KEY (currency_id) REFERENCES currencies(id),
    UNIQUE (account_id, day_posted)
) STRICT;

CREATE VIEW ofx_running_balances AS
SELECT
  day_posted,
  account_id,
  SUM(amount) OVER (
    PARTITION BY account_id, currency_id
    ORDER BY day_posted ROWS BETWEEN
        UNBOUNDED PRECEDING
        AND CURRENT ROW
  ) AS balance,
  currency_id
FROM ofx_transactions
ORDER BY day_posted;