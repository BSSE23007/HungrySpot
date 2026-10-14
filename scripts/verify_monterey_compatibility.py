"""Catch known Monterey regressions; an SDK availability/compiler check is still required."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
package = (ROOT / 'Package.swift').read_text(encoding='utf8')
assert package.startswith('// swift-tools-version: 5.7')
assert 'platforms: [.macOS(.v12)]' in package
with (ROOT / 'Configuration/Info.plist').open('rb') as file:
    assert plistlib.load(file)['LSMinimumSystemVersion'] == '12.0'
project = (ROOT / 'HungrySpot.xcodeproj/project.pbxproj').read_text(encoding='utf8')
assert set(re.findall(r'MACOSX_DEPLOYMENT_TARGET = ([\d.]+);', project)) == {'12.0'}
build_script = (ROOT / 'scripts/build-macos.sh').read_text(encoding='utf8')
assert 'swift test --jobs 1' in build_script
assert re.search(r'swift build\s+\\?\s*--configuration release\s+\\?\s*--jobs 1', build_script)
assert not re.search(r'xcodebuild\s+-(?:project|workspace|scheme)', build_script)
assert 'build/The Hungry Spot.app' in build_script
assert 'Test suite completed successfully.' in build_script
assert '74-test' not in build_script

# These are deliberate fixes in the owner's successfully tested upload.
paths_source = (ROOT / 'Sources/HungrySpot/Infrastructure/AppPaths.swift').read_text(encoding='utf8')
assert 'Darwin.lockf' in paths_source and 'lockedPaths' in paths_source and 'NSLock' in paths_source
assert 'Darwin.flock' not in paths_source
database_source = (ROOT / 'Sources/HungrySpotCore/Persistence/Database.swift').read_text(encoding='utf8')
assert 'sqlite3_backup_init' in database_source and 'journal_mode=DELETE' in database_source
assert 'sqlite3_close' in database_source and '-wal' in database_source and '-shm' in database_source
printer_source = (ROOT / 'Sources/HungrySpot/Infrastructure/PrinterService.swift').read_text(encoding='utf8')
assert 'PaginationMode' in printer_source

unsupported = {
    'Swift Charts (macOS 13)': r'\bimport\s+Charts\b|\b(?:BarMark|AxisMarks)\s*\(',
    'NavigationSplitView/NavigationStack (macOS 13)': r'\b(?:NavigationSplitView|NavigationStack)\s*\{',
    'LabeledContent (macOS 13)': r'\bLabeledContent\s*\(',
    'new drag/drop API (macOS 13)': r'\.dropDestination\s*\(',
    'new window sizing (macOS 13)': r'\.(?:defaultSize|windowResizability|navigationSplitViewColumnWidth)\s*\(',
    'scroll content backgrounds (macOS 13)': r'\.scrollContentBackground\s*\(',
    'selection context menus (macOS 13)': r'\.contextMenu\s*\(\s*forSelectionType\s*:',
    'vertical TextField API (macOS 13)': r'TextField\([^\n]*\baxis\s*:',
    'lineLimit range overload (macOS 13)': r'\.lineLimit\s*\([^)]*\.\.',
    'grouped Form style (macOS 13)': r'\.formStyle\s*\(\s*\.grouped',
    'two-value onChange (macOS 14)': r'\.onChange\(of:[^\n]*?\)\s*\{\s*\w+\s*,\s*\w+\s+in',
    'Observation (macOS 14 / Swift 5.9)': r'\bimport\s+Observation\b|@Observable\b',
}
failures = []
files = sorted((ROOT / 'Sources').rglob('*.swift'))
for path in files:
    source = path.read_text(encoding='utf8')
    for label, pattern in unsupported.items():
        for match in re.finditer(pattern, source):
            line = source[:match.start()].count('\n') + 1
            failures.append(f'{path.relative_to(ROOT)}:{line}: {label}')
for failure in failures:
    print(failure)
assert not failures, 'Known newer APIs remain in the Monterey target'
print(f'Monterey static gate passed: {len(files)} production Swift files, deployment 12.0, tools 5.7, one SwiftPM build job, manual app bundle.')
print('Known-API scan only; not a full SDK availability check or a native compile/run.')
