from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

# V2.11 is generated from raw Python strings. Normalize only double-escaped
# Swift interpolation/key-path sequences that should be single backslashes in
# the final .swift source.
content = content.replace(r"\\(", r"\(")
content = content.replace(r"\\.", r"\.")

CONTENT.write_text(content)
print("V2.11 Swift escape normalization applied")
