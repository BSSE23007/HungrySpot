"""Create a reproducible source checkpoint, excluding tools/builds/live databases."""
from pathlib import Path
import hashlib
import os
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT.parent / 'deliverables'
OUTPUT.mkdir(exist_ok=True)
archive = OUTPUT / 'HungrySpot-Monterey-cashier-update.zip'
excluded = {'.verification-tools', '.verification-temp', '.build', '.swiftpm', 'build', 'dist', '__pycache__', '.git', 'xcuserdata'}
paths = []
for directory, children, files in os.walk(ROOT):
    children[:] = sorted(c for c in children if c not in excluded)
    for name in sorted(files):
        path = Path(directory) / name
        if name.endswith(('.sqlite3', '.sqlite3-wal', '.sqlite3-shm', '.pyc', '.xcuserstate')) or name == '.DS_Store':
            continue
        paths.append(path)
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
    for path in sorted(paths):
        info = zipfile.ZipInfo('HungrySpot/' + path.relative_to(ROOT).as_posix(), date_time=(2026, 10, 8, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = (0o100755 if path.suffix == '.sh' else 0o100644) << 16
        bundle.writestr(info, path.read_bytes())
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(OUTPUT / 'HungrySpot-Monterey-cashier-update.sha256').write_text(digest + '  ' + archive.name + '\n', encoding='ascii')
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None
print(f'Source checkpoint: {archive.name}; {len(paths)} files; {archive.stat().st_size:,} bytes')
print(f'SHA-256: {digest}')
