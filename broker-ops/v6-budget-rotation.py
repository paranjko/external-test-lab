#!/usr/bin/env python3
"""Operator rotation with durable gross-funding caps; not native qualification."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import urllib.error
import urllib.request

MODEL = 'Qwen/Qwen3-0.6B'
AMOUNT = 1_000_000_000
CAP = 5000  # Each independently bound A/B campaign reserves at most 5000 GNK.


def initialize(path, instance):
    # Initialization is deliberately separate. Never recreate a missing ledger.
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    with sqlite3.connect(path / 'ledger.sqlite') as db:
        db.executescript('''
          CREATE TABLE binding(instance TEXT NOT NULL, cap INTEGER NOT NULL);
          CREATE TABLE funding(epoch INTEGER PRIMARY KEY, amount INTEGER NOT NULL,
            result TEXT, escrow TEXT, settled INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE settlement(epoch INTEGER NOT NULL, attempt INTEGER NOT NULL,
            result TEXT, PRIMARY KEY(epoch, attempt));
        ''')
        db.execute('INSERT INTO binding VALUES (?, ?)', (instance, CAP))


def tick(path, instance, request):
    with (path / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # URI mode=rw fails closed if the ledger disappears after installation.
        with sqlite3.connect((path / 'ledger.sqlite').as_uri() + '?mode=rw', uri=True) as db:
            db.execute('PRAGMA synchronous=FULL')
            assert db.execute('SELECT * FROM binding').fetchall() == [(instance, CAP)]
            rows = db.execute('SELECT epoch,amount,result,escrow,settled FROM funding').fetchall()
            assert all(row[1] == AMOUNT for row in rows) and len(rows) <= CAP
            # Any ambiguous or failed transaction requires operator reconciliation.
            if any(row[2] is None or row[3] is None or not 200 <= json.loads(row[2])['status'] < 300 for row in rows):
                return 'halt: funding outcome needs reconciliation'
            if db.execute('SELECT count(*) FROM settlement WHERE result IS NULL').fetchone()[0]:
                return 'halt: settlement outcome needs reconciliation'
            settings = request('/v1/admin/settings')
            assert settings['status'] == 200
            assert settings['result']['escrow_rotation']['enabled'] is False
            debug = request('/v1/debug/rotation')
            assert debug['status'] == 200
            chain = debug['result']['chain']
            epoch = int(chain['epoch_index'])
            assert epoch > 0
            # Do not settle the previous epoch during handover; never force busy work.
            for old, _, _, escrow, settled in rows:
                if settled or old > epoch - 2:
                    continue
                attempts = db.execute('SELECT result FROM settlement WHERE epoch=?', (old,)).fetchall()
                if len(attempts) >= 3:
                    return 'halt: settlement retry allowance exhausted'
                if any(json.loads(r[0])['status'] != 409 for r in attempts):
                    return 'halt: settlement failure needs reconciliation'
                attempt = len(attempts) + 1
                db.execute('INSERT INTO settlement VALUES (?,?,NULL)', (old, attempt))
                db.commit()
                result = request('/v1/admin/devshards/' + str(escrow) + '/settle',
                                 {'private_key_env': 'DEVSHARD_PRIVATE_KEY', 'force': False})
                db.execute('UPDATE settlement SET result=? WHERE epoch=? AND attempt=?',
                           (json.dumps(result), old, attempt))
                if 200 <= result['status'] < 300:
                    db.execute('UPDATE funding SET settled=1 WHERE epoch=?', (old,))
                db.commit()
                if result['status'] != 409 and not 200 <= result['status'] < 300:
                    return 'halt: settlement failure needs reconciliation'
                # Bound each invocation to one settlement plus one creation.
                break
            if len(rows) >= CAP:
                return 'budget exhausted: no more funding'
            if epoch in [row[0] for row in rows]:
                return 'waiting: this epoch already funded'
            if chain['phase'] != 'Inference' or chain['blocks_to_epoch_switch'] < 15:
                return 'waiting: normal funding window'
            db.execute('INSERT INTO funding(epoch,amount) VALUES (?,?)', (epoch, AMOUNT))
            db.commit()  # Reserve even if the request crashes or its reply is lost.
            result = request('/v1/admin/escrows', {'amount': AMOUNT, 'model_id': MODEL,
                                                 'private_key_env': 'DEVSHARD_PRIVATE_KEY'})
            escrow = result.get('result', {}).get('escrow_id') if isinstance(result.get('result'), dict) else None
            db.execute('UPDATE funding SET result=?,escrow=? WHERE epoch=?',
                       (json.dumps(result), str(escrow) if escrow is not None else None, epoch))
            db.commit()
            if not 200 <= result['status'] < 300 or escrow is None:
                return 'halt: creation failed or returned no escrow identity'
            return 'created: reserved_gnk=' + str(len(rows) + 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('instance', choices=['a', 'b'])
    p.add_argument('--initialize', action='store_true')
    a = p.parse_args()
    os.umask(0o077)
    root = Path('/srv/dai/broker-tests')
    path = root / ('v6-' + a.instance) / 'rotation-10000gnk-20261013'
    if a.initialize:
        initialize(path, a.instance)
        return
    values = dict(line.split('=', 1) for line in (root / ('ds502-' + a.instance) / 'gateway.env').read_text().splitlines()
                  if line and not line.startswith('#'))
    origin = 'http://127.0.0.1:' + ('18187' if a.instance == 'a' else '18188')
    def request(route, payload=None):
        req = urllib.request.Request(origin + route,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + values['DEVSHARD_ADMIN_API_KEY'], 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                return {'status': response.status, 'result': json.load(response)}
        except urllib.error.HTTPError as error:
            return {'status': error.code, 'result': error.read().decode()}
    try:
        result = tick(path, a.instance, request)
    except Exception as error:
        # Do not log response bodies, environment or credentials.
        print('rotation check failed: ' + type(error).__name__, flush=True)
        raise SystemExit(1)
    print(result, flush=True)
    if result.startswith('halt:'):
        subprocess.run(['systemctl', 'stop', 'gdc-v6-budget-' + a.instance + '.timer'], check=True)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
