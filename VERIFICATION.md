# Verification — cashier update, 8 October 2026

This project was modified from the owner's uploaded HungrySpot.zip. The owner reports that the baseline passed 74 XCTest cases on Intel macOS Monterey12.7.6 / Xcode14.2. That result does not establish a native pass for this changed revision.

## Executed on this Windows host

| Check | Result |
|---|---|
| SQLite persistence tests | 11 executed, 11 passed, 0 failed |
| SQLite commerce tests | 14 executed, 14 passed, 0 failed |
| Combined portable tests | **25 executed, 25 passed, 0 failed** |
| Extracted literal SQL | 67 statements prepared against actual schema; dynamic order filter combinations also exercised |
| Swift grammar | 35 files, 0 grammar errors; not type checking |
| Project structure | Passed; resources, plist, scheme and source references present |
| Monterey static gate | Passed; deployment12.0, tools5.7, one-job SwiftPM/manual app workflow and preserved compatibility guards |
| Shell syntax | Build and DMG script syntax checks passed |
| Original test methods | All74 retained, with requested workflow expectations updated; 32 added, **106 supplied** |
| Source preservation | Package, locking, printing, backup service, database backup implementation, pricing/reporting service, schema and seed are byte-identical to uploaded baseline |

See `verification-results.txt` for captured portable test output. The initial persistence run under the Windows default temporary directory failed due to sandbox permissions; the final run used a writable workspace temporary directory and all25 tests passed. The sandbox initially prevented Git Bash startup; the shell check and platform check were rerun outside that sandbox.

SQL fixtures execute real schema/seed and extracted service statements. They exercise filters, transactional audit rollback, payment/completion rollback, uniqueness, snapshots and standalone SQLite backup mechanics. They do not execute Swift authorization, phone validation, calculation or UI code; those behaviors have native XCTest coverage awaiting execution.

## Native build attempted, not completed

The requested `bash scripts/build-macos.sh` was invoked. Its actual result on this Windows host was:

```text
Build requires macOS.
Exit status: 1
```

It exited at its platform guard before Swift tests or compilation. Therefore native XCTest results are **0 executed; no pass/fail result available**, with106 supplied tests pending execution on the Mac. There is no newly generated application to distribute and no claim that this revision compiles or launches on Monterey yet.

On the owner's Intel Mac, run:

```sh
bash scripts/build-macos.sh
```

Only a successful run there confirms the tests and app build. Expected application output: `build/The Hungry Spot.app`.

Native UI interaction, Xcode14.2 type checking, printer hardware, resource relocation at runtime, signing/notarization and DMG creation remain unverified. The resource relocation fix is based on the actual Swift5.7 generated accessors in the uploaded build: they search for bundles directly inside Bundle.main.bundleURL. Packaging now supplies relative app-root links to the standard resource folders.

## Data compatibility

No schema or seed changes and no migration. Existing orders and legacy statuses remain readable. Existing restaurant data and the original ZIP were not modified. Build caches and the old executable are excluded from the new source ZIP so they cannot be mistaken for an updated build.
