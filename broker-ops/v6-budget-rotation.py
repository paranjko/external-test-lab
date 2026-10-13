#!/usr/bin/env python3
"""Operator rotation with durable gross-funding caps; not native qualification."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request

MODEL = 'Qwen/Qwen3-0.6B'
AMOUNT = 1_000_000_000
CAP = 5000  # Each independently bound A/B campaign reserves at most 5000 GNK.
UNITS_PER_GNK = 1_000_000_000
PARAMS_ROUTE = '/productscience/inference/inference/params'
ESCROW_ROUTE = '/productscience/inference/inference/devshard_escrow/'


def positive_integer(value):
    # Chain JSON encodes uint64 as decimal strings. Reject lossy conversions.
    if isinstance(value, str) and value.isascii() and value.isdecimal():
        value = int(value)
    if type(value) is not int or value <= 0:
        raise ValueError('expected a positive integer amount')
    return value


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


def reconciled_epochs(db, rows):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='reconciliation'").fetchone():
        return set()
    known = {row[0]: (row[1], row[3]) for row in rows}
    result = set()
    for epoch, amount, escrow in db.execute('SELECT epoch,amount,escrow FROM reconciliation'):
        if known.get(epoch) != (amount, escrow):
            raise ValueError('reconciliation binding mismatch')
        result.add(epoch)
    return result


def reconcile_settled(path, instance, request, escrow_id):
    """Append a current chain-terminal observation; never submit a transaction."""
    escrow_id = str(positive_integer(escrow_id))
    with (path / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with sqlite3.connect((path / 'ledger.sqlite').as_uri() + '?mode=rw', uri=True) as db:
            db.execute('PRAGMA synchronous=FULL')
            if instance not in ('a', 'b') or db.execute('SELECT * FROM binding').fetchall() != [(instance, CAP)]:
                raise ValueError('campaign binding mismatch')
            rows = db.execute('SELECT epoch,amount,result,escrow,settled FROM funding WHERE escrow=?', (escrow_id,)).fetchall()
            if len(rows) != 1:
                raise ValueError('one known funding record required')
            epoch, amount, result, _, _ = rows[0]
            positive_integer(amount)
            if result is None or not 200 <= json.loads(result)['status'] < 300:
                return 'halt: creation outcome still ambiguous'
            chain = request(ESCROW_ROUTE + escrow_id)
            if chain['status'] != 200 or chain['result'].get('found') is not True:
                return 'halt: absent escrow is not settlement proof'
            observed = chain['result']['escrow']
            if (str(observed['id']) != escrow_id or
                    positive_integer(observed['amount']) != amount or
                    int(observed['epoch_index']) != epoch or observed['settled'] is not True):
                return 'halt: matching settled chain record required'
            state = request('/v1/admin/state')
            if state['status'] != 200:
                return 'halt: runtime state unavailable'
            matches = [item for item in state['result']['devshards'] if str(item['id']) == escrow_id]
            if len(matches) != 1 or matches[0].get('active') is not False:
                return 'halt: inactive runtime record required'
            # Preserve original funding/settlement rows, including errors. This
            # new observation resolves operational handling, not past verdicts.
            db.execute('''CREATE TABLE IF NOT EXISTS reconciliation(
                epoch INTEGER PRIMARY KEY, amount INTEGER NOT NULL,
                escrow TEXT NOT NULL, observed_at INTEGER NOT NULL, proof TEXT NOT NULL)''')
            previous = db.execute('SELECT amount,escrow FROM reconciliation WHERE epoch=?', (epoch,)).fetchone()
            if previous is not None:
                if previous != (amount, escrow_id):
                    raise ValueError('reconciliation binding mismatch')
                return 'reconciled: observation already retained'
            proof = {'chain': chain, 'runtime': {'id': escrow_id, 'active': False}}
            db.execute('INSERT INTO reconciliation VALUES (?,?,?,?,?)',
                       (epoch, amount, escrow_id, int(time.time()), json.dumps(proof)))
            db.commit()
            return 'reconciled: chain settled; gross reservation unchanged'


def tick(path, instance, request, amount=AMOUNT, model=MODEL):
    amount = positive_integer(amount)
    if not isinstance(model, str) or not model.strip():
        raise ValueError('explicit model required')
    with (path / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # URI mode=rw fails closed if the ledger disappears after installation.
        with sqlite3.connect((path / 'ledger.sqlite').as_uri() + '?mode=rw', uri=True) as db:
            db.execute('PRAGMA synchronous=FULL')
            if instance not in ('a', 'b') or db.execute('SELECT * FROM binding').fetchall() != [(instance, CAP)]:
                raise ValueError('campaign binding mismatch')
            rows = db.execute('SELECT epoch,amount,result,escrow,settled FROM funding').fetchall()
            # Existing ledger amounts already use chain units. No migration or
            # rewrite is needed, and settled/unknown reservations still count.
            reserved = sum(positive_integer(row[1]) for row in rows)
            if reserved > CAP * UNITS_PER_GNK:
                return 'halt: historical reservations exceed gross allowance'
            # Any ambiguous or failed transaction requires operator reconciliation.
            if any(row[2] is None or row[3] is None or not 200 <= json.loads(row[2])['status'] < 300 for row in rows):
                return 'halt: funding outcome needs reconciliation'
            reconciled = reconciled_epochs(db, rows)
            if any(epoch not in reconciled for (epoch,) in db.execute('SELECT epoch FROM settlement WHERE result IS NULL')):
                return 'halt: settlement outcome needs reconciliation'
            settings = request('/v1/admin/settings')
            if settings['status'] != 200 or settings['result']['escrow_rotation']['enabled'] is not False:
                raise ValueError('native rotation must be disabled')
            params = request(PARAMS_ROUTE)
            if params['status'] != 200:
                return 'halt: chain funding limits unavailable'
            limits = params['result']['params']['devshard_escrow_params']
            minimum = positive_integer(limits['min_amount'])
            maximum = positive_integer(limits['max_amount'])
            if not minimum <= amount <= maximum:
                return 'halt: requested amount outside current chain limits'
            debug = request('/v1/debug/rotation')
            assert debug['status'] == 200
            chain = debug['result']['chain']
            epoch = int(chain['epoch_index'])
            assert epoch > 0
            # Do not settle the previous epoch during handover; never force busy work.
            for old, _, _, escrow, settled in rows:
                if settled or old in reconciled or old > epoch - 2:
                    continue
                attempts = db.execute('SELECT result FROM settlement WHERE epoch=?', (old,)).fetchall()
                if any(json.loads(r[0])['status'] != 409 for r in attempts):
                    return 'halt: settlement failure needs reconciliation'
                if len(attempts) >= 3:
                    # Known-busy escrows remain for manual reconciliation. They
                    # must not interrupt funding of unrelated healthy epochs.
                    continue
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
            if reserved + amount > CAP * UNITS_PER_GNK:
                return 'budget exhausted: no more funding'
            if epoch in [row[0] for row in rows]:
                return 'waiting: this epoch already funded'
            if chain['phase'] != 'Inference' or chain['blocks_to_epoch_switch'] < 15:
                return 'waiting: normal funding window'
            db.execute('INSERT INTO funding(epoch,amount) VALUES (?,?)', (epoch, amount))
            db.commit()  # Reserve even if the request crashes or its reply is lost.
            result = request('/v1/admin/escrows', {'amount': amount, 'model_id': model,
                                                 'private_key_env': 'DEVSHARD_PRIVATE_KEY'})
            escrow = result.get('result', {}).get('escrow_id') if isinstance(result.get('result'), dict) else None
            db.execute('UPDATE funding SET result=?,escrow=? WHERE epoch=?',
                       (json.dumps(result), str(escrow) if escrow is not None else None, epoch))
            db.commit()
            if not 200 <= result['status'] < 300 or escrow is None:
                return 'halt: creation failed or returned no escrow identity'
            return 'created: reserved_units=' + str(reserved + amount)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('instance', choices=['a', 'b'])
    p.add_argument('--initialize', action='store_true')
    p.add_argument('--reconcile-settled', metavar='ESCROW_ID', type=positive_integer,
                   help='append chain-confirmed settlement proof; no transactions or funding')
    p.add_argument('--amount', type=positive_integer, help='escrow amount in integer chain units')
    p.add_argument('--model', help='explicit admitted model ID')
    a = p.parse_args()
    os.umask(0o077)
    root = Path('/srv/dai/broker-tests')
    path = root / ('v6-' + a.instance) / 'rotation-10000gnk-20261013'
    if a.initialize:
        if a.reconcile_settled is not None:
            p.error('initialization and reconciliation are mutually exclusive')
        initialize(path, a.instance)
        return
    if a.reconcile_settled is None and (a.amount is None or not a.model or not a.model.strip()):
        p.error('--amount and --model are required; old service configuration must not silently resume')
    values = dict(line.split('=', 1) for line in (root / ('ds502-' + a.instance) / 'gateway.env').read_text().splitlines()
                  if line and not line.startswith('#'))
    origin = 'http://127.0.0.1:' + ('18187' if a.instance == 'a' else '18188')
    def request(route, payload=None):
        # Never forward the gateway admin credential to the chain API.
        chain_query = route == PARAMS_ROUTE or route.startswith(ESCROW_ROUTE)
        base = 'http://127.0.0.1:1317' if chain_query else origin
        headers = {'Content-Type': 'application/json'}
        if not chain_query:
            headers['Authorization'] = 'Bearer ' + values['DEVSHARD_ADMIN_API_KEY']
        req = urllib.request.Request(base + route,
            data=None if payload is None else json.dumps(payload).encode(),
            headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                return {'status': response.status, 'result': json.load(response)}
        except urllib.error.HTTPError as error:
            return {'status': error.code, 'result': error.read().decode()}
    try:
        if a.reconcile_settled is not None:
            result = reconcile_settled(path, a.instance, request, a.reconcile_settled)
        else:
            result = tick(path, a.instance, request, a.amount, a.model)
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
