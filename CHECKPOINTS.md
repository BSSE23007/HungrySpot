# Implementation checkpoints

These checkpoints describe saved source work. Native compile/test status for every phase is **pending macOS verification**; a grammar check is not a substitute. Work was interrupted by account usage limits and resumed from the existing files without resetting the catalog design or application code.

| Brief phases | Saved implementation |
| --- | --- |
| 1 | Architecture, ERD, domain model, navigation, screen list, explicit business uncertainties |
| 2–3 | Native app/Swift package project, SQLite connection/migrations, setup/login, PBKDF2 and service-enforced roles |
| 4–5 | Catalog/category/variant/deal management, optimized image storage and one-time structured menu seed |
| 6–10 | Native cashier grid/search/cart, pizza and bundle configuration, central pricing, transactional orders/state machine, delivery |
| 11–12 | Full payment transaction, paid status, historical receipts, isolated native printing and kitchen tickets |
| 13–15 | Dashboard/date ranges/reports, expenses, settings/user management/audit, checksummed backup/restore and recovery |
| 16 | 71 supplied XCTest cases, 21 executed SQLite integration checks, seed/grammar/project/script checks |
| 17 | Charcoal/burgundy/orange/gold native UI, source branding, dialogs, filters, keyboard commands and input validation; native visual review pending |
| 18 | Xcode `.app` project plus unsigned/signed/notarized DMG scripts; actual build and distribution pending Mac verification |

The final source archive and its SHA-256 checksum form the delivery checkpoint. `VERIFICATION.md` is the authority for what has actually been tested. The only intended operational holds are the unconfirmed pizza bundle policies described in `BUSINESS_RULES.md`; other screens are implemented rather than placeholder views.

## 7 October 2026 — Monterey hardware revision

The owner supplied an Intel Core i5 / 8 GB Mac running macOS 12.7.6. Deployment was lowered to macOS 12.0, Swift tools to 5.7, and the release script now explicitly builds Intel with two compilation jobs. Newer navigation, chart, field, drop and change-observer APIs were replaced. Window/sheet sizing was adjusted for a smaller laptop display. Three additional aggregation tests bring the supplied suite to 74 XCTest cases; native execution remains pending. `HungrySpot-Monterey-source.zip` is the current hardware-specific source checkpoint; the original source archive is retained.

## Owner upload and cashier update — 8 October 2026

The earlier checkpoint descriptions above are historical. The owner supplied a working Monterey/Xcode14.2 project and reported74 native tests passing after local compatibility fixes. This revision modifies that upload, preserves those fixes, uses its one-job SwiftPM/manual app build, and implements the cashier/report/order changes. Current output is build/The Hungry Spot.app; current source archive is HungrySpot-Monterey-cashier-update.zip. See VERIFICATION.md for this revision’s actual results.
