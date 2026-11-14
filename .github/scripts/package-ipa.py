#!/usr/bin/env python3
"""Package an IPA for re-signing, retaining its App Group entitlement."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import shutil
import zipfile


def run(*args):
    return subprocess.run(args, check=True, capture_output=True)


def verify(app, expected):
    run('codesign', '--verify', '--strict', str(app))
    result = run('codesign', '-d', '--entitlements', '-', '--xml', str(app))
    actual = plistlib.loads(result.stdout)
    if actual != expected:
        raise RuntimeError('Packaged signature does not contain the expected entitlements')
    details = run('codesign', '-dvv', str(app)).stderr.decode()
    if 'Signature=adhoc' not in details or 'TeamIdentifier=not set' not in details:
        raise RuntimeError('Expected an ad-hoc signature without a developer identity')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    source = args.app.resolve()
    output = args.output.resolve()
    info = plistlib.loads((source / 'Info.plist').read_bytes())
    bundle_id = info['CFBundleIdentifier']
    if not isinstance(bundle_id, str) or not bundle_id or '$' in bundle_id:
        raise RuntimeError('Invalid built bundle identifier')
    template = Path(__file__).resolve().parents[2] / 'placard/placard.entitlements'
    entitlements = plistlib.loads(template.read_bytes())
    groups = entitlements.get('com.apple.security.application-groups')
    if not isinstance(groups, list) or not groups:
        raise RuntimeError('App Group declaration is missing')
    groups = [group.replace('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle_id) for group in groups]
    if any(not group.startswith('group.') or '$' in group for group in groups):
        raise RuntimeError('App Group declaration could not be expanded')
    entitlements['com.apple.security.application-groups'] = groups
    if 'application-identifier' in entitlements or 'com.apple.developer.team-identifier' in entitlements:
        raise RuntimeError('Re-signable packages must not embed developer identity entitlements')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='placard-package-', dir=output.parent) as temporary:
        staging = Path(temporary)
        payload = staging / 'Payload'
        payload.mkdir()
        app = payload / source.name
        shutil.copytree(source, app, symlinks=True)
        if list(app.rglob('*.appex')):
            raise RuntimeError('Embedded extensions need their own explicit entitlement configuration')
        nested = [p for p in app.rglob('*') if p.suffix in ('.framework', '.dylib')]
        for item in sorted(nested, key=lambda p: len(p.parts), reverse=True):
            run('codesign', '--force', '--sign', '-', str(item))
        entitlement_file = staging / 'entitlements.plist'
        entitlement_file.write_bytes(plistlib.dumps(entitlements))
        run('codesign', '--force', '--sign', '-', '--entitlements', str(entitlement_file), str(app))
        verify(app, entitlements)
        ipa = staging / 'package.ipa'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(ipa))
        with zipfile.ZipFile(ipa) as archive:
            if archive.testzip() is not None:
                raise RuntimeError('IPA integrity check failed')
        unpacked = staging / 'verified'
        run('ditto', '-x', '-k', str(ipa), str(unpacked))
        verify(unpacked / 'Payload' / source.name, entitlements)
        os.replace(ipa, output)
    print(f'Packaged {info["CFBundleShortVersionString"]}: {output}')
    print(f'Embedded App Groups: {", ".join(groups)}')


if __name__ == '__main__':
    main()
