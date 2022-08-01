PRAGMA foreign_keys=ON;

CREATE TABLE currencies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    day_opened INTEGER NOT NULL,
    divisor INTEGER NOT NULL
) STRICT;

CREATE TABLE ofx_banks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE ofx_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bank_id INTEGER NOT NULL,
    hash TEXT NOT NULL UNIQUE,

    FOREIGN KEY (bank_id) REFERENCES ofx_banks(id)
) STRICT;

CREATE TABLE ofx_account_names (
    account_id INTEGER NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,

    FOREIGN KEY (account_id) REFERENCES ofx_accounts(id)
) STRICT;

CREATE TABLE ofx_transactions (
    account_id INTEGER NOT NULL,
    id INTEGER NOT NULL,
    day_posted INTEGER NOT NULL,
    amount INTEGER NOT NULL,
    currency_id INTEGER NOT NULL,
    description TEXT NOT NULL,
    
    FOREIGN KEY (account_id) REFERENCES ofx_accounts(id),
    FOREIGN KEY (currency_id) REFERENCES currencies(id),
    PRIMARY KEY (account_id, id)
) STRICT;

CREATE TABLE ofx_ledger_balance (
    account_id INTEGER NOT NULL,
    day_posted INTEGER NOT NULL,
    amount INTEGER NOT NULL,
    currency_id INTEGER NOT NULL,

    FOREIGN KEY (account_id) REFERENCES ofx_accounts(id),
    FOREIGN KEY (currency_id) REFERENCES currencies(id),
    UNIQUE (account_id, day_posted)
) STRICT;

