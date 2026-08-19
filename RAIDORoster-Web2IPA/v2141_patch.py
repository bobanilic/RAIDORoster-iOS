from pathlib import Path

ROOT = Path(__file__).resolve().parent
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

pbx = PBX.read_text()
key = "INFOPLIST_KEY_NSLocationWhenInUseUsageDescription"
if key not in pbx:
    marker = "GENERATE_INFOPLIST_FILE = YES;"
    if marker not in pbx:
        raise RuntimeError("V2.14.1 generated Info.plist marker not found")
    pbx = pbx.replace(
        marker,
        marker + '\n\t\t\t\tINFOPLIST_KEY_NSLocationWhenInUseUsageDescription = "Allow RAIDO Roster to use this iPhone\'s location only while Live GPS tracking is active on the Today route map.";'
    )
PBX.write_text(pbx)
print("V2.14 location usage description build setting applied")
