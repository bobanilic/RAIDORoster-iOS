"""Check the actual generated aircraft catalogue and announcement resolver."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = root / 'RAIDORoster-Web2IPA/RAIDORoster'
content = (app / 'ContentView.swift').read_text()
a = content.index('private struct FleetAircraftDefinition:')
b = content.index('\nprivate struct FleetLiveSnapshot:', a)
c = content.index('func announcementAirline(registration: String) -> AnnouncementAirline {')
d = content.index('\n}', c) + 2
checks = '''
@main struct Checks {
    static func main() throws {
        let book = try AnnouncementCatalogue.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(announcementAirline(registration: "LYTEN") == .getjet)
        precondition(!book.available(airline: announcementAirline(registration: "LYTEN"), aircraft: .a320).isEmpty)
        precondition(announcementAirline(registration: "9HGTS") == .airhub)
        precondition(book.available(airline: announcementAirline(registration: "9HGTS"), aircraft: .a320).isEmpty)
        precondition(announcementAirline(registration: "LYXYZ") == .unspecified)
        precondition(announcementAirline(registration: "6H501") == .unspecified)
        for aircraft in FleetAircraftDefinition.all {
            let expected: AnnouncementAirline = aircraft.operatorCode == "GETJET" ? .getjet : .airhub
            precondition(announcementAirline(registration: aircraft.registration) == expected)
            precondition(announcementAirline(registration: aircraft.registration.replacingOccurrences(of: "-", with: "")) == expected)
        }
        print("Passed actual generated announcement selection: \\(FleetAircraftDefinition.all.count) aircraft, compact tails, unknown tails, offline scripts")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='announcement-selection-') as directory:
    source = Path(directory) / 'Checks.swift'
    source.write_text('import Foundation\n' + content[a:b] + '\n' + content[c:d] + '\n' + checks)
    executable = Path(directory) / 'checks'
    subprocess.run(['swiftc', str(app / 'AnnouncementModels.swift'), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(app / 'GetJetAnnouncements.json')], check=True)
