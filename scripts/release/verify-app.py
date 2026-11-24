#!/usr/bin/env python3
"""Verify the compiled Roomwave identity and bundled pilot asset."""
import argparse,json,plistlib,zipfile
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument("path",type=Path)
p.add_argument("--build",required=True)
args=p.parse_args()
if args.path.suffix==".ipa":
    with zipfile.ZipFile(args.path) as archive:
        roots=[n for n in archive.namelist() if n.startswith("Payload/") and n.count("/")==2 and n.endswith(".app/Info.plist")]
        if len(roots)!=1: raise SystemExit("Expected one primary app in IPA")
        info=plistlib.loads(archive.read(roots[0]))
        prefix=roots[0].removesuffix("Info.plist")
        model=any(n.startswith(prefix) and n.endswith("/RoomwavePilot.usdz") and archive.getinfo(n).file_size>0 for n in archive.namelist())
        catalog=prefix+"Assets.car" in archive.namelist()
else:
    info=plistlib.loads((args.path/"Info.plist").read_bytes())
    model=any(x.stat().st_size>0 for x in args.path.rglob("RoomwavePilot.usdz"))
    catalog=(args.path/"Assets.car").is_file()
for key,value in {"CFBundleIdentifier":"org.timelabs.blueshoes.roomwave","CFBundleShortVersionString":"0.1.0","CFBundleVersion":args.build}.items():
    if str(info.get(key))!=value: raise SystemExit("Compiled identity differs: "+key)
if not model or not catalog: raise SystemExit("Pilot asset or compiled asset catalog missing")
if info.get("ITSAppUsesNonExemptEncryption") is not False: raise SystemExit("Explicit encryption-compliance value is required")
print(json.dumps({"bundle":"org.timelabs.blueshoes.roomwave","version":"0.1.0","build":args.build,"identity_verified":True,"pilot_asset_present":True,"asset_catalog_present":True}))
