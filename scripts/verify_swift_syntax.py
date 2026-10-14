"""Parse Swift source without claiming compilation/type checking.

Requires tree-sitter and tree-sitter-swift, available locally in .verification-tools.
On a Mac the authoritative check is `bash scripts/build-macos.sh`.
"""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.verification-tools'))
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))
failures = []
files = [ROOT / 'Package.swift', *sorted((ROOT / 'Sources').rglob('*.swift')), *sorted((ROOT / 'Tests').rglob('*.swift'))]
for path in files:
    source = path.read_bytes()
    tree = parser.parse(source)
    def visit(node):
        if node.type == 'ERROR' or node.is_missing:
            failures.append((str(path.relative_to(ROOT)), node.start_point.row + 1, node.start_point.column + 1, node.type, source[node.start_byte:node.end_byte].decode('utf8')[:180]))
        for child in node.children:
            visit(child)
    visit(tree.root_node)
for file, line, column, kind, fragment in failures:
    print(f'{file}:{line}:{column}: {kind}: {fragment!r}')
print(f'Swift syntax parse: {len(files)} files, {len(failures)} grammar errors. This is not a native compiler or type check.')
raise SystemExit(bool(failures))
