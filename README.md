# The Hungry Spot

A native macOS restaurant POS and management application for **The Hungry Spot — Eat • Enjoy • Repeat**. Menu records, prices, variants, deals, accounts, orders and reports live in local SQLite. No server, cloud database, account subscription or internet connection is required for normal operation.

**Delivery status:** source implementation supplied with an Xcode project, Swift tests and release scripts. Development and cross-platform checks were performed on Windows. The macOS build, Swift test execution, visual acceptance, physical printers, signing and notarization have **not** been verified here. Read `VERIFICATION.md` before deploying in a restaurant.

## Open and run on a Mac

1. The revised target is macOS 12 Monterey or newer. On your Intel Mac running 12.7.6, install **Xcode 14.2** and its Command Line Tools. See `MONTEREY.md` for the revised compatibility notes.
2. Run `bash scripts/build-macos.sh` in the extracted project folder. This preserves the working SwiftPM build path for Xcode 14.2; see `BUILD_MACOS.md`.
3. First launch asks you to create an administrator username and password. There are no preset accounts or passwords.
4. Review **Settings**, create a cashier account, and review highlighted pizza deals in **Deals** before selling them.
5. Update products, prices, sizes and photos in **Menu**. Those edits immediately flow to the POS after saving.

From Terminal at the project root:

```sh
bash scripts/build-macos.sh
```

The script tests the package, builds the native app, and stops on any error. The app is output to `build/The Hungry Spot.app`.

## Included workflows

- Secure first-run setup and separate administrator/cashier roles, enforced in services; cashier Menu allows only availability changes.
- Collapsible sidebar, visible deal details, consistent quantity controls and Pakistan delivery phone validation.
- Orders default to Today with combined type/payment/date/search filters and paginated history.
- Editable categories/sections, products, arbitrary variants, product photos and availability.
- Searchable cashier grid, configurable pizzas and per-pizza choices in fixed-price bundles.
- Dine-in, takeaway and delivery; customer fields, adjustable delivery fees, authorized discounts.
- Transactional punching and snapshots, direct Payment Pending, cash received/change and automatic completion.
- Receipt and kitchen ticket printing through macOS print dialogs, with retry from Orders.
- Gross/after-expense sales display, date ranges, product/category performance, recorded expenses and audit log.
- Editable restaurant identity, pricing options, printer preferences and cashier accounts.
- Timestamped backups including images; checksum/schema validation, safety backup and restore recovery.

## Restaurant menu

The initial database contains **62 products including 14 deals, 49 variants, 9 main categories and 8 sections**, transcribed from the supplied menu. The menu is seeded only once. The source artwork is used for branding; the POS never substitutes a menu photograph for catalog data.

The ordinary pizza deal flavour policy and the meaning of “Family Pan Pizza” were not specified. These deals are flagged **Needs review** and cannot be sold until an administrator supplies eligible choices and confirms the bundle. Cashier discounts default to disabled. See `BUSINESS_RULES.md` for the explicit policies and uncertainties.

## Technology and structure

Swift tools 5.7 with Swift 5 language mode; SwiftUI; AppKit printing; lightweight SwiftUI sales bars; SQLite through prepared statements; CommonCrypto PBKDF2; CryptoKit backup hashes; ImageIO image import. The project has no third-party runtime dependencies. The release script builds for the host architecture (Intel `x86_64` on your laptop) and uses one compilation job for the 8 GB laptop.

```text
HungrySpot.xcodeproj/          Native app project and shared scheme
Package.swift                 Core, executable and test targets
Sources/HungrySpot/            Native UI and platform services
  Views/                      Cashier and administrator screens
  Infrastructure/             Printing, images, backup/restore, local paths
  Resources/Branding.jpg      Supplied restaurant branding
Sources/HungrySpotCore/
  Domain/                     Shared models and integer-paisa money
  Persistence/                Serialized SQLite connection and migrations
  Security/                   Password hashing
  Services/                   Authorized catalog, pricing, orders and reports
  Resources/                  Versioned schema and one-time seed
Tests/                        Service and platform infrastructure tests
scripts/                      Verification, project generation, app/DMG packaging
Configuration/Info.plist      Native application metadata
```

## Local data

```text
~/Library/Application Support/TheHungrySpot/
  database/spot.sqlite3
  images/products/
  images/categories/
  backups/TheHungrySpot-<timestamp>-<suffix>/
```

This application protects access through its login and role checks; it does not encrypt the SQLite file. Mac account permissions and FileVault protect local files at rest. Backups contain restaurant and customer records and should be stored appropriately. Only one process may open the app's data folder at a time.

## Documentation

- `ARCHITECTURE.md` — layers, ERD, models, navigation and screen design.
- `DATABASE.md` — normalized schema, relationships, snapshots, indexes and seeding.
- `BUSINESS_RULES.md` — pricing, bundles, permissions and unresolved restaurant policies.
- `BUILD_MACOS.md` — Xcode, command-line build, native app and DMG preparation.
- `BACKUP_RESTORE.md` — backup contents, validation, recovery and maintenance.
- `PRINTING.md` — thermal layouts, native printer selection and retry behavior.
- `TESTING.md` — automated coverage and native acceptance checklist.
- `VERIFICATION.md` — checks actually performed and outstanding release gates.
- `MONTEREY.md` — compatibility changes for the supplied Intel Mac running 12.7.6.

To produce a local test DMG: `bash scripts/package-dmg.sh --unsigned`. For a signed and notarized distribution, follow `BUILD_MACOS.md`; a Developer ID signing identity and notarization profile are required.

See `UPDATE_NOTES.md` for this update and its file list. No schema migration or seed changes were made. The uploaded baseline passed 74 native tests according to the owner; this updated source includes 106 tests whose Mac execution remains pending.
