from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

old = '''    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-ELM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-FOX", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "220Y"),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-KUA", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "180Y")
    ]
'''

new = '''    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-CAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-DAE", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-EKB", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-FAS", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-FOX", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-GYM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WIL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WIZ", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "")
    ]
'''

if new not in content:
    if old not in content:
        raise RuntimeError("V2.17.4 fleet catalog marker not found")
    content = content.replace(old, new, 1)

content = content.replace(
    'Text("\\(aircraft.operatorName) • \\(aircraft.type) • \\(aircraft.seats)")',
    'Text("\\(aircraft.operatorName) • \\(aircraft.type)")',
    1,
)

content = content.replace(
    '''                        LabeledContent("Aircraft", value: aircraft.type)\n                        LabeledContent("Cabin", value: aircraft.seats)\n                        LabeledContent("Operator", value: aircraft.operatorName)\n''',
    '''                        LabeledContent("Aircraft", value: aircraft.type)\n                        if !aircraft.seats.isEmpty {\n                            LabeledContent("Cabin", value: aircraft.seats)\n                        }\n                        LabeledContent("Operator", value: aircraft.operatorName)\n''',
    1,
)

CONTENT.write_text(content)
print("V2.17.4 current public fleet catalog and conservative cabin metadata applied")
