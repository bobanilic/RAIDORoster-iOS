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
ve = s.find("\nstruct RosterHomeView: View {", vs)
if vs < 0 or ve < 0:
    raise RuntimeError("ContentView scope fix: bounds missing")

content_view = s[vs:ve]
balance = swift_brace_balance(content_view)

if balance == 1:
    # The opening ContentView brace is still live at the next top-level type.
    # Close only that struct; do not alter any body or nested declaration.
    s = s[:ve] + "\n}" + s[ve:]
elif balance != 0:
    raise RuntimeError(f"ContentView scope fix: unexpected brace balance {balance}")

# Re-check after repair. RosterHomeView must start at file scope.
ve2 = s.find("\nstruct RosterHomeView: View {", vs)
if ve2 < 0 or swift_brace_balance(s[vs:ve2]) != 0:
    raise RuntimeError("ContentView scope fix: ContentView still not closed")

CONTENT.write_text(s)
print("ContentView file-scope structural validation applied")
