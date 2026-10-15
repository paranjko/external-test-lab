#!/usr/bin/env python3
"""Align existing bot/site observation models without replacing other settings."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import tempfile


def update(bot_env, sites, expected, model, evidence, env_key='MODEL'):
    if (env_key not in ('MODEL', 'GDC_GATEWAY_READINESS_MODEL')
            or (env_key == 'MODEL' and not sites)
            or not all(re.fullmatch(r'[A-Za-z0-9_.\-/]+', v) for v in (expected, model))):
        raise ValueError('invalid model or missing site')
    paths = [bot_env, *sites]
    if len(set(paths)) != len(paths):
        raise ValueError('duplicate target')
    prepared = []
    for index, path in enumerate(paths):
        if path.is_symlink() or not path.is_file():
            raise ValueError('regular existing file required')
        before = path.read_bytes()
        text = before.decode()
        if index == 0:
            matches = list(re.finditer(r'^' + env_key + r'=([^\r\n]*)$', text, re.M))
            if len(matches) != 1 or matches[0][1] not in (expected, '"' + expected + '"'):
                raise ValueError('bot model drift')
            match = matches[0]
            replacement = '"' + model + '"' if match[1].startswith('"') else model
            after = text[:match.start(1)] + replacement + text[match.end(1):]
        else:
            wrapper = re.fullmatch(r'(\s*window\.GDC_CONFIG\s*=\s*)(\{.*\})(\s*;?\s*)', text, re.S)
            if not wrapper:
                raise ValueError('unsupported site configuration')
            config = json.loads(wrapper[2])
            if config.get('model') != expected:
                raise ValueError('site model drift')
            matches = list(re.finditer(r'"model"\s*:\s*"([^"\\]*)"', wrapper[2]))
            if len(matches) != 1 or matches[0][1] != expected:
                raise ValueError('ambiguous site model')
            start, end = matches[0].span(1)
            body = wrapper[2][:start] + model + wrapper[2][end:]
            updated = json.loads(body)
            config['model'] = model
            if updated != config:
                raise ValueError('unrelated site mutation')
            after = wrapper[1] + body + wrapper[3]
        prepared.append((path, before, after.encode(), path.stat()))
    evidence.mkdir(mode=0o700, exist_ok=False)
    for index, (_, before, _, _) in enumerate(prepared):
        with os.fdopen(os.open(evidence / f'{index}.before', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'wb') as out:
            out.write(before)
            out.flush()
            os.fsync(out.fileno())
    for path, before, after, info in prepared:
        if path.is_symlink() or path.read_bytes() != before:
            raise ValueError('target drift; inspect retained preimages')
        fd, temporary = tempfile.mkstemp(prefix='.model-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as out:
                os.fchmod(out.fileno(), stat.S_IMODE(info.st_mode))
                os.fchown(out.fileno(), info.st_uid, info.st_gid)
                out.write(after)
                out.flush()
                os.fsync(out.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print('Observation model updated; reload only the owning observation service')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bot-env', required=True, type=Path)
    parser.add_argument('--site-config', default=[], action='append', type=Path)
    parser.add_argument('--env-key', choices=('MODEL', 'GDC_GATEWAY_READINESS_MODEL'), default='MODEL')
    parser.add_argument('--expected-model', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    try:
        update(args.bot_env, args.site_config, args.expected_model, args.model, args.evidence, args.env_key)
    except (ValueError, OSError):
        raise SystemExit('Observation model update refused or partial; inspect private preimages before retry')
