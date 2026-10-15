#!/usr/bin/env python3
"""Activate prepared observer/admission only, preserving provider and edge configuration."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('regular configuration file required')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def activate(root, prepared, expected_compose, run=subprocess.run):
    edge = root / 'srv/dai/edge'
    observer = root / 'srv/dai/ops/gateway-admission-observer.env'
    compose = edge / 'compose.yaml'
    if digest(compose) != expected_compose:
        raise ValueError('compose drift')
    if digest(observer) != digest(prepared / 'observer-before.env'):
        raise ValueError('observer drift')
    for name in ('observer-after.env', 'admission-after.env'):
        digest(prepared / name)
    backups = prepared / 'activation-preimages'
    backups.mkdir(mode=0o700, exist_ok=False)
    targets = [observer, edge / 'gateway-admission.env', edge / 'gateway-admission-proxy.py']
    for target in targets:
        digest(target)
        shutil.copy2(target, backups / target.name)
    installer = Path(__file__).resolve().parents[1] / '04-ops/edge-node/install-gateway-admission.sh'
    compose_command = ['docker', 'compose', '--project-name', 'gdc-edge', '--file', str(compose),
                       'up', '-d', '--no-deps', '--force-recreate', 'gateway-admission']
    try:
        run(['bash', str(installer), str(prepared / 'admission-after.env'),
             '--preserve-compose', expected_compose], check=True)
        shutil.copyfile(prepared / 'observer-after.env', observer)
        observer.chmod(0o600)
        run(['systemctl', 'restart', 'gdc-gateway-admission-observer.service'], check=True)
        run(compose_command, cwd=edge, check=True)
        if digest(compose) != expected_compose:
            raise ValueError('compose changed during activation')
    except Exception:
        # Configuration/service rollback only; never replay inference/funding.
        for target in targets:
            shutil.copy2(backups / target.name, target)
        run(['systemctl', 'restart', 'gdc-gateway-admission-observer.service'], check=True)
        run(compose_command, cwd=edge, check=True)
        raise
    print('observer/admission activated; provider unchanged; verify admission before provider cutover')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared', required=True, type=Path)
    parser.add_argument('--compose-sha256', required=True)
    args = parser.parse_args()
    activate(Path('/'), args.prepared, args.compose_sha256)


if __name__ == '__main__':
    main()
