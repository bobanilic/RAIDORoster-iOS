"""Render the real SwiftUI reader in CI, after the distributable IPA is built.

The disposable simulator build replaces only the entry point and appends a preview
host to the generated source. It never alters the already-packaged release IPA.
"""
from pathlib import Path
import base64
import hashlib
import json
import plistlib
import subprocess
import time

root = Path(__file__).resolve().parents[1] / 'RAIDORoster-Web2IPA'
ipa = root / 'RAIDORoster-unsigned.ipa'
assert ipa.exists(), 'Build and package the release IPA before previewing'
before = hashlib.sha256(ipa.read_bytes()).hexdigest()
view = root / 'RAIDORoster/AnnouncementsView.swift'
app = root / 'RAIDORoster/RAIDORosterApp.swift'
original_view, original_app = view.read_text(), app.read_text()
preview = '''
struct AnnouncementPreviewRoot: View {
    @StateObject private var store = AnnouncementStore()
    @State private var path: [String] = ["reader"]
    var body: some View {
        NavigationStack(path: $path) {
            Text("Announcements")
                .navigationTitle("Announcements")
                .navigationDestination(for: String.self) { _ in
                    if let catalogue = store.catalogue,
                       let announcement = catalogue.announcements.first(where: { $0.section == "1.1.1" }) {
                        AnnouncementReader(announcement: announcement, catalogue: catalogue, store: store,
                            airline: .getjet, aircraft: .a320, preferredLanguage: .en)
                    }
                }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
    }
}
'''
def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

try:
    view.write_text(original_view + preview)
    assert original_app.count('ContentView()') == 1
    app.write_text(original_app.replace('ContentView()', 'AnnouncementPreviewRoot()'))
    run(['xcodebuild', '-project', str(root / 'RAIDORoster.xcodeproj'), '-scheme', 'RAIDORoster',
         '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
         '-derivedDataPath', '/tmp/raido-reader-preview', 'CODE_SIGNING_ALLOWED=NO', 'build'],
         stdout=open('/tmp/raido-reader-preview-build.log', 'w'), stderr=subprocess.STDOUT)
    product = Path('/tmp/raido-reader-preview/Build/Products/Debug-iphonesimulator/RAIDORoster.app')
    info = plistlib.loads((product / 'Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], capture_output=True, text=True).stdout)
    choices = [d for group in devices['devices'].values() for d in group if d['name'].startswith('iPhone')]
    device = next((d for d in choices if d['name'] == 'iPhone 16 Pro'), choices[0])
    udid = device['udid']
    if device['state'] != 'Booted': run(['xcrun', 'simctl', 'boot', udid])
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
    run(['xcrun', 'simctl', 'install', udid, str(product)])
    run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100'])
    for theme in ['dark', 'light']:
        run(['xcrun', 'simctl', 'launch', udid, bundle] + (['--light'] if theme == 'light' else []))
        time.sleep(4)
        path = Path('/tmp/raido-reader-' + theme + '.png')
        run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(path)])
        jpg = path.with_suffix('.jpg')
        run(['sips', '-Z', '1100', '-s', 'format', 'jpeg', '-s', 'formatOptions', '75', str(path), '--out', str(jpg)], stdout=subprocess.DEVNULL)
        print('RAIDO_READER_' + theme.upper() + '=' + base64.b64encode(jpg.read_bytes()).decode(), flush=True)
        run(['xcrun', 'simctl', 'terminate', udid, bundle])
finally:
    view.write_text(original_view); app.write_text(original_app)
    assert hashlib.sha256(ipa.read_bytes()).hexdigest() == before, 'Preview must not change the release IPA'
