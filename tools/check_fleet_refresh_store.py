"""Exercise the actual generated Fleet store against a local URLProtocol fake."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
content = (root / 'RAIDORoster-Web2IPA/RAIDORoster/ContentView.swift').read_text()
start = content.index('private struct FleetAircraftDefinition:')
end = content.index('\nprivate enum FleetFilter:', start)
extension = content[content.index('extension String {'):].split('\n}', 1)[0] + '\n}'
with tempfile.TemporaryDirectory(prefix='fleet-store-') as directory:
    fixture = Path(directory) / 'FleetStoreChecks.swift'
    fixture.write_text('import Foundation\nimport Combine\nimport CoreLocation\n' + content[start:end] + '\n' + extension + '\n' +
                       (root / 'tests/FleetStoreChecks.swift.inc').read_text())
    executable = Path(directory) / 'checks'
    subprocess.run(['swiftc', str(root / 'RAIDORoster-Web2IPA/RAIDORoster/FleetTrackingPolicy.swift'),
                    str(root / 'RAIDORoster-Web2IPA/RAIDORoster/FleetRefreshPolicy.swift'),
                    str(root / 'RAIDORoster-Web2IPA/RAIDORoster/AircraftHTTPClient.swift'), str(fixture),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
