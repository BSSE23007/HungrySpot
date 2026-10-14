#!/usr/bin/env python3
"""Run the shipped schema/seed and catalog/auth SQL with standard-library SQLite.

Tests create only temporary or in-memory databases. They verify the real SQL,
constraints and backup mechanics, not Swift authorization, hashing or UI behavior.
The Swift XCTest suite and a macOS app build remain required native checks.
"""
from contextlib import contextmanager
from pathlib import Path
import json
import re
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Sources" / "HungrySpotCore"
SCHEMA = (CORE / "Resources" / "001_schema.sql").read_text(encoding="utf-8-sig")
SEED = (CORE / "Resources" / "seed.sql").read_text(encoding="utf-8-sig")


def service_sql(name):
    source = (CORE / "Services" / f"{name}.swift").read_text(encoding="utf-8-sig")
    return [json.loads('"' + match[1] + '"') for match in re.finditer(r'\bsql:\s*"((?:[^"\\]|\\.)*)"', source)]


SQL = {name: service_sql(name) for name in ("AuthenticationService", "CatalogService", "AuditService")}


def statement(name, prefix):
    matches = [sql for sql in SQL[name] if sql.startswith(prefix)]
    if len(matches) != 1:
        raise AssertionError(f"Expected one {name} SQL statement starting {prefix!r}, found {len(matches)}")
    return matches[0]


def script_in_transaction(db, script):
    # Unlike executescript(), this does not implicitly commit the caller's transaction.
    pending = ""
    for line in script.splitlines(keepends=True):
        pending += line
        if sqlite3.complete_statement(pending):
            db.execute(pending)
            pending = ""
    if pending.strip():
        raise AssertionError("Unterminated bundled SQL statement")


@contextmanager
def transaction(db):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise


def connection(path=":memory:"):
    db = sqlite3.connect(path, isolation_level=None)
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    return db


def first_run_sql(db):
    """Exercise the transaction/marker SQL sequence; does not execute Swift bootstrap."""
    with transaction(db):
        db.execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY,applied_at REAL NOT NULL)")
        version = db.execute("SELECT COALESCE(MAX(version),0) FROM schema_migrations").fetchone()[0]
        if version > 1:
            raise ValueError("Future schema")
        if version < 1:
            script_in_transaction(db, SCHEMA)
            db.execute("INSERT INTO schema_migrations(version,applied_at) VALUES(1,0)")
        if not db.execute("SELECT COUNT(*) FROM settings WHERE key='initial_seed_complete'").fetchone()[0]:
            script_in_transaction(db, SEED)
            db.execute("INSERT INTO settings(key,value) VALUES('initial_seed_complete','1')")


class PersistenceSQLTests(unittest.TestCase):
    def setUp(self):
        self.db = connection()
        first_run_sql(self.db)

    def tearDown(self):
        self.db.close()

    def scalar(self, sql, params=()):
        return self.db.execute(sql, params).fetchone()[0]

    def add_user(self, username="owner", role="admin"):
        return self.db.execute(statement("AuthenticationService", "INSERT INTO users(username,password_hash,password_salt,password_iterations,role,is_active,created_at) VALUES(?,?,?,?,?,?,?)"),
            (username, bytes(range(32)), bytes(reversed(range(32))), 600_000, role, 1, 0)).lastrowid

    def test_catalog_counts_references_and_no_default_credentials(self):
        for table, expected in [("categories", 17), ("products", 62), ("product_variants", 49), ("deals", 14), ("users", 0), ("orders", 0), ("payments", 0)]:
            self.assertEqual(self.scalar(f"SELECT COUNT(*) FROM {table}"), expected, table)
        self.assertEqual(self.scalar("PRAGMA integrity_check"), "ok")
        self.assertEqual(self.db.execute("PRAGMA foreign_key_check").fetchall(), [])
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM categories WHERE parent_id IS NULL"), 9)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM products p JOIN categories s ON s.id=p.subcategory_id WHERE s.parent_id != p.category_id"), 0)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM deal_item_choices c JOIN product_variants v ON v.id=c.variant_id WHERE c.product_id != v.product_id"), 0)

    def test_all_literal_catalog_auth_audit_queries_prepare_against_schema(self):
        count = 0
        for name, statements in SQL.items():
            for sql in statements:
                with self.subTest(service=name, sql=sql):
                    self.db.execute("EXPLAIN " + sql, [None] * sql.count("?")).fetchall()
                    count += 1
        self.assertGreater(count, 40)

    def test_availability_update_changes_only_its_flag_and_rolls_back_with_audit(self):
        user = self.add_user("fixture_cashier", role="cashier")
        self.db.row_factory = sqlite3.Row
        before = dict(self.db.execute("SELECT * FROM products WHERE name='Zinger Burger'").fetchone())
        update = statement("CatalogService", "UPDATE products SET is_available=? WHERE id=?")
        insert_audit = statement("AuditService", "INSERT INTO audit_logs")
        values = (user, "fixture_cashier", "Product availability changed", "Product", "Sold out", 100)
        with transaction(self.db):
            self.db.execute(update, (0, before["id"]))
            self.db.execute(insert_audit, values)
        after = dict(self.db.execute("SELECT * FROM products WHERE id=?", (before["id"],)).fetchone())
        expected = dict(before, is_available=0)
        self.assertEqual(after, expected)
        self.assertEqual(self.scalar("SELECT user_id FROM audit_logs WHERE action='Product availability changed'"), user)
        self.db.execute("CREATE TRIGGER fail_availability_audit BEFORE INSERT ON audit_logs BEGIN SELECT RAISE(ABORT,'failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            with transaction(self.db):
                self.db.execute(update, (1, before["id"]))
                self.db.execute(insert_audit, values)
        self.assertEqual(self.scalar("SELECT is_available FROM products WHERE id=?", (before["id"],)), 0)

    def test_seed_marker_preserves_price_changes_and_deleted_products(self):
        self.db.execute("UPDATE products SET base_price=43210,name='Owner edited burger' WHERE name='Anda Shami Burger'")
        self.db.execute("DELETE FROM products WHERE name='300 ml'")
        first_run_sql(self.db)
        first_run_sql(self.db)
        self.assertEqual(self.scalar("SELECT base_price FROM products WHERE name='Owner edited burger'"), 43_210)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM products"), 61)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM schema_migrations"), 1)
        self.assertEqual(self.scalar("SELECT value FROM settings WHERE key='initial_seed_complete'"), "1")

    def test_first_run_is_atomic_and_future_schema_is_not_modified(self):
        empty = connection()
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                with transaction(empty):
                    script_in_transaction(empty, SCHEMA)
                    script_in_transaction(empty, SEED)
                    script_in_transaction(empty, SEED)
            self.assertEqual(empty.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()[0], 0)
        finally:
            empty.close()
        self.db.execute("INSERT INTO schema_migrations VALUES(2,0)")
        with self.assertRaisesRegex(ValueError, "Future schema"):
            first_run_sql(self.db)
        self.assertEqual(self.scalar("SELECT MAX(version) FROM schema_migrations"), 2)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM products"), 62)

    def test_username_uniqueness_hash_blobs_and_role_constraints(self):
        user = self.add_user()
        row = self.db.execute(statement("AuthenticationService", "SELECT * FROM users WHERE username = ? COLLATE NOCASE"), ("OWNER",)).fetchone()
        self.assertEqual(row[0], user)
        self.assertEqual(len(row[2]), 32)
        with self.assertRaises(sqlite3.IntegrityError):
            self.add_user("OWNER")
        for sql in ["UPDATE users SET role='superuser'", "UPDATE users SET is_active=2", "UPDATE users SET password_iterations=10"]:
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)
        self.assertEqual(self.scalar("SELECT role FROM users WHERE id=?", (user,)), "admin")

    def test_product_variant_crud_money_and_safe_deletion_constraints(self):
        product = self.db.execute(statement("CatalogService", "INSERT INTO products(name,category_id"),
            ("Custom wrap", 4, None, "Test", "variant", 0, "products/wrap.jpg", 1, 1, 99)).lastrowid
        variant = self.db.execute(statement("CatalogService", "INSERT INTO product_variants(name,price"),
            ("Regular", 25_000, 0, 1, None, product)).lastrowid
        self.db.execute(statement("CatalogService", "UPDATE product_variants SET name=?,price"),
            ("Large", 30_000, 1, 0, None, variant))
        self.assertEqual(self.db.execute("SELECT name,price,is_available FROM product_variants WHERE id=?", (variant,)).fetchone(), ("Large", 30_000, 0))
        for sql in ["UPDATE products SET base_price=-1", "UPDATE product_variants SET price=-1", "UPDATE product_variants SET topping_price=-1", "DELETE FROM products WHERE name='Zinger Burger'", "DELETE FROM categories WHERE name='Burgers'", "DELETE FROM product_variants WHERE product_id=(SELECT id FROM products WHERE name='Fried Wings')"]:
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)
        self.db.execute(statement("CatalogService", "DELETE FROM products WHERE id=?"), (product,))
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM product_variants WHERE id=?", (variant,)), 0)

    def test_catalog_update_rolls_back_when_audit_cannot_be_written(self):
        user = self.add_user()
        product = self.scalar("SELECT id FROM products WHERE name='Chicken Paratha'")
        self.db.execute("CREATE TRIGGER reject_audit BEFORE INSERT ON audit_logs BEGIN SELECT RAISE(ABORT,'test failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            with transaction(self.db):
                self.db.execute(statement("CatalogService", "UPDATE products SET name=?"),
                    ("Wrong", 5, None, "Test", "normal", 98765, None, 1, 1, 0, product))
                self.db.execute(statement("AuditService", "INSERT INTO audit_logs"),
                    (user, "owner", "Product changed", str(product), "Test", 0))
        self.assertEqual(self.db.execute("SELECT name,base_price FROM products WHERE id=?", (product,)).fetchone(), ("Chicken Paratha", 25_000))
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM audit_logs"), 0)

    def test_settings_upsert_roundtrip_and_parameterized_literal_search(self):
        settings = {"restaurantName": "Hungry Spot 🍔", "quickDeliveryCharges": [0, 7500], "logoPath": "branding/logo.png"}
        upsert = statement("CatalogService", "INSERT INTO settings(key,value) VALUES('app_settings',?)")
        self.db.execute(upsert, (json.dumps(settings),))
        settings["restaurantName"] = "Owner edited name"
        self.db.execute(upsert, (json.dumps(settings),))
        self.assertEqual(json.loads(self.scalar("SELECT value FROM settings WHERE key='app_settings'")), settings)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM settings WHERE key='app_settings'"), 1)
        self.db.execute("INSERT INTO products(name,category_id,kind,base_price) VALUES('100%_Chicken',4,'normal',100)")
        pattern = "%" + "%_".replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        self.assertEqual(self.db.execute("SELECT name FROM products WHERE name LIKE ? ESCAPE '\\' COLLATE NOCASE", (pattern,)).fetchall(), [("100%_Chicken",)])

    def test_nested_savepoints_preserve_outer_changes(self):
        with transaction(self.db):
            self.db.execute("INSERT INTO settings VALUES('outer-before','1')")
            self.db.execute("SAVEPOINT nested_1")
            self.db.execute("INSERT INTO settings VALUES('inner','1')")
            self.db.execute("ROLLBACK TO SAVEPOINT nested_1")
            self.db.execute("RELEASE SAVEPOINT nested_1")
            self.db.execute("INSERT INTO settings VALUES('outer-after','1')")
        self.assertEqual(self.db.execute("SELECT key FROM settings WHERE key LIKE 'outer-%' ORDER BY key").fetchall(), [("outer-after",), ("outer-before",)])
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM settings WHERE key='inner'"), 0)

    def test_online_backup_includes_wal_commits_without_readonly_sidecars(self):
        with tempfile.TemporaryDirectory(prefix="HungrySpotPersistenceTests-") as folder:
            live_path, snapshot_path = Path(folder) / "live.sqlite3", Path(folder) / "snapshot.sqlite3"
            live, snapshot = connection(live_path), sqlite3.connect(snapshot_path, isolation_level=None)
            try:
                first_run_sql(live)
                live.execute("PRAGMA wal_autocheckpoint=0")
                live.execute("UPDATE products SET base_price=67890 WHERE name='Chicken Paratha'")
                self.assertTrue(Path(str(live_path) + "-wal").exists())
                live.backup(snapshot)
                self.assertEqual(snapshot.execute("PRAGMA journal_mode=DELETE").fetchone()[0], "delete")
                snapshot.close()
                readonly = sqlite3.connect(snapshot_path.as_uri() + "?mode=ro", uri=True)
                try:
                    self.assertEqual(readonly.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                    self.assertEqual(readonly.execute("PRAGMA foreign_key_check").fetchall(), [])
                    self.assertEqual(readonly.execute("SELECT base_price FROM products WHERE name='Chicken Paratha'").fetchone()[0], 67_890)
                    self.assertEqual(readonly.execute("PRAGMA journal_mode").fetchone()[0], "delete")
                    self.assertFalse(Path(str(snapshot_path) + "-wal").exists())
                    self.assertFalse(Path(str(snapshot_path) + "-shm").exists())
                finally:
                    readonly.close()
            finally:
                snapshot.close()
                live.close()


if __name__ == "__main__":
    print(f"SQLite {sqlite3.sqlite_version}; {sum(map(len, SQL.values()))} literal service statements checked. These are SQL checks, not Swift execution.", flush=True)
    unittest.main(verbosity=2)
