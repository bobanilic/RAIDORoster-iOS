"""Exercise the committed Fleet store against a local URLProtocol fake."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = root / 'RAIDORoster-Web2IPA/RAIDORoster'
with tempfile.TemporaryDirectory(prefix='fleet-store-') as directory:
    fixture = Path(directory) / 'FleetStoreChecks.swift'
    fixture.write_text('import Foundation\n' + (root / 'tests/FleetStoreChecks.swift.inc').read_text())
    executable = Path(directory) / 'checks'
    sources = ['FleetTrackingPolicy.swift', 'FleetRefreshPolicy.swift', 'AircraftHTTPClient.swift',
               'FleetModels.swift', 'FleetLiveStore.swift', 'RosterModels.swift',
               'RosterFormatting.swift', 'RosterTimestamp.swift', 'AnnouncementModels.swift']
    subprocess.run(['swiftc', *[str(app / name) for name in sources], str(fixture), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
