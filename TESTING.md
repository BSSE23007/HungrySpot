# Testing

## Native test and build

On the Intel Mac with Xcode 14.2 selected:

```sh
bash scripts/build-macos.sh
```

This runs `swift test --jobs 1`, then the release build and manual app packaging. For tests alone: `swift test --jobs 1`. The suite now contains 106 XCTest methods, preserving the original 74 with workflow assertions updated to the requested behavior and adding 32 cases. Tests use in-memory or temporary stores.

Coverage includes authentication, catalog permissions, variants/pricing/deals, snapshots, transaction rollback, backup/restore, printing text and process locking. Added tests cover mobile formats/service validation, exact/over/under cash, automatic completion and audit rollback, legacy statuses, combined order filters and pagination, availability-only cashier permissions, gross/after-expense display, cashier routes and local-day/DST boundaries.

## Portable checks

```sh
python3 scripts/verify_persistence_sql.py
python3 scripts/verify_commerce_sql.py
python3 scripts/verify_project.py
python3 scripts/verify_monterey_compatibility.py
```

The SQL scripts run actual extracted service SQL against the shipped schema and seed. They do not execute Swift authorization, pricing or UI. They total 25 tests. The optional Swift grammar checker uses tree-sitter and tree-sitter-swift; grammar acceptance is not type checking. Tests create no restaurant data and do not reseed the live store.

## Mac acceptance

- Build and open `build/The Hungry Spot.app`. Verify at the laptop's screen size and at the 1060×620 minimum window. Collapse/expand the sidebar; confirm selected icons, tooltips and logout work.
- Sign in as a cashier: only POS, Orders and Menu should appear. Change availability and verify immediate POS updates. No full editor, price, archive/delete or deal/category controls should be available.
- Read deal name, full description, price, availability and choice requirements before selecting. Configure each pizza and its extras. Verify all quantity controls at their lower/upper limits.
- Make dine-in, takeaway and delivery orders. Try valid local/international numbers and invalid letters/length/prefix/plus placement. Confirm normalized local phone appears on the saved delivery.
- Punch, print kitchen ticket, mark Payment Pending, then pay. Cash Rs 1,250 due / Rs 2,000 received must show Rs 750 change and record Rs 1,250. Short cash must block confirmation. Successful payment must display Completed with no further completion step.
- Retry payment and cancel printing. Confirm one payment, one completion and saved order. Verify unpaid cancellation requires a reason and paid/completed cancellation is forbidden.
- Combine Today/All Dates, type, payment and search filters; page through history. Test midnight behavior and Paid including completed orders. Legacy Preparing/Ready can go directly to Pending; historical Paid remains readable.
- Compare Gross Sales and After Expenses for the selected report range, including expenses above sales. Daily collections must remain unchanged. Confirm payment dates, discounts, delivery and historical names/prices remain accurate.
- Print long kitchen tickets and receipts with the actual 58/80 mm printer, including a cancelled print and retry.
- Back up, restore a test store and verify image/database integrity, required sign-out and process locking. Use an actual restaurant backup before replacing its app.
- Move the app away from its original build folder, temporarily rename `.build`, and launch the moved app to check resource independence; restore the build folder afterward.

Native XCTest, macOS UI, physical printing and signing were not executed on the Windows editing host. The previous 74-test pass was reported by the owner for the uploaded baseline, not for this changed revision.
