"""Run committed cache reads and bounded month selection without a simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root/'RAIDORoster-Web2IPA/RAIDORoster/RosterMonthCache.swift').read_text()
policy = source[source.index('enum RosterMonthCachePolicy {'):source.index('\nstruct RosterHistoryProgress:')]
with tempfile.TemporaryDirectory(prefix='raido-startup-') as directory:
    fixture = Path(directory)/'Checks.swift'
    fixture.write_text('import Foundation\n'+policy+'\n'+(root/'tests/StartupPolicyChecks.swift.inc').read_text())
    binary = Path(directory)/'checks'
    subprocess.run(['swiftc','-parse-as-library',
        str(root/'RAIDORoster-Web2IPA/RAIDORoster/PortalBridgePolicy.swift'),
        str(root/'RAIDORoster-Web2IPA/RAIDORoster/ProtectedJSONFile.swift'),
        str(fixture),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=15)
