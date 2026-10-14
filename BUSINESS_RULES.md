# Business rules

- All catalog amounts are copied from the supplied artwork and brief, stored as integer paisa (Rs 1 = 100 paisa).
- The administrator owns the catalog after one-time initialization. Reseeding never overwrites edits.
- Inactive products/categories are excluded from POS. Sold-out products remain visible but cannot be ordered; unavailable variants and bundle components are rejected by the pricing service.
- Orders hold historical product, variant, category, option and price snapshots. Safe deletion rejects catalog references needed by orders or bundles; archive instead.
- Extra Topping is generic. Small/Medium/Large default to Rs 50/100/150, with quantity supported. An arbitrary newly added pizza size needs an explicit topping price. Dip Sauce is Rs 50 initially. Admin can maintain the options.
- Deal base prices are fixed. Selected pizza toppings/dips add to that base. Every required pizza unit is configured separately, and component availability is checked at punch time.
- The artwork does not define which flavours are included in ordinary pizza deals. Those deals start marked “Needs review” until the admin confirms their permitted choices. Birthday deals explicitly permit special large pizzas; Crown Crust and Lasagnia are not silently excluded from that category.
- Deal 10's Family Pan Pizza lacks a standalone price, size definition and flavour policy. It remains disabled for sale until configured by the admin. No invented standalone pizza is seeded.
- Cashier discounts default to disabled. The admin may enable them; discounts cannot exceed food subtotal. Delivery charges are nonnegative and only apply to delivery. Delivery requires customer name, phone and address. No tax rule is assumed.
- Normal progression is Punched → Payment Pending → Completed. Payment, completion and both audit entries commit in one transaction. NEW represents an unsaved cart. Preparing/Ready remain readable for historical data and can move directly to Payment Pending. Legacy Paid orders can still be completed. Cancel is allowed before payment with a reason; paid/completed orders cannot be cancelled. Refunds remain outside scope.
- A sale is recognized once a payment transaction commits; it continues to count after the order is Completed. Unpaid/cancelled orders never enter collected sales.
- Sales After Recorded Expenses is collections less recorded expenses; it is not net profit. Reporting ranges are local calendar boundaries and half-open date intervals.
- Printing happens after save and cannot roll back an order or payment. Both kitchen tickets and customer receipts can be retried.
- Restore requires an authenticated admin, validation, a safety backup and a concrete confirmation inside the app. A restore signs the current user out.
- Initial address: Shaheen Villas Phase #2, E Block Bajwa Market, near Family Park, Sheikhupura. Phones: 03304573301 / 03221168559. Hours in the artwork: 1 PM–1 AM. All are editable.

- Cashiers can change only product availability through the narrow authenticated service. Name, price, category, descriptions, images, variants, archive/delete and deal configuration remain admin-only. Availability changes are audited atomically and immediately refresh POS pricing.
- New delivery phones accept 03XXXXXXXXX, +923XXXXXXXXX or 923XXXXXXXXX with spaces/hyphens. Stored phone numbers use 03XXXXXXXXX; existing historical phone snapshots are unchanged. Invalid numbers cannot be punched.
- Cash received and change use integer paisa. A shortage blocks payment in both UI and service. The payment row always equals the order total, while tender/change appear only in the audit details. A missing optional cashTendered argument means exact cash for existing service callers. Retries with the same payment method/amount return the original payment without another audit or collection.
- Orders initially list Today using local-calendar creation timestamps, inclusive start/exclusive next-day boundary. All Dates enables history. Type, payment, date and literal-text search compose before pagination. Paid means a payment-backed PAID or COMPLETED order. An explicitly selected order detail can remain visible after payment; changing filters clears it.
- Gross Sales and After Expenses select the emphasized report figure. Daily bars always show collections before expenses; period expenses are not subtracted from each bar.
