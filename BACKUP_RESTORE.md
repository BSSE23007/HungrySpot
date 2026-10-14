# Backup and restore

In **Settings → Backups**, an administrator can create a timestamped backup in the local backup directory or choose another destination. A cashier cannot invoke either operation. Copy completed backup folders to another storage device according to the restaurant's retention policy.

Each backup folder contains:

```text
database.sqlite3     Consistent SQLite online-backup snapshot
images/              All imported images, including category/logo references
manifest.json        Format version, creation date and SHA-256 file hashes
```

Settings, users, password hashes, catalog, orders, payments, expenses and audit entries are stored in the database. Backups contain sensitive customer/business information; they are not encrypted or cryptographically signed. Checksums detect accidental damage, not a malicious party rewriting both the data and its manifest.

## Restore workflow

1. Choose the complete backup folder in Settings.
2. The app checks file hashes, file set, schema/columns, database integrity, foreign keys, an active administrator, settings, referenced images, and order/payment totals.
3. Read the backup summary and confirm replacement.
4. The app creates a safety backup of the current data and copies the selected backup into private staging.
5. The staged copy is validated again. The current database and images are moved into a recovery journal, then replaced together.
6. The app records the restore and invalidates all active sessions. Sign in with credentials from the restored backup.

If replacement fails before commit, the app restores the original directories. An interrupted restore is recovered on the next launch. After the durable commit marker, cleanup can be retried without rolling back the new data. The process lock prevents a second instance from modifying the same files while a restore is in progress.

Do not copy only the live `spot.sqlite3` file while the app is open: recent writes may be in its WAL. Use the app's backup function, which uses SQLite's backup API and produces a standalone snapshot. Backups cannot be stored inside the live images/database folders.

## Maintenance

Keep complete backup folders, including manifests and images. Never merge files from different backups. The app does not automatically delete old backups. Replaced/removed product images are retained in local storage, so older references remain recoverable; backups include those retained assets. Review disk space periodically. To test recovery, use a separate Mac user account or a copy of the data folder, never overwrite the only working store as a test.

If recovery reports an error, quit the app and preserve the whole Application Support folder, including `.restore-*` directories and the reported safety backup. Do not repeatedly remove or replace files manually.
