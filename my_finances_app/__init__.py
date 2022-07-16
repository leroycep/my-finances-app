import os
import codecs
import sqlite3
import http.server
import socketserver
import json
import importlib.resources as resources
from ofxparse import OfxParser


def main():
    with sqlite3.connect("transactions.sqlite3") as db:
        resetDbForImport(db)
        setupSchema(db)
        importOfxFiles(db)
    startHttpServer()


def convertOfx(db, filename):
    with codecs.open(filename) as fileobj:
        ofx = OfxParser.parse(fileobj)

    cur = db.cursor()
    cur.execute('''
        SELECT account_id FROM ofx_account_id_mapping
        WHERE ofx_id = ?
    ''', [int(ofx.account.account_id)])
    account_row = cur.fetchone()
    if account_row is None:
        print(f"Unknown ofx account id {ofx.account.account_id}")
        return

    account = account_row[0]
    stmt = ofx.account.statement

    cur.execute('''
        SELECT id, divisor FROM currency
        WHERE name = ?
    ''', ['USD'])

    currency_row = cur.fetchone()
    if currency_row is None:
        raise Exception("Unknown currency USD")
    currency = currency_row[0]
    currency_divisor = currency_row[1]

    # check if statement balance assertion already exists
    cur.execute('''
        SELECT
            strftime('%Y-%m-%d', datetime(date, 'unixepoch')),
            account_id FROM account_balance_assert
        WHERE date = ? AND account_id = ? AND balance = ?
        ''', (
            stmt.balance_date.timestamp(),
            account,
            int(stmt.balance * currency_divisor),
        ))

    if cur.fetchone() is not None:
        return

    for txn in stmt.transactions:
        cur.execute('''
            SELECT txn_id FROM ofx_txn_id_mapping
            WHERE ofx_account = ? AND ofx_txn = ?
            ''', (account, txn.id))

        if cur.fetchone() is not None:
            continue

        txn_id = None

        if txn.payee.startswith("Autosave") and txn.memo:
            txn_id_row = cur.execute(
                '''SELECT txn_id FROM txn_note WHERE description LIKE ?''',
                [txn.memo]
            ).fetchone()
            if txn_id_row:
                txn_id = txn_id_row[0]

        if not txn_id:
            cur.execute(
                '''INSERT INTO txn (date) VALUES (?)''',
                [txn.date.timestamp()]
            )
            txn_id = cur.lastrowid

        notes = [
            (txn_id, txn.payee)
        ]
        if txn.memo:
            notes.append((txn_id, txn.memo))

        extractPostings(cur, account, txn_id, txn, currency, currency_divisor)

        cur.executemany('''
            INSERT OR IGNORE INTO txn_note (txn_id, description)
            VALUES (?, ?)
            ''', notes)
        cur.execute('''
            INSERT INTO ofx_txn_id_mapping (ofx_account, ofx_txn, txn_id)
            VALUES (?, ?, ?)
            ''', [account, txn.id, txn_id])

    cur.execute('''
        INSERT INTO account_balance_assert (
            date,
            account_id,
            balance,
            currency
        ) VALUES (?, ?, ?, ?)
    ''', [
            stmt.balance_date.timestamp(),
            account,
            int(stmt.balance * currency_divisor),
            currency
        ])


def extractPostings(cur, account, txn_id, txn, currency, currency_divisor):
    amount = int(txn.amount * currency_divisor)
    postings = [
        (txn_id, account, amount, currency)
    ]
    notes = []

    cur.execute("""
        SELECT payee_contains, account_id
        FROM onimport_payee_contains_set_account
        WHERE instr(?, payee_contains) > 0
    """, [txn.payee])
    rows = cur.fetchall()
    if len(rows) > 1:
        for row in rows:
            print(row)
        raise Exception("Transaction maps to multiple accounts")
    elif len(rows) == 1:
        account_id = rows[0][1]
        postings.append((txn_id, account_id, -amount, currency))
        notes.append((txn_id, account_id, f"payee contained '{rows[0][0]}'"))

    cur.executemany('''
        INSERT INTO posting (txn_id, account_id, amount, currency)
        VALUES (?, ?, ?, ?)
    ''', postings)
    cur.executemany('''
        INSERT OR IGNORE INTO posting_note (txn_id, account_id, description)
        VALUES (?, ?, ?)
    ''', notes)


# Reset the database of stuff we can re-import
# TODO: split db in two and keep stuff we can re-import in memory
def resetDbForImport(db):
    db.executescript('''
        DROP TABLE IF EXISTS account_balance_assert;
        DROP TABLE IF EXISTS ofx_txn_id_mapping;
        DROP TABLE IF EXISTS posting_note;
        DROP TABLE IF EXISTS posting;
        DROP TABLE IF EXISTS txn_note;
        DROP TABLE IF EXISTS txn;
    ''')


# https://david.rothlis.net/declarative-schema-migration-for-sqlite/
def setupSchema(db: sqlite3.Connection):
    pristine = sqlite3.connect(":memory:")
    SCHEMA = resources.read_text("my_finances_app", "schema.sql")
    pristine.executescript(SCHEMA)

    pristine_tables = dict(pristine.execute('''
        SELECT name, sql FROM sqlite_schema
        WHERE type = "table" AND name != "sqlite_sequence"
    ''').fetchall())
    tables = dict(db.execute('''
        SELECT name, sql FROM sqlite_schema
        WHERE type = "table" AND name != "sqlite_sequence"
    ''').fetchall())

    new_tables = set(pristine_tables.keys()) - set(tables.keys())
    removed_tables = set(tables.keys()) - set(pristine_tables.keys())

    for t in new_tables:
        print(f"creating table {t}")
        db.execute(pristine_tables[t])

    for t in removed_tables:
        print(f"unknown table {t}")

    pristine.close()


def importOfxFiles(db):
    for root, dirs, files in os.walk("import/ofx"):
        for file in files:
            filepath = os.path.join(root, file)
            convertOfx(db, filepath)


# All transactions should add up to zero
def allTransactions(db):
    cur = db.cursor()

    num_imbalanced, = cur.execute('''
        SELECT COUNT(balance)
        FROM (
            SELECT SUM(posting.amount) as balance
            FROM posting
            GROUP BY posting.txn_id
        )
        WHERE balance != 0
    ''').fetchone()

    txns = cur.execute('''
        SELECT posting.txn_id, SUM(posting.amount) as balance
        FROM posting
        LEFT JOIN txn ON posting.txn_id = txn.id
        GROUP BY posting.txn_id
        ORDER BY txn.date DESC
    ''').fetchall()

    parts = ['''\
        <link rel="stylesheet" href="/style.css">"
        ''', f'''
        <p>There are {num_imbalanced} imbalanced transactions</p>
        ''', '''
        <table id="transactions">
        <caption>Transactions</caption>
        <thead>
            <tr>
                <th>Date</th>
                <th>Account</th>
                <th class='align-end' colspan=2>Amount</th>
                <th>Notes</th>
            </tr>
        </thead>
    ''']
    for txn_id, txn_balance in txns:
        is_error = txn_balance != 0
        if is_error:
            parts.append('<tbody class="error">')
        else:
            parts.append('<tbody>')

        parts.append('<tr class="heading">')
        txn_date, = cur.execute('''
            SELECT strftime('%Y-%m-%d', datetime(txn.date, 'unixepoch'))
            FROM txn
            WHERE id = ?
        ''', [txn_id]).fetchone()
        parts.append(f"<th>{txn_date}</th>")

        # get transaction notes
        parts.append('<td colspan=4>')
        if txn_balance != 0:
            parts.append('<div class="it">Transaction did not balance</div>')

        txn_notes = cur.execute('''
            SELECT description
            FROM txn_note
            WHERE txn_note.txn_id = ?
        ''', [txn_id]).fetchall()
        for (note, ) in txn_notes:
            parts.append('<div>')
            parts.append(note)
            parts.append('</div>')

        parts.append('</td>')

        parts.append('</tr>')

        # Generate postings
        postings = cur.execute('''
            SELECT
                account.name,
                CAST(posting.amount AS REAL) / currency.divisor,
                currency.name,
                account.id
            FROM posting
            LEFT JOIN account ON account.id = posting.account_id
            LEFT JOIN currency ON currency.id = currency
            WHERE posting.txn_id = ?
        ''', [txn_id]).fetchall()
        for account_name, amount, currency, account_id in postings:
            parts.extend([
                "<tr>",
                "<td></td>",
                f"<td>{account_name}</td>",
                f"<td class='align-end'>{str(amount)}</td>",
                f"<td class='align-center'>{currency}</td>",
                "<td class='align-end'>"
            ])

            post_notes = cur.execute('''
                SELECT description
                FROM posting_note
                WHERE txn_id = ? AND account_id = ?
            ''', [txn_id, account_id]).fetchall()
            for note in post_notes:
                parts.append(note[0])
            parts.append("</td></tr>")
        parts.append('</tbody>')

    parts.append("</table>")
    return parts


def assertionsBalance(db):
    parts = []

    cur = db.cursor()
    cur.execute('''
        SELECT date, account_id, balance, currency
        FROM account_balance_assert
        ORDER BY date
    ''')
    balance_asserts = cur.fetchall()

    parts.append('''\
        <link rel="stylesheet" href="/style.css">
        <table id="balance-assertions-invalid">
        <caption>Balance Assertion Errors</caption>
        <thead>
        <tr>
            <th>Date</th>
            <th>Account</th>
            <th>Expected</th>
            <th>Actual</th>
            <th>Difference</th>
        </tr>
        </thead>

        <tbody>
    ''')
    for ba in balance_asserts:
        assert_date = ba[0]
        assert_account = ba[1]
        assert_balance = ba[2]
        assert_currency = ba[3]
        account_balance = cur.execute('''
            SELECT SUM(amount)
            FROM posting
            LEFT JOIN txn ON txn_id = txn.id
            WHERE txn.date < ? AND account_id = ? AND currency = ?
        ''', (assert_date, assert_account, assert_currency)).fetchone()[0]
        if account_balance != assert_balance:
            account = cur.execute("""
                SELECT name FROM account WHERE id = ?
            """, [assert_account]).fetchone()[0]

            parts.extend([
                "<tr>",
                f"<td>{assert_date}</td>",
                f"<td>{account}</td>",
                f"<td>{assert_balance}</td>",
                f"<td>{account_balance}</td>",
                f"<td>{assert_balance - account_balance}</td>",
                "</tr>",
            ])
    parts.append("</tbody></table>")
    return parts


def accounts(db):
    parts = []

    parts.append('''\
        <link rel="stylesheet" href="/style.css">
        <script src="https://unpkg.com/htmx.org@1.8.0" defer></script>
        <script src="https://unpkg.com/htmx.org@1.8.0/dist/ext/json-enc.js" defer></script>

        <table id="accounts">
        <caption>Accounts</caption>
        <thead>
        <tr>
            <th>Account</th>
            <th colspan=2>Balance</th>
        </tr>
        </thead>

        <tbody>
    ''')

    accounts = db.execute('''
        SELECT
            account.name,
            CAST(SUM(posting.amount) AS REAL) / currency.divisor,
            currency.name
        FROM account
        LEFT JOIN posting ON posting.account_id = account.id
        LEFT JOIN currency ON posting.currency = currency.id
        GROUP BY account.name, currency.name
        ORDER BY account.name
    ''').fetchall()
    for name, balance, currency in accounts:
        parts.append('<tr>')
        parts.append(f'<td class="align-end">{name}</td>')
        if balance:
            parts.append(f'<td class="align-end mono">{balance}</td>')
            parts.append(f'<td class="mono">{currency}</td>')
        else:
            parts.append('<td></td>')
            parts.append('<td></td>')
        parts.append('</tr>')

    parts.append("</tbody></table>")
    parts.append('<form hx-post="/account" hx-ext="json-enc">')
    parts.append('<label for="name">Account Name: </label>')
    parts.append('<input name="name" type="text" />')
    parts.append('<button type="submit">Create</button>')
    parts.append("</form>")
    return parts


def createAccount(db, account_name):
    cur = db.cursor()
    cur.execute('''
        INSERT INTO account (name)
        VALUES
        (?);
    ''', [account_name])
    account_id = cur.lastrowid
    db.commit()

    parts = [f'''
        <p>Created account <a href="/account/{account_id}">{account_name}</a>
    ''']
    return parts


def rulesPayee(db):
    parts = []

    parts.append('''\
        <link rel="stylesheet" href="/style.css">
        <script src="https://unpkg.com/htmx.org@1.8.0" defer></script>
        <script src="https://unpkg.com/htmx.org@1.8.0/dist/ext/json-enc.js" defer></script>

        <table id="accounts">
        <caption>Payee Contains Rules</caption>
        <thead>
        <tr>
            <th>Payee Contains</th>
            <th>Set Account To</th>
        </tr>
        </thead>

        <tbody>
    ''')

    rules = db.execute('''
        SELECT
            rule.payee_contains,
            account.id,
            account.name
        FROM onimport_payee_contains_set_account AS rule
        LEFT JOIN account ON rule.account_id = account.id
        ORDER BY account.name, rule.payee_contains
    ''').fetchall()
    for payee_contains, account_id, account_name in rules:
        parts.append('<tr><input name="id" type="hidden" />')
        parts.append(f'<td><code>{payee_contains}</code></td>')
        parts.append(f'<td><code>{account_name}<code></td>')
        parts.append('</tr>')

    parts.append("</tbody></table>")
    parts.append('<form hx-post="/rule/payee" hx-ext="json-enc">')
    parts.append('<label for="payee_contains">If payee contains: </label>')
    parts.append('<input name="payee_contains" type="text" />')
    parts.append('<label for="account_name">Account: </label>')
    parts.append('<input name="account_name" type="text" />')
    parts.append('<button type="submit">Create</button>')
    parts.append("</form>")
    return parts


def createPayeeRule(db, payee_contains, account_name):
    cur = db.cursor()

    account_id, = cur.execute('''
        SELECT id FROM account WHERE name = ?
    ''', [account_name]).fetchone()

    if account_id is None:
        return ['Account does not exist']

    cur.execute('''
        INSERT INTO onimport_payee_contains_set_account
        (payee_contains, account_id)
        VALUES
        (?, ?);
    ''', [payee_contains, account_id])
    rule_id = cur.lastrowid
    db.commit()

    parts = [f'''
        <p>Created rule <a href="/rule/payee/{rule_id}">/rule/payee/{rule_id}</a>
    ''']
    return parts


def startHttpServer(port=45486):
    httpd = socketserver.TCPServer(
        ("", port),
        Handler,
        bind_and_activate=False
    )
    with httpd:
        httpd.allow_reuse_address = True
        httpd.server_bind()
        httpd.server_activate()
        print("serving at port ", port)
        print(f"http://localhost:{port}/")
        httpd.serve_forever()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, directory="www", **kwargs):
        self.db = sqlite3.connect("transactions.sqlite3")
        kwargs['directory'] = directory
        super(Handler, self).__init__(*args, **kwargs)

    def do_GET(self):
        parts = []
        if self.path == "/account":
            parts.extend(accounts(self.db))
        elif self.path == "/rule/payee":
            parts.extend(rulesPayee(self.db))
        elif self.path == "/assertions/balance":
            parts.extend(assertionsBalance(self.db))
        elif self.path == "/transactions":
            parts.extend(allTransactions(self.db))
        else:
            super(Handler, self).do_GET()
            return

        content_len = 0
        for part in parts:
            content_len += len(part)

        self.send_response(http.HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", content_len)
        self.end_headers()
        self.wfile.writelines(map(stringsToBytes, parts))

    def do_POST(self):
        if self.headers['Content-Length'] is None:
            return self.send_error("content-length must be set")
        content_len = int(self.headers['Content-Length'])
        data = json.loads(self.rfile.read(content_len))

        parts = []
        if self.path == "/account":
            if data["name"] is None:
                return self.send_error("name must not be none")
            parts.extend(createAccount(self.db, data["name"]))
        elif self.path == "/rule/payee":
            payee_contains = data["payee_contains"]
            account_name = data["account_name"]
            if payee_contains is None or account_name is None:
                return self.send_error("`payee_contains` and `account_name` must be set")
            parts.extend(createPayeeRule(self.db, payee_contains, account_name))

        content_len = 0
        for part in parts:
            content_len += len(part)

        self.send_response(http.HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", content_len)
        self.end_headers()
        self.wfile.writelines(map(stringsToBytes, parts))


def stringsToBytes(part_string: str):
    return part_string.encode()
