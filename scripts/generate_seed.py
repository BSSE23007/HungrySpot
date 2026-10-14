#!/usr/bin/env python3
"""Regenerate the reviewed first-run catalog and verify it with real SQLite.

No third-party packages. Run from any folder with Python 3.10+.
This script writes seed.sql only. It never opens or changes a user's live database.
"""
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "HungrySpotCore" / "Resources"
statements = ["-- One-time initial Hungry Spot catalog, transcribed from supplied menu and brief."]
products = {}
variants = {}
next_product = 1
next_variant = 1
next_slot = 1

def literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    return str(int(value))

def insert(table, **values):
    statements.append(f"INSERT INTO {table}({','.join(values)}) VALUES({','.join(map(literal, values.values()))});")

categories = [
    (1, "Burgers", None, "flame.fill"), (2, "Pizza", None, "circle.grid.cross.fill"),
    (3, "Deals", None, "gift.fill"), (4, "Wraps", None, "takeoutbag.and.cup.and.straw.fill"),
    (5, "Paratha", None, "circle.fill"), (6, "Shawarma", None, "fork.knife"),
    (7, "Fries", None, "takeoutbag.and.cup.and.straw.fill"), (8, "Appetizers", None, "flame.fill"),
    (9, "Drinks", None, "cup.and.saucer.fill"), (10, "Classic Burgers", 1, "flame.fill"),
    (11, "Special Burgers", 1, "star.fill"), (12, "Regular Flavours", 2, "circle.fill"),
    (13, "Special Flavours", 2, "star.fill"), (14, "Regular Deals", 3, "gift.fill"),
    (15, "Pizza Combo Deals", 3, "gift.fill"), (16, "Family Deals", 3, "person.3.fill"),
    (17, "Birthday Deals", 3, "birthday.cake.fill")
]
for order, (ident, name, parent, icon) in enumerate(categories):
    insert("categories", id=ident, name=name, parent_id=parent, display_order=order, icon=icon)

def product(name, category, price=0, *, section=None, sizes=None, pizza=False, deal=False, description=""):
    global next_product, next_variant
    ident = next_product
    next_product += 1
    products[name] = ident
    kind = "deal" if deal else "pizza" if pizza else "variant" if sizes else "normal"
    insert("products", id=ident, name=name, category_id=category, subcategory_id=section,
           description=description, kind=kind, base_price=price*100, display_order=ident)
    for order, (size, amount) in enumerate(sizes or []):
        variant = next_variant
        next_variant += 1
        variants[(name, size)] = variant
        topping = {"Small": 50, "Medium": 100, "Large": 150}.get(size) if pizza else None
        insert("product_variants", id=variant, product_id=ident, name=size, price=amount*100,
               display_order=order, topping_price=topping*100 if topping is not None else None)
    return ident

for name, price in [("Anda Shami Burger",150),("Double Anda Burger",200),("Zinger Burger",350),("Petty Burger",250),("Chapli Burger",260)]:
    product(name,1,price,section=10)
for name, price in [("Grill Burger",350),("Pizza Burger",600),("Double Crispy Burger",400),("Zinger Tower Burger",450)]:
    product(name,1,price,section=11)
for name, price in [("Zinger Tortilla Wrap",430),("Grill Wrap",450),("Hungry Special Wrap",550)]:
    product(name,4,price)
for name, price in [("Chicken Paratha",250),("Zinger Paratha",300),("Grill Paratha",350),("Chicken Cheese Paratha",400)]:
    product(name,5,price)
product("Chicken Shawarma",6,sizes=[("Small",160),("Large",200)])
product("Zinger Shawarma",6,sizes=[("Small",250),("Large",300)])
for name, price in [("Platter Shawarma",550),("Hungry Special Platter",850),("Chicken Donner",450)]:
    product(name,6,price)
product("Regular Fries",7,sizes=[("Small",150),("Large",250)])
product("Pizza Fries",7,sizes=[("Small",550),("Large",950)])
product("Loaded Fries",7,400)
product("Cheese Fries",7,350)
product("Fried Wings",8,sizes=[("5 PCS",250),("10 PCS",450)])
product("Oven Baked Wings",8,sizes=[("5 PCS",350),("10 PCS",550)])
product("Nuggets",8,sizes=[("5 PCS",250),("10 PCS",450)])
product("Zinger Shots",8,sizes=[("5 PCS",250)])
for name in ["Chicken Tikka","Pepperoni Pizza","Chicken Fajita","Vegetable Lover","Cheese Lover"]:
    product(name,2,section=12,pizza=True,sizes=[("Small",500),("Medium",900),("Large",1250)])
special = ["Peri Peri Pizza","Malai Boti Pizza","Chicken Supreme","Kababish Pizza","Hungry Special Pizza","Crown Crust","Lasagnia Pizza"]
for name in special[:3]:
    product(name,2,section=13,pizza=True,sizes=[("Small",600),("Medium",1000),("Large",1350)])
for name in special[3:5]:
    product(name,2,section=13,pizza=True,sizes=[("Small",650),("Medium",1050),("Large",1400)])
product("Crown Crust",2,section=13,pizza=True,sizes=[("Medium",1100),("Large",1450)])
product("Lasagnia Pizza",2,section=13,pizza=True,sizes=[("Medium",1200),("Large",1550)])
for name, price in [("300 ml",80),("500 ml",120),("1 Ltr",160),("1.5 Ltr",220),("Can",130),("Small Water",60),("Large Water",120)]:
    product(name,9,price)

def fixed(name, quantity=1, size=None):
    return (f"{size} {name}".strip() if size else name,quantity,False,[(name,size)])
def pizza(size, quantity=1, special_only=False):
    choices = [(name,size) for name in special] if special_only else []
    return (f"{'Special ' if special_only else ''}{size} Pizza",quantity,True,choices)
ordinary_note = "The menu does not specify eligible pizza flavours. Choose eligible flavour/size pairs for each pizza component, then clear Needs review."
family_note = "Family Pan Pizza has no defined standalone price, size or flavour policy. Create/configure the intended product and its eligible variants, then clear Needs review."
deals = [
    (750,14,"2 Zinger Burgers + 0.5 L Drink",[fixed("Zinger Burger",2),fixed("500 ml")]),
    (850,14,"1 Small Pizza + 5 PCS Fried Wings + 0.5 L Drink",[pizza("Small"),fixed("Fried Wings",size="5 PCS"),fixed("500 ml")]),
    (1099,14,"3 Zinger Burgers + 1 L Drink",[fixed("Zinger Burger",3),fixed("1 Ltr")]),
    (1499,14,"1 Medium Pizza + 10 PCS Fried Wings + 1 L Drink",[pizza("Medium"),fixed("Fried Wings",size="10 PCS"),fixed("1 Ltr")]),
    (1799,14,"5 Zinger Burgers + 1.5 L Drink",[fixed("Zinger Burger",5),fixed("1.5 Ltr")]),
    (1050,15,"2 Small Pizzas + 0.5 L Drink",[pizza("Small",2),fixed("500 ml")]),
    (1850,15,"2 Medium Pizzas + 1 L Drink",[pizza("Medium",2),fixed("1 Ltr")]),
    (2550,15,"2 Large Pizzas + 1.5 L Drink",[pizza("Large",2),fixed("1.5 Ltr")]),
    (1599,16,"1 Medium Pizza + 2 Zinger Burgers + 1 L Drink",[pizza("Medium"),fixed("Zinger Burger",2),fixed("1 Ltr")]),
    (2499,16,"1 Family Pan Pizza + Loaded Fries + 10 PCS Oven Baked Wings + 1.5 L Drink",[("Family Pan Pizza",1,True,[]),fixed("Loaded Fries"),fixed("Oven Baked Wings",size="10 PCS"),fixed("1.5 Ltr")]),
    (2850,16,"1 Large Pizza + 4 Zinger Burgers",[pizza("Large"),fixed("Zinger Burger",4)]),
    (2999,16,"2 Large Pizzas + 10 PCS Fried Wings + 1.5 L Drink",[pizza("Large",2),fixed("Fried Wings",size="10 PCS"),fixed("1.5 Ltr")]),
    (3499,17,"2 Special Large Pizzas + 2 Cheese Fries + 2 x 1 L Drinks",[pizza("Large",2,True),fixed("Cheese Fries",2),fixed("1 Ltr",2)]),
    (4999,17,"3 Special Large Pizzas + 2 Loaded Fries + 2 x 1.5 L Drinks",[pizza("Large",3,True),fixed("Loaded Fries",2),fixed("1.5 Ltr",2)])
]
for number, (price, section, description, slots) in enumerate(deals,1):
    ident = product(f"Deal {number}",3,price,section=section,deal=True,description=description)
    review = any(not choices for _,_,_,choices in slots)
    insert("deals",product_id=ident,needs_review=review,review_note=(family_note if number==10 else ordinary_note) if review else "")
    for order, (label, quantity, selection, choices) in enumerate(slots):
        slot = next_slot
        next_slot += 1
        insert("deal_items",id=slot,deal_id=ident,label=label,quantity=quantity,requires_selection=selection,display_order=order)
        for name, size in choices:
            insert("deal_item_choices",deal_item_id=slot,product_id=products[name],variant_id=variants[(name,size)] if size else None)

sql = "\n".join(statements)+"\n"
RESOURCES.mkdir(parents=True,exist_ok=True)
(RESOURCES/"seed.sql").write_text(sql,encoding="utf-8")

def verify():
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript((RESOURCES/"001_schema.sql").read_text(encoding="utf-8"))
    db.executescript(sql)
    assert db.execute("PRAGMA integrity_check").fetchone()==("ok",)
    assert db.execute("PRAGMA foreign_key_check").fetchall()==[]
    assert db.execute("SELECT count(*) FROM products").fetchone()[0]==62
    assert db.execute("SELECT count(*) FROM categories").fetchone()[0]==17
    assert db.execute("SELECT count(*) FROM product_variants").fetchone()[0]==49
    assert db.execute("SELECT count(*) FROM users").fetchone()[0]==0
    assert db.execute("SELECT count(*) FROM deals").fetchone()[0]==14
    assert db.execute("SELECT name,base_price FROM products WHERE name IN ('Zinger Burger','Chapli Burger','Hungry Special Wrap') ORDER BY name").fetchall()==[("Chapli Burger",26000),("Hungry Special Wrap",55000),("Zinger Burger",35000)]
    assert db.execute("SELECT p.name,v.name,v.price FROM products p JOIN product_variants v ON v.product_id=p.id WHERE p.name IN ('Crown Crust','Lasagnia Pizza') ORDER BY p.name,v.display_order").fetchall()==[("Crown Crust","Medium",110000),("Crown Crust","Large",145000),("Lasagnia Pizza","Medium",120000),("Lasagnia Pizza","Large",155000)]
    assert db.execute("SELECT count(*) FROM product_variants v JOIN products p ON p.id=v.product_id WHERE p.kind='pizza' AND (v.topping_price IS NULL OR v.topping_price != CASE v.name WHEN 'Small' THEN 5000 WHEN 'Medium' THEN 10000 WHEN 'Large' THEN 15000 END)").fetchone()[0]==0
    review_numbers = [int(row[0].split()[1]) for row in db.execute("SELECT p.name FROM deals d JOIN products p ON p.id=d.product_id WHERE d.needs_review=1")]
    assert sorted(review_numbers)==[2,4,6,7,8,9,10,11,12]
    for number in (13,14):
        choices = db.execute("SELECT p.name,v.name FROM deal_item_choices c JOIN deal_items i ON i.id=c.deal_item_id JOIN products d ON d.id=i.deal_id JOIN products p ON p.id=c.product_id JOIN product_variants v ON v.id=c.variant_id WHERE d.name=?",(f"Deal {number}",)).fetchall()
        assert len(choices)==7 and set(n for n,_ in choices)==set(special) and all(size=="Large" for _,size in choices)
    assert db.execute("SELECT count(*) FROM products WHERE name LIKE '%Family Pan%'").fetchone()[0]==0
    for number, expected in enumerate([750,850,1099,1499,1799,1050,1850,2550,1599,2499,2850,2999,3499,4999],1):
        assert db.execute("SELECT base_price FROM products WHERE name=?",(f"Deal {number}",)).fetchone()[0]==expected*100
    # SQL constraints protect catalog references, money and order/payment uniqueness.
    def must_fail(statement, parameters=()):
        try:
            db.execute(statement,parameters)
        except sqlite3.IntegrityError:
            return
        raise AssertionError(f"Constraint did not reject: {statement}")
    must_fail("UPDATE products SET base_price=-1 WHERE name='Zinger Burger'")
    must_fail("DELETE FROM products WHERE name='Zinger Burger'")
    must_fail("DELETE FROM categories WHERE name='Burgers'")
    must_fail("UPDATE deal_items SET quantity=0")
    assert db.execute("PRAGMA foreign_key_check").fetchall()==[]
    print("PASS: 17 categories, 62 products, 49 variants, 14 deals; exact prices, pizza topping prices, review flags, birthday eligibility, foreign keys and money/deletion constraints.")

if __name__ == "__main__":
    verify()
