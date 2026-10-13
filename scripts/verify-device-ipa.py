#!/usr/bin/env python3
"""Reject simulator binaries and malformed packaging before exporting a device IPA."""
import plistlib
import struct
import sys
import zipfile
from pathlib import PurePosixPath

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    if any(PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts for name in names):
        raise SystemExit('IPA contains an unsafe archive path.')
    prefix = 'Payload/FunoonWorkforce.app/'
    if any(not name.startswith('Payload/') for name in names):
        raise SystemExit('IPA must contain only the Payload tree.')
    info = plistlib.loads(archive.read(prefix + 'Info.plist'))
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS'] or info.get('DTPlatformName') != 'iphoneos':
        raise SystemExit('Refusing a simulator or non-iPhone device build.')
    executable = info.get('CFBundleExecutable')
    if not executable or PurePosixPath(executable).name != executable:
        raise SystemExit('Invalid app executable name.')
    binary = archive.read(prefix + executable)
    if len(binary) < 32 or struct.unpack_from('<II', binary) != (0xFEEDFACF, 0x0100000C):
        raise SystemExit('Expected a 64-bit ARM iPhone executable.')
    if archive.testzip() is not None:
        raise SystemExit('IPA archive is damaged.')
print('Device IPA structure passed: iPhoneOS platform, ARM64 executable and Payload bundle.')
print('This verifies build packaging, not signing, installation or physical-device behavior.')
