from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()


def swift_brace_balance(text: str) -> int:
    """Count structural Swift braces while ignoring comments and string literals."""
    balance = 0
    i = 0
    n = len(text)
    block_comment_depth = 0
    state = "code"

    while i < n:
        if state == "line_comment":
            if text[i] == "\n":
                state = "code"
            i += 1
            continue

        if state == "block_comment":
            if text.startswith("/*", i):
                block_comment_depth += 1
                i += 2
            elif text.startswith("*/", i):
                block_comment_depth -= 1
                i += 2
                if block_comment_depth == 0:
                    state = "code"
            else:
                i += 1
            continue

        if state == "string":
            if text[i] == "\\":
                i += 2
            elif text[i] == '"':
                state = "code"
                i += 1
            else:
                i += 1
            continue

        if state == "multiline_string":
            if text.startswith('"""', i):
                state = "code"
                i += 3
            else:
                i += 1
            continue

        if text.startswith("//", i):
            state = "line_comment"
            i += 2
        elif text.startswith("/*", i):
            state = "block_comment"
            block_comment_depth = 1
            i += 2
        elif text.startswith('"""', i):
            state = "multiline_string"
            i += 3
        elif text[i] == '"':
            state = "string"
            i += 1
        elif text[i] == "{":
            balance += 1
            i += 1
        elif text[i] == "}":
            balance -= 1
            if balance < 0:
                raise RuntimeError("ContentView scope fix: unexpected closing brace")
            i += 1
        else:
            i += 1

    if state == "block_comment":
        raise RuntimeError("ContentView scope fix: unterminated block comment")
    return balance


vs = s.find("struct ContentView: View {")
if vs < 0:
    raise RuntimeError("ContentView scope fix: ContentView missing")

# V2.11.x inserts reusable file-scope helper views between ContentView and
# RosterHomeView. Use the earliest of those helpers as the ContentView boundary;
# closing only at RosterHomeView would incorrectly nest the helpers.
boundary_markers = [
    "\nstruct SyncFreshnessStrip: View {",
    "\nprivate struct SyncFreshnessStrip: View {",
    "\nstruct RosterHeaderPrincipal: View {",
    "\nprivate struct RosterHeaderPrincipal: View {",
    "\nstruct RosterHomeView: View {",
]
boundaries = [s.find(marker, vs) for marker in boundary_markers]
boundaries = [pos for pos in boundaries if pos >= 0]
if not boundaries:
    raise RuntimeError("ContentView scope fix: no following file-scope boundary found")
boundary = min(boundaries)

balance = swift_brace_balance(s[vs:boundary])
if balance == 1:
    # Only the ContentView opening brace remains live. Close it immediately
    # before the first reusable helper view.
    s = s[:boundary] + "\n}" + s[boundary:]
elif balance != 0:
    raise RuntimeError(f"ContentView scope fix: unexpected brace balance {balance}")

# Every known reusable helper following ContentView must now be at file scope.
for marker in boundary_markers:
    pos = s.find(marker, vs)
    if pos >= 0 and swift_brace_balance(s[vs:pos]) != 0:
        raise RuntimeError("ContentView scope fix: helper still nested: " + marker.strip())

CONTENT.write_text(s)
print("ContentView file-scope structural validation applied")
