#!/usr/bin/env python3
"""Exercise the real commerce SQL against the bundled schema and seed.

This uses only Python's standard library and temporary in-memory databases. SQL
is extracted from the Swift services so renamed columns or invalid queries fail
here. It verifies persistence, constraints, rollback, snapshots and report date
filters; it does NOT execute Swift pricing, authorization or UI code. Run the
XCTest suite on macOS for those behaviors and the authoritative build check.
"""
from contextlib import contextmanager
from pathlib import Path
import json
import re
import sqlite3
import textwrap
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Sources" / "HungrySpotCore"
SERVICES = CORE / "Services"
SERVICE_NAMES = ("OrderService", "PaymentService", "ReportingService", "ExpenseService", "AuditService")


def source_sql(name):
    source = (SERVICES / f"{name}.swift").read_text(encoding="utf-8-sig")
    pattern = r'\bsql:\s*(?:"""(.*?)"""|"((?:[^"\\]|\\.)*)")'
    statements = []
    for match in re.finditer(pattern, source, re.DOTALL):
        sql = textwrap.dedent(match[1]).strip() if match[1] is not None else json.loads('"' + match[2] + '"')
        if r"\(" in sql:
            raise AssertionError(f"Unexpected interpolation in {name} SQL: {sql}")
        statements.append(sql)
    return statements


SQL = {name: source_sql(name) for name in SERVICE_NAMES}


def statement(name, prefix):
    found = [sql for sql in SQL[name] if " ".join(sql.split()).startswith(prefix)]
    if len(found) != 1:
        raise AssertionError(f"Expected one {name} statement starting {prefix!r}, found {len(found)}")
    return found[0]


@contextmanager
def transaction(connection):
    connection.execute("BEGIN IMMEDIATE")
    try:
        yield
        connection.execute("COMMIT")
    except BaseException:
        connection.execute("ROLLBACK")
        raise


class CommerceSQLTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:", isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript((CORE / "Resources" / "001_schema.sql").read_text(encoding="utf-8-sig"))
        self.db.executescript((CORE / "Resources" / "seed.sql").read_text(encoding="utf-8-sig"))
        self.user_id = self.db.execute(
            "INSERT INTO users(username,password_hash,password_salt,password_iterations,role,is_active,created_at) VALUES(?,?,?,?,?,?,?)",
            ("fixture_admin", bytes(32), bytes(32), 600_000, "admin", 1, 100),
        ).lastrowid
        self.burger = self.db.execute("SELECT * FROM products WHERE name=?", ("Zinger Burger",)).fetchone()
        self.pizza = self.db.execute("SELECT * FROM products WHERE name=?", ("Chicken Tikka",)).fetchone()
        self.medium = self.db.execute("SELECT * FROM product_variants WHERE product_id=? AND name=?", (self.pizza["id"], "Medium")).fetchone()

    def tearDown(self):
        self.db.close()

    def execute_service(self, name, prefix, parameters=()):
        return self.db.execute(statement(name, prefix), parameters)

    def count(self, table):
        # Table names in these tests are fixed identifiers, never user inputs.
        return self.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def audit(self, action, order_id):
        self.execute_service("AuditService", "INSERT INTO audit_logs", (self.user_id, "fixture_admin", action, f"Order {order_id}", "SQL fixture", 200))

    def punch(self, *, pizza=False, quantity=1, request_id=None, created_at=100, discount=0, delivery=0, customer=""):
        """Persist manually quoted fixture values using the exact service SQL."""
        product = self.pizza if pizza else self.burger
        base = self.medium["price"] if pizza else product["base_price"]
        extras = self.medium["topping_price"] * 2 + 5_000 if pizza else 0
        subtotal = (base + extras) * quantity
        total = subtotal + delivery - discount
        request_id = request_id or str(uuid.uuid4())
        with transaction(self.db):
            row = self.execute_service("OrderService", "INSERT INTO orders(", (
                request_id, "{\"fixture\":true}", f"PENDING-{request_id}", "DELIVERY" if delivery else "DINE-IN", "PUNCHED",
                created_at, self.user_id, "fixture_admin", customer, "03300000000" if delivery else "", "Fixture Road" if delivery else "", "", "",
                subtotal, delivery, discount, total,
            ))
            order_id = row.lastrowid
            self.execute_service("OrderService", "UPDATE orders SET order_number", (f"HS-{order_id:06}", order_id))
            category = self.db.execute("SELECT name FROM categories WHERE id=?", (product["category_id"],)).fetchone()[0]
            item_id = self.execute_service("OrderService", "INSERT INTO order_items(", (
                order_id, product["id"], product["name"], category, self.medium["name"] if pizza else None, base, extras, quantity, "No onions",
            )).lastrowid
            if pizza:
                for name, amount, option_quantity in (("Selected variant: Medium", 0, 1), ("Extra Topping", self.medium["topping_price"], 2), ("Dip Sauce", 5_000, 1)):
                    self.execute_service("OrderService", "INSERT INTO order_item_options(", (item_id, name, option_quantity, amount, product["id"], self.medium["id"]))
            self.audit("Order punched", order_id)
        return order_id, total

    def pay(self, order_id, total, paid_at=200):
        with transaction(self.db):
            self.execute_service("PaymentService", "INSERT INTO payments(", (order_id, total, "CASH", self.user_id, paid_at))
            self.execute_service("PaymentService", "UPDATE orders SET status", ("COMPLETED", order_id))
            self.audit("Payment recorded", order_id)
            self.audit("Order completed", order_id)

    def report_orders(self, start, end):
        return self.execute_service("ReportingService", "SELECT o.id, o.type", (start, end)).fetchall()

    def test_every_static_service_sql_prepares_against_current_schema(self):
        for name, statements in SQL.items():
            self.assertTrue(statements, f"No SQL was extracted from {name}")
            for sql in statements:
                with self.subTest(service=name, sql=sql):
                    self.db.execute("EXPLAIN " + sql, [None] * sql.count("?")).fetchall()

    def test_order_round_trip_and_snapshot_prices_names_options(self):
        order_id, total = self.punch(pizza=True, quantity=2)
        self.assertEqual(total, 230_000)
        self.db.execute("UPDATE products SET name='Changed',base_price=1 WHERE id=?", (self.pizza["id"],))
        self.db.execute("UPDATE product_variants SET name='Changed size',price=1,topping_price=1 WHERE id=?", (self.medium["id"],))
        order = self.execute_service("OrderService", "SELECT * FROM orders WHERE id", (order_id,)).fetchone()
        items = self.execute_service("OrderService", "SELECT * FROM order_items WHERE order_id", (order_id,)).fetchall()
        options = self.execute_service("OrderService", "SELECT op.* FROM order_item_options", (order_id,)).fetchall()
        self.assertEqual(order["order_number"], f"HS-{order_id:06}")
        self.assertEqual(items[0]["product_name"], "Chicken Tikka")
        self.assertEqual(items[0]["variant_name"], "Medium")
        self.assertEqual(items[0]["unit_price"], 90_000)
        self.assertEqual(sum(o["quantity"] * o["unit_price"] for o in options), items[0]["extra_price"])
        self.assertEqual(sum((i["unit_price"] + i["extra_price"]) * i["quantity"] for i in items), order["subtotal"])

    def test_duplicate_request_cannot_create_a_second_order(self):
        request_id = str(uuid.uuid4())
        order_id, _ = self.punch(request_id=request_id)
        existing = self.execute_service("OrderService", "SELECT id, request_payload, cashier_id", (request_id,)).fetchone()
        self.assertEqual(existing["id"], order_id)
        self.assertEqual(existing["cashier_id"], self.user_id)
        with self.assertRaises(sqlite3.IntegrityError):
            self.punch(request_id=request_id)
        self.assertEqual(self.count("orders"), 1)
        self.assertEqual(self.count("order_items"), 1)

    def test_item_failure_rolls_back_order_and_all_snapshots(self):
        self.db.execute("CREATE TRIGGER fail_option BEFORE INSERT ON order_item_options BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.punch(pizza=True)
        for table in ("orders", "order_items", "order_item_options", "audit_logs"):
            self.assertEqual(self.count(table), 0)
        self.db.execute("DROP TRIGGER fail_option")
        self.punch(pizza=True)
        self.assertEqual(self.count("orders"), 1)

    def test_payment_unique_and_audit_failure_rolls_back_payment_and_status(self):
        order_id, total = self.punch()
        self.execute_service("OrderService", "UPDATE orders SET status", ("PAYMENT PENDING", "", order_id))
        self.db.execute("CREATE TRIGGER fail_audit BEFORE INSERT ON audit_logs WHEN NEW.action='Payment recorded' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.pay(order_id, total)
        self.assertEqual(self.count("payments"), 0)
        self.assertEqual(self.execute_service("OrderService", "SELECT * FROM orders WHERE id", (order_id,)).fetchone()["status"], "PAYMENT PENDING")
        self.db.execute("DROP TRIGGER fail_audit")
        self.pay(order_id, total)
        with self.assertRaises(sqlite3.IntegrityError):
            self.pay(order_id, total)
        self.assertEqual(self.count("payments"), 1)
        payment = self.execute_service("OrderService", "SELECT * FROM payments WHERE order_id", (order_id,)).fetchone()
        self.assertEqual(payment["amount"], total)

    def test_report_uses_payment_dates_half_open_range_and_completed_sales(self):
        paid, total = self.punch(created_at=1)
        self.pay(paid, total, paid_at=200)
        self.execute_service("OrderService", "UPDATE orders SET status", ("COMPLETED", "", paid))
        boundary, amount = self.punch(created_at=1)
        self.pay(boundary, amount, paid_at=300)
        self.punch(created_at=210)  # Unpaid order is not revenue.
        cancelled, _ = self.punch(created_at=210)
        self.execute_service("OrderService", "UPDATE orders SET status", ("CANCELLED", "Customer cancelled", cancelled))
        selected = self.report_orders(200, 300)
        self.assertEqual([r["id"] for r in selected], [paid])
        self.assertEqual(sum(r["amount"] for r in selected), 35_000)
        items = self.execute_service("ReportingService", "SELECT i.* FROM order_items", (200, 300)).fetchall()
        self.assertEqual([r["order_id"] for r in items], [paid])
        self.assertEqual(len(self.report_orders(300, 301)), 1)

    def test_report_items_preserve_historical_categories_and_names(self):
        order_id, total = self.punch()
        self.pay(order_id, total)
        self.db.execute("UPDATE products SET name='New name',base_price=1 WHERE id=?", (self.burger["id"],))
        self.db.execute("UPDATE categories SET name='New category' WHERE id=?", (self.burger["category_id"],))
        items = self.execute_service("ReportingService", "SELECT i.* FROM order_items", (0, 1000)).fetchall()
        self.assertEqual(items[0]["product_name"], "Zinger Burger")
        self.assertEqual(items[0]["category_name"], "Burgers")
        self.assertEqual(items[0]["unit_price"], 35_000)

    def test_paid_zero_and_delivery_discount_totals_are_retained(self):
        free, amount = self.punch(discount=35_000)
        self.assertEqual(amount, 0)
        self.pay(free, amount)
        delivered, amount = self.punch(quantity=2, discount=5_000, delivery=10_000, customer="Delivery Customer")
        self.assertEqual(amount, 75_000)
        self.pay(delivered, amount)
        report = self.report_orders(0, 1000)
        self.assertEqual(len(report), 2)
        self.assertEqual(sum(r["amount"] for r in report), 75_000)
        self.assertEqual(sum(r["delivery_charge"] for r in report), 10_000)

    def test_used_products_and_variants_cannot_be_deleted(self):
        self.punch(pizza=True)
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM products WHERE id=?", (self.pizza["id"],))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM product_variants WHERE id=?", (self.medium["id"],))
        self.assertEqual(self.db.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_expense_range_and_audit_rollback(self):
        insert = statement("ExpenseService", "INSERT INTO expenses(")
        with transaction(self.db):
            self.db.execute(insert, (200, 12_500, "Gas", self.user_id))
            self.audit("Expense added", 1)
        self.db.execute(insert, (300, 5_000, "Outside range", self.user_id))
        rows = self.execute_service("ExpenseService", "SELECT id, expense_date", (200, 300)).fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["description"], "Gas")
        report = self.execute_service("ReportingService", "SELECT amount FROM expenses", (200, 300)).fetchall()
        self.assertEqual(sum(r["amount"] for r in report), 12_500)
        self.db.execute("CREATE TRIGGER fail_expense_audit BEFORE INSERT ON audit_logs WHEN NEW.action='Expense added' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            with transaction(self.db):
                self.db.execute(insert, (250, 500, "Rollback", self.user_id))
                self.audit("Expense added", 3)
        self.assertEqual(self.count("expenses"), 2)

    def test_dynamic_order_search_is_literal_and_pagination_is_stable(self):
        matched, _ = self.punch(customer="Customer 100%_special", created_at=100)
        newest, _ = self.punch(created_at=100)
        source = (SERVICES / "OrderService.swift").read_text(encoding="utf-8-sig")
        # This service builds one SELECT from literal strings. Use the same
        # fragments rather than maintaining a separate handwritten search.
        def fragment(pattern):
            result = re.search(pattern, source)
            self.assertIsNotNone(result)
            return json.loads('"' + result[1] + '"')
        base = fragment(r'var sql = "([^"]+)"')
        active = fragment(r'if activeOnly \{ sql \+= "([^"]+)"')
        search = fragment(r'sql \+= "( AND \(instr[^\n]+)"')
        ordering = fragment(r'sql \+= "( ORDER BY created_at[^\n]+)"')
        rows = self.db.execute(base + search + ordering, ("%_", "%_", "%_", 10, 0)).fetchall()
        self.assertEqual([r["id"] for r in rows], [matched])
        injection = "' OR 1=1 --"
        self.assertEqual(self.db.execute(base + search + ordering, (injection, injection, injection, 10, 0)).fetchall(), [])
        self.assertEqual(self.db.execute(base + active + ordering, (1, 0)).fetchone()["id"], newest)
        self.assertEqual(self.db.execute(base + active + ordering, (1, 1)).fetchone()["id"], matched)

    def filtered_orders(self, *, order_type=None, payment="all", start=None, end=None, term="", limit=100, offset=0):
        """Exercise literal query fragments from Swift, not a replacement Swift service."""
        source = (SERVICES / "OrderService.swift").read_text(encoding="utf-8-sig")
        fragments = [json.loads('"' + value + '"') for value in re.findall(r'(?:var sql =|sql \+=) "([^"\n]+)"', source)]
        def clause(prefix):
            matches = [sql for sql in fragments if sql.startswith(prefix)]
            self.assertEqual(len(matches), 1, prefix)
            return matches[0]
        sql = clause("SELECT id FROM orders")
        params = []
        if order_type:
            sql += clause(" AND type =")
            params.append(order_type)
        if payment == "pending":
            sql += clause(" AND status = ? AND NOT EXISTS")
            params.append("PAYMENT PENDING")
        elif payment == "paid":
            sql += clause(" AND status IN ('PAID', 'COMPLETED') AND EXISTS")
        elif payment == "cancelled":
            sql += next(value for value in fragments if value == " AND status = ?")
            params.append("CANCELLED")
        if start is not None:
            sql += clause(" AND created_at >=")
            params += [start, end]
        if term:
            sql += clause(" AND (instr")
            params += [term, term, term]
        sql += clause(" ORDER BY created_at")
        params += [limit, offset]
        return [row["id"] for row in self.db.execute(sql, params)]

    def test_payment_completion_and_both_audits_commit_together(self):
        order_id, total = self.punch()
        self.execute_service("OrderService", "UPDATE orders SET status", ("PAYMENT PENDING", "", order_id))
        for trigger in (
            "CREATE TRIGGER fail_completion BEFORE UPDATE OF status ON orders WHEN NEW.status='COMPLETED' BEGIN SELECT RAISE(ABORT,'failure'); END",
            "CREATE TRIGGER fail_completion BEFORE INSERT ON audit_logs WHEN NEW.action='Order completed' BEGIN SELECT RAISE(ABORT,'failure'); END",
        ):
            self.db.execute(trigger)
            with self.assertRaises(sqlite3.IntegrityError):
                self.pay(order_id, total)
            self.assertEqual(self.count("payments"), 0)
            self.assertEqual(self.db.execute("SELECT status FROM orders WHERE id=?", (order_id,)).fetchone()[0], "PAYMENT PENDING")
            self.assertEqual(self.db.execute("SELECT COUNT(*) FROM audit_logs WHERE action='Payment recorded'").fetchone()[0], 0)
            self.db.execute("DROP TRIGGER fail_completion")
        self.pay(order_id, total)
        self.assertEqual(self.db.execute("SELECT status FROM orders WHERE id=?", (order_id,)).fetchone()[0], "COMPLETED")
        self.assertEqual(self.db.execute("SELECT amount FROM payments WHERE order_id=?", (order_id,)).fetchone()[0], total)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM audit_logs WHERE action IN ('Payment recorded','Order completed')").fetchone()[0], 2)

    def test_type_payment_date_and_search_filters_compose(self):
        delivery, _ = self.punch(delivery=5000, customer="Customer 100%_special", created_at=200)
        self.execute_service("OrderService", "UPDATE orders SET status", ("PAYMENT PENDING", "", delivery))
        dine_in, total = self.punch(created_at=220)
        self.pay(dine_in, total)
        takeaway, _ = self.punch(created_at=230)
        self.db.execute("UPDATE orders SET type='TAKEAWAY' WHERE id=?", (takeaway,))
        self.execute_service("OrderService", "UPDATE orders SET status", ("CANCELLED", "Customer cancelled", takeaway))
        self.assertEqual(self.filtered_orders(order_type="DELIVERY", payment="pending", start=200, end=300, term="%_"), [delivery])
        self.assertEqual(self.filtered_orders(order_type="DINE-IN", payment="paid"), [dine_in])
        self.assertEqual(self.filtered_orders(order_type="TAKEAWAY", payment="cancelled"), [takeaway])
        self.assertEqual(self.filtered_orders(order_type="DELIVERY", payment="paid"), [])
        self.assertEqual(self.filtered_orders(term="' OR 1=1 --"), [])
        self.assertEqual(self.filtered_orders(term="03300000000"), [delivery])

    def test_day_boundaries_history_and_pagination_include_paid_legacy_orders(self):
        previous, total = self.punch(created_at=199)
        self.pay(previous, total)
        self.db.execute("UPDATE orders SET status='PAID' WHERE id=?", (previous,))
        start_order, total = self.punch(created_at=200)
        self.pay(start_order, total)
        last_today, _ = self.punch(created_at=299.999)
        next_day, _ = self.punch(created_at=300)
        self.assertEqual(self.filtered_orders(start=200, end=300), [last_today, start_order])
        self.assertEqual(self.filtered_orders(payment="paid", start=200, end=300), [start_order])
        self.assertEqual(self.filtered_orders(payment="paid"), [start_order, previous])
        self.assertEqual(self.filtered_orders(limit=2, offset=0), [next_day, last_today])
        self.assertEqual(self.filtered_orders(limit=2, offset=2), [start_order, previous])


if __name__ == "__main__":
    print(f"Checking {sum(map(len, SQL.values()))} Swift SQL statements against bundled SQLite schema and catalog.", flush=True)
    print("Scope: SQL persistence/integrity only; native Swift compilation and XCTest still require macOS.", flush=True)
    unittest.main(verbosity=2)
