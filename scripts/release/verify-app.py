#!/usr/bin/env python3
"""Verify the compiled Roomwave identity and bundled pilot asset."""
import argparse,json,plistlib,zipfile
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument("path",type=Path)
p.add_argument("--build",required=True)
p.add_argument("--version",default=(Path(__file__).resolve().parents[2]/"VERSION").read_text().strip())
args=p.parse_args()
if args.path.suffix==".ipa":
    with zipfile.ZipFile(args.path) as archive:
        roots=[n for n in archive.namelist() if n.startswith("Payload/") and n.count("/")==2 and n.endswith(".app/Info.plist")]
        if len(roots)!=1: raise SystemExit("Expected one primary app in IPA")
        info=plistlib.loads(archive.read(roots[0]))
        prefix=roots[0].removesuffix("Info.plist")
        model=any(n.startswith(prefix) and n.endswith("/RoomwavePilot.usdz") and archive.getinfo(n).file_size>0 for n in archive.namelist())
        catalog=prefix+"Assets.car" in archive.namelist()
        privacy=plistlib.loads(archive.read(prefix+"PrivacyInfo.xcprivacy")) if prefix+"PrivacyInfo.xcprivacy" in archive.namelist() else None
else:
    info=plistlib.loads((args.path/"Info.plist").read_bytes())
    model=any(x.stat().st_size>0 for x in args.path.rglob("RoomwavePilot.usdz"))
    catalog=(args.path/"Assets.car").is_file()
    privacy=plistlib.loads((args.path/"PrivacyInfo.xcprivacy").read_bytes()) if (args.path/"PrivacyInfo.xcprivacy").is_file() else None
for key,value in {"CFBundleIdentifier":"org.timelabs.moleculefoundry","CFBundleShortVersionString":args.version,"CFBundleVersion":args.build}.items():
    if str(info.get(key))!=value: raise SystemExit("Compiled identity differs: "+key)
if 2 in info.get("UIDeviceFamily", []):
    required_orientations = {
        "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
    }
    ipad_orientations = info.get("UISupportedInterfaceOrientations~ipad",
                                 info.get("UISupportedInterfaceOrientations", []))
    if not isinstance(ipad_orientations, list) or not required_orientations.issubset(ipad_orientations):
        raise SystemExit("iPad multitasking requires all four interface orientations in the compiled app")
if not model or not catalog: raise SystemExit("Pilot asset or compiled asset catalog missing")
if info.get("ITSAppUsesNonExemptEncryption") is not False: raise SystemExit("Explicit encryption-compliance value is required")
if not privacy or privacy.get("NSPrivacyTracking") is not False or not any(x.get("NSPrivacyAccessedAPIType")=="NSPrivacyAccessedAPICategorySystemBootTime" and "35F9.1" in x.get("NSPrivacyAccessedAPITypeReasons",[]) for x in privacy.get("NSPrivacyAccessedAPITypes",[])):
    raise SystemExit("Expected elapsed-time privacy manifest is missing")
print(json.dumps({"bundle":"org.timelabs.moleculefoundry","version":args.version,"build":args.build,"identity_verified":True,"pilot_asset_present":True,"asset_catalog_present":True,"privacy_manifest_verified":True}))
