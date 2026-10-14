CREATE TABLE users (
 id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL COLLATE NOCASE UNIQUE,
 password_hash BLOB NOT NULL, password_salt BLOB NOT NULL, password_iterations INTEGER NOT NULL CHECK(password_iterations >= 100000),
 role TEXT NOT NULL CHECK(role IN ('admin','cashier')), is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)), created_at REAL NOT NULL
);
CREATE TABLE categories (
 id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL COLLATE NOCASE,
 parent_id INTEGER REFERENCES categories(id) ON DELETE RESTRICT, display_order INTEGER NOT NULL DEFAULT 0,
 is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)), icon TEXT NOT NULL DEFAULT 'fork.knife', image_path TEXT,
 CHECK(parent_id IS NULL OR parent_id != id)
);
CREATE TABLE products (
 id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL COLLATE NOCASE,
 category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
 subcategory_id INTEGER REFERENCES categories(id) ON DELETE RESTRICT, description TEXT NOT NULL DEFAULT '',
 kind TEXT NOT NULL CHECK(kind IN ('normal','variant','pizza','deal')), base_price INTEGER NOT NULL CHECK(base_price >= 0),
 image_path TEXT, is_available INTEGER NOT NULL DEFAULT 1 CHECK(is_available IN (0,1)),
 is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)), display_order INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE product_variants (
 id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
 name TEXT NOT NULL COLLATE NOCASE, price INTEGER NOT NULL CHECK(price >= 0), display_order INTEGER NOT NULL DEFAULT 0,
 is_available INTEGER NOT NULL DEFAULT 1 CHECK(is_available IN (0,1)), topping_price INTEGER CHECK(topping_price >= 0), UNIQUE(product_id,name)
);
CREATE TABLE deals (
 product_id INTEGER PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
 needs_review INTEGER NOT NULL DEFAULT 1 CHECK(needs_review IN (0,1)), review_note TEXT NOT NULL DEFAULT ''
);
CREATE TABLE deal_items (
 id INTEGER PRIMARY KEY AUTOINCREMENT, deal_id INTEGER NOT NULL REFERENCES deals(product_id) ON DELETE CASCADE,
 label TEXT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity BETWEEN 1 AND 100),
 requires_selection INTEGER NOT NULL CHECK(requires_selection IN (0,1)), display_order INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE deal_item_choices (
 id INTEGER PRIMARY KEY AUTOINCREMENT, deal_item_id INTEGER NOT NULL REFERENCES deal_items(id) ON DELETE CASCADE,
 product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
 variant_id INTEGER REFERENCES product_variants(id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX unique_deal_choice ON deal_item_choices(deal_item_id,product_id,COALESCE(variant_id,0));
CREATE TABLE orders (
 id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE, request_payload TEXT NOT NULL, order_number TEXT NOT NULL UNIQUE,
 type TEXT NOT NULL CHECK(type IN ('DINE-IN','TAKEAWAY','DELIVERY')),
 status TEXT NOT NULL CHECK(status IN ('PUNCHED','PREPARING','READY','PAYMENT PENDING','PAID','COMPLETED','CANCELLED')),
 created_at REAL NOT NULL, cashier_id INTEGER NOT NULL REFERENCES users(id), cashier_name TEXT NOT NULL,
 customer_name TEXT NOT NULL DEFAULT '', customer_phone TEXT NOT NULL DEFAULT '', customer_address TEXT NOT NULL DEFAULT '',
 notes TEXT NOT NULL DEFAULT '', cancellation_reason TEXT NOT NULL DEFAULT '',
 subtotal INTEGER NOT NULL CHECK(subtotal >= 0), delivery_charge INTEGER NOT NULL CHECK(delivery_charge >= 0),
 discount INTEGER NOT NULL CHECK(discount >= 0 AND discount <= subtotal), total INTEGER NOT NULL CHECK(total = subtotal + delivery_charge - discount),
 CHECK(type = 'DELIVERY' OR delivery_charge = 0)
);
CREATE TABLE order_items (
 id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
 product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
 product_name TEXT NOT NULL, category_name TEXT NOT NULL, variant_name TEXT,
 unit_price INTEGER NOT NULL CHECK(unit_price >= 0), extra_price INTEGER NOT NULL CHECK(extra_price >= 0),
 quantity INTEGER NOT NULL CHECK(quantity > 0), notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE order_item_options (
 id INTEGER PRIMARY KEY AUTOINCREMENT, order_item_id INTEGER NOT NULL REFERENCES order_items(id) ON DELETE RESTRICT,
 name TEXT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity > 0), unit_price INTEGER NOT NULL CHECK(unit_price >= 0),
 product_id INTEGER REFERENCES products(id) ON DELETE RESTRICT, variant_id INTEGER REFERENCES product_variants(id) ON DELETE RESTRICT
);
CREATE TABLE payments (
 id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL UNIQUE REFERENCES orders(id) ON DELETE RESTRICT,
 amount INTEGER NOT NULL CHECK(amount >= 0), method TEXT NOT NULL CHECK(method IN ('CASH','CARD','OTHER')),
 cashier_id INTEGER NOT NULL REFERENCES users(id), created_at REAL NOT NULL
);
CREATE TABLE expenses (
 id INTEGER PRIMARY KEY AUTOINCREMENT, expense_date REAL NOT NULL, amount INTEGER NOT NULL CHECK(amount > 0),
 description TEXT NOT NULL, user_id INTEGER NOT NULL REFERENCES users(id)
);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE audit_logs (
 id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER REFERENCES users(id) ON DELETE RESTRICT,
 username TEXT NOT NULL DEFAULT 'System', action TEXT NOT NULL, entity TEXT NOT NULL, details TEXT NOT NULL, created_at REAL NOT NULL
);
CREATE INDEX idx_product_name ON products(name COLLATE NOCASE);
CREATE INDEX idx_product_category ON products(category_id,subcategory_id,is_active,display_order);
CREATE INDEX idx_category_parent ON categories(parent_id,display_order);
CREATE INDEX idx_variant_product ON product_variants(product_id,display_order);
CREATE INDEX idx_deal_product ON deal_item_choices(product_id,variant_id);
CREATE INDEX idx_order_date ON orders(created_at);
CREATE INDEX idx_order_status_date ON orders(status,created_at);
CREATE INDEX idx_order_item_order ON order_items(order_id);
CREATE INDEX idx_order_item_product ON order_items(product_id);
CREATE INDEX idx_option_item ON order_item_options(order_item_id);
CREATE INDEX idx_option_product ON order_item_options(product_id,variant_id);
CREATE INDEX idx_payment_date ON payments(created_at);
CREATE INDEX idx_expense_date ON expenses(expense_date);
CREATE INDEX idx_audit_date ON audit_logs(created_at);
