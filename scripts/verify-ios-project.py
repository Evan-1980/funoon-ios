#!/usr/bin/env python3
"""Validate portable Xcode inputs before attempting a cloud compilation."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

mobile = Path(__file__).resolve().parents[1]
ios = mobile / "ios"
app = ios / "FunoonWorkforce"
project = ios / "FunoonWorkforce.xcodeproj"
pbx = (project / "project.pbxproj").read_text()
info = plistlib.loads((app / "Info.plist").read_bytes())
privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
scheme = ET.parse(project / "xcshareddata/xcschemes/FunoonWorkforce.xcscheme")

assert info["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)"
assert info["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
assert "location" in info["UIBackgroundModes"]
assert info["NSLocationWhenInUseUsageDescription"].strip()
assert privacy["NSPrivacyTracking"] is False
reasons = {row["NSPrivacyAccessedAPIType"]: row["NSPrivacyAccessedAPITypeReasons"]
           for row in privacy["NSPrivacyAccessedAPITypes"]}
assert "CA92.1" in reasons["NSPrivacyAccessedAPICategoryUserDefaults"]

objects = re.findall(r'^\s+([A-Fa-f0-9]{24})\s*=\s*\{', pbx, re.M)
assert len(objects) == len(set(objects)), "Duplicate Xcode object identifiers"
for reference in scheme.iter("BuildableReference"):
    assert reference.attrib["BlueprintIdentifier"] in objects
    assert reference.attrib["ReferencedContainer"] == "container:FunoonWorkforce.xcodeproj"
assert 'name = FunoonWorkforce;' in pbx
assert 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;' in pbx
for source in ["FunoonWorkforceApp.swift", "Tracker.swift", "API.swift"]:
    assert (app / source).is_file(), "Missing Swift source: " + source
    assert "path = " + source + ";" in pbx

icons = app / "Assets.xcassets/AppIcon.appiconset"
for item in json.loads((icons / "Contents.json").read_text())["images"]:
    if "filename" not in item:
        continue
    png = (icons / item["filename"]).read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack(">II", png[16:24])
    expected = int(float(item["size"].split("x")[0]) * float(item["scale"].rstrip("x")))
    assert (width, height) == (expected, expected), "Incorrect icon dimensions"
    if item["idiom"] == "ios-marketing":
        assert png[25] in (0, 2), "Store icon must have no alpha channel"

origin = re.search(r'static let origin = URL\(string: "([^"]+)"\)',
                   (app / "API.swift").read_text()).group(1)
assert origin == "https://funoon-workforce.evan80.chatgpt.site"
print("iOS inputs passed: Xcode references, shared scheme, permissions, privacy reasons, icons and production API origin.")
print("This is source validation; it does not replace Xcode compilation or physical iPhone testing.")
