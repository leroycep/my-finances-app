CREATE TABLE currency (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    opened DATE NOT NULL,
    divisor INTEGER NOT NULL
);

CREATE TABLE account (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,

    UNIQUE(name)
);

CREATE TABLE ofx_account_id_mapping (
    ofx_id INTEGER NOT NULL UNIQUE,
    account_id INTEGER NOT NULL,

    FOREIGN KEY (account_id) REFERENCES account(id)
);

CREATE TABLE ofx_txn_id_mapping (
    ofx_account INTEGER NOT NULL,
    ofx_txn INTEGER NOT NULL,
    txn_id INTEGER NOT NULL,

    FOREIGN KEY (txn_id) REFERENCES txn(id),
    UNIQUE (ofx_account, ofx_txn)
);

CREATE TABLE onimport_payee_contains_set_account (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payee_contains TEXT NOT NULL UNIQUE,
    account_id INTEGER NOT NULL,

    FOREIGN KEY (account_id) REFERENCES account(id)
);

-- Stuff that can be imported from ofx files
CREATE TABLE account_balance_assert (
    date DATETIME NOT NULL,
    account_id INTEGER NOT NULL,
    balance INTEGER,
    currency INTEGER,

    FOREIGN KEY (account_id) REFERENCES account(id),
    FOREIGN KEY (currency) REFERENCES currency(id),
    PRIMARY KEY(date, account_id)
);

CREATE TABLE txn (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date DATETIME NOT NULL
);

CREATE TABLE posting (
    txn_id INTEGER NOT NULL,
    account_id INTEGER NOT NULL,
    amount INTEGER NOT NULL,
    currency INTEGER NOT NULL,

    FOREIGN KEY (txn_id) REFERENCES txn(id),
    FOREIGN KEY (account_id) REFERENCES account(id),
    FOREIGN KEY (currency) REFERENCES currency(id),
    PRIMARY KEY (txn_id, account_id)
);

CREATE TABLE txn_note (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    txn_id INTEGER NOT NULL,
    description TEXT NOT NULL UNIQUE,

    FOREIGN KEY (txn_id) REFERENCES txn(id)
);

CREATE TABLE posting_note (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    txn_id INTEGER NOT NULL,
    account_id INTEGER NOT NULL,
    description TEXT NOT NULL UNIQUE,

    FOREIGN KEY (txn_id) REFERENCES txn(id),
    FOREIGN KEY (account_id) REFERENCES account(id)
);
