"""Portable structural checks for the source delivery, not an Xcode build."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
pbx = (ROOT / 'HungrySpot.xcodeproj/project.pbxproj').read_text(encoding='utf8')
definitions = re.findall(r'^\s*([A-F0-9]{24}) = \{', pbx, re.MULTILINE)
assert len(definitions) == len(set(definitions)), 'Duplicate Xcode object IDs'
references = set(re.findall(r'\b[A-F0-9]{24}\b', pbx))
assert references == set(definitions), f'Unresolved object IDs: {references - set(definitions)}'
app_sources = sorted((ROOT / 'Sources/HungrySpot').rglob('*.swift'))
for path in app_sources:
    assert path.relative_to(ROOT).as_posix() in pbx, f'Missing app source: {path}'
assert 'XCLocalSwiftPackageReference' in pbx and 'productName = HungrySpotCore' in pbx
for relative in ['Configuration/Info.plist', 'Sources/HungrySpot/Resources/Branding.jpg',
                 'Sources/HungrySpotCore/Resources/001_schema.sql', 'Sources/HungrySpotCore/Resources/seed.sql']:
    assert (ROOT / relative).stat().st_size > 0, f'Missing resource: {relative}'
with (ROOT / 'Configuration/Info.plist').open('rb') as file:
    info = plistlib.load(file)
assert info['LSMinimumSystemVersion'] == '12.0' and info['CFBundlePackageType'] == 'APPL'
ET.parse(ROOT / 'HungrySpot.xcodeproj/xcshareddata/xcschemes/HungrySpot.xcscheme')
required_docs = ['README.md', 'ARCHITECTURE.md', 'DATABASE.md', 'BUSINESS_RULES.md', 'BUILD_MACOS.md', 'BACKUP_RESTORE.md', 'PRINTING.md', 'TESTING.md']
for doc in required_docs:
    assert (ROOT / doc).stat().st_size > 0
all_swift = list((ROOT / 'Sources').rglob('*.swift'))
for path in all_swift:
    source = path.read_text(encoding='utf8')
    assert 'fatalError(' not in source, f'Unexpected fatalError: {path}'
    assert 'TODO' not in source and 'FIXME' not in source, f'Unfinished source marker: {path}'
tests = sum(len(re.findall(r'\bfunc test\w+\(', p.read_text(encoding='utf8'))) for p in (ROOT / 'Tests').rglob('*.swift'))
print(f'Project structure passed: {len(app_sources)} app files, {len(all_swift)} production Swift files, {tests} supplied XCTest cases, resources/plist/scheme/object references checked.')
print('This does not type-check Swift or compile an app. Run bash scripts/build-macos.sh on macOS.')
