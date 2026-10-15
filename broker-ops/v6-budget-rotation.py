#!/usr/bin/env python3
"""Operator rotation with durable gross-funding caps; not native qualification."""
import argparse
import fcntl
import json
import math
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
EFFECTIVE_EPOCH_ROUTE = '/productscience/inference/inference/current_epoch_group_data'


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


def reconciled_epochs(db, rows, table='reconciliation'):
    if table not in ('reconciliation', 'deferred_pruned'):
        raise ValueError('invalid disposition table')
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
        return set()
    known = {row[0]: (row[1], row[3]) for row in rows}
    result = set()
    for epoch, amount, escrow in db.execute('SELECT epoch,amount,escrow FROM ' + table):
        if known.get(epoch) != (amount, escrow):
            raise ValueError('reconciliation binding mismatch')
        result.add(epoch)
    return result


def reconcile_settled(path, instance, request, escrow_id, defer_pruned=False):
    """Append settlement proof or explicit reserved-debit deferral; no transaction."""
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
            if defer_pruned:
                if chain['status'] != 200 or chain['result'].get('found') is not False:
                    return 'halt: explicit absent chain observation required'
                debug = request('/v1/debug/rotation')
                if debug['status'] != 200 or int(debug['result']['chain']['epoch_index']) < epoch + 2:
                    return 'halt: stale funding epoch required'
            elif chain['status'] != 200 or chain['result'].get('found') is not True:
                return 'halt: absent escrow is not settlement proof'
            if not defer_pruned:
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
            if defer_pruned:
                # Explicit operational disposition, NOT settlement/refund proof.
                # Keep original failures and the full gross debit indefinitely.
                db.execute('''CREATE TABLE IF NOT EXISTS deferred_pruned(
                    epoch INTEGER PRIMARY KEY, amount INTEGER NOT NULL,
                    escrow TEXT NOT NULL, observed_at INTEGER NOT NULL, proof TEXT NOT NULL)''')
                previous = db.execute('SELECT amount,escrow FROM deferred_pruned WHERE epoch=?', (epoch,)).fetchone()
                if previous is not None:
                    if previous != (amount, escrow_id):
                        raise ValueError('deferred reservation binding mismatch')
                    return 'deferred: reservation already retained'
                proof = {'chain': chain, 'runtime': {'id': escrow_id, 'active': False},
                         'current_epoch': debug['result']['chain']['epoch_index'],
                         'disposition': 'no-retry; gross debit retained; settlement unknown'}
                db.execute('INSERT INTO deferred_pruned VALUES (?,?,?,?,?)',
                           (epoch, amount, escrow_id, int(time.time()), json.dumps(proof)))
                db.commit()
                return 'deferred: no transaction retry; gross reservation unchanged'
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


def deactivate_pruned(path, instance, request, escrow_id, receipt, run=subprocess.run):
    """Close admission only for a proven stale, chain-absent known escrow."""
    escrow_id = str(positive_integer(escrow_id))
    timer = run(['systemctl', 'show', 'gdc-v6-budget-' + instance + '.timer',
                 '--property=ActiveState', '--value'], check=True, capture_output=True,
                text=True).stdout.strip()
    if timer != 'inactive':
        raise ValueError('pause campaign timer before recovery')
    with (path / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with sqlite3.connect((path / 'ledger.sqlite').as_uri() + '?mode=ro', uri=True) as db:
            if db.execute('SELECT * FROM binding').fetchall() != [(instance, CAP)]:
                raise ValueError('campaign binding mismatch')
            rows = db.execute('SELECT epoch,amount,result FROM funding WHERE escrow=?', (escrow_id,)).fetchall()
        if len(rows) != 1 or rows[0][2] is None or not 200 <= json.loads(rows[0][2])['status'] < 300:
            raise ValueError('one confirmed funding record required')
        def absent():
            chain = request(ESCROW_ROUTE + escrow_id)
            return chain.get('status') == 200 and chain.get('result', {}).get('found') is False
        debug = request('/v1/debug/rotation')
        if (debug.get('status') != 200 or
            int(debug['result']['chain']['epoch_index']) < rows[0][0] + 2 or not absent()):
            raise ValueError('stale epoch and explicit chain absence required')
        settings = request('/v1/admin/settings')
        if settings.get('status') != 200 or settings['result']['escrow_rotation']['enabled'] is not False:
            raise ValueError('native rotation must be disabled')
        participants = request('/v1/admin/devshards/' + escrow_id + '/participants')
        view = participants.get('result', {})
        if (participants.get('status') != 200 or str(view.get('id')) != escrow_id or
            type(view.get('active_requests')) is not int or view['active_requests'] != 0 or not absent()):
            raise ValueError('matching idle runtime and fresh chain absence required')
        with open(receipt, 'x', opener=lambda p, f: os.open(p, f, 0o600)) as stream:
            json.dump({'instance': instance, 'escrow': escrow_id, 'epoch': rows[0][0],
                       'amount': rows[0][1], 'before': view, 'chain_absent': True,
                       'action': 'deactivate only; settlement unknown'}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        result = request('/v1/admin/devshards/' + escrow_id + '/deactivate', {})
        if result.get('status') != 200 or result.get('result', {}).get('active') is not False:
            raise ValueError('deactivation outcome requires readback')
        state = request('/v1/admin/state')
        matches = [row for row in state.get('result', {}).get('devshards', []) if str(row.get('id')) == escrow_id]
        if state.get('status') != 200 or len(matches) != 1 or matches[0].get('active') is not False:
            raise ValueError('inactive readback required')
        return 'deactivated: no settlement or funding; reconcile separately with --defer-pruned'


def settlement_window(chain):
    return (chain.get('phase') == 'Inference' and
            chain.get('confirmation_poc_phase', '') in
            ('', 'CONFIRMATION_POC_INACTIVE', 'CONFIRMATION_POC_COMPLETED') and
            type(chain.get('blocks_to_epoch_switch')) is int and
            chain['blocks_to_epoch_switch'] >= 15)


def chain_epoch_matches(request, row):
    observed = request(ESCROW_ROUTE + str(row[3]))
    if observed.get('status') != 200 or not isinstance(observed.get('result'), dict):
        return False
    data = observed['result']
    escrow = data.get('escrow') or {}
    try:
        return (data.get('found') is True and escrow.get('settled') is False and
                str(escrow.get('id')) == str(row[3]) and
                positive_integer(escrow.get('amount')) == row[1] and
                positive_integer(escrow.get('epoch_index')) == row[0])
    except (ValueError, TypeError):
        return False


def replacement_ready(request, replacement, retiring, model):
    """Read-only evidence for a different, individually usable funded runtime."""
    def positive(value):
        return type(value) in (int, float) and math.isfinite(value) and value > 0
    state = request('/v1/admin/state')
    if state.get('status') != 200 or not isinstance(state.get('result'), dict):
        return False
    state = state['result']
    identity = str(replacement[3])
    if identity == str(retiring[3]):
        return False
    matches = [item for item in state.get('devshards', []) if str(item.get('id')) == identity]
    if len(matches) != 1:
        return False
    item = matches[0]
    rt = item.get('runtime') or {}
    if (item.get('active') is not True or item.get('model') != model or
        str(rt.get('id')) != identity or rt.get('model') != model or
        rt.get('active') is not True or rt.get('requests_blocked') is not False or
        rt.get('on_hold') is not False or not positive(rt.get('balance'))):
        return False
    capacity = state.get('capacity', {})
    if not positive(capacity.get('escrow_weights', {}).get(identity)):
        return False
    model_capacity = capacity.get('models', {}).get(model, {})
    if model_capacity.get('routable') is not True or not positive(model_capacity.get('current_weight')):
        return False
    limits = state.get('limiter', {}).get('models', {}).get(model, {})
    baseline_tokens = limits.get('max_input_tokens_in_flight')
    effective_tokens = limits.get('effective_max_input_tokens_in_flight')
    # Frozen gateway_limiter.go AcquireModel enforces token caps only when
    # the configured baseline is positive. Explicit 0/0 means unlimited,
    # unlike a positive baseline scaled to zero. Missing/malformed is unknown.
    tokens_ready = (type(baseline_tokens) is int and type(effective_tokens) is int and
                    ((baseline_tokens == 0 and effective_tokens == 0) or
                     (baseline_tokens > 0 and effective_tokens > 0)))
    if not positive(limits.get('effective_max_concurrent_requests')) or not tokens_ready:
        return False
    return all(chain_epoch_matches(request, row) for row in (replacement, retiring))


def tick(path, instance, request, amount=AMOUNT, model=MODEL, settle_after_replacement=False):
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
            reconciled |= reconciled_epochs(db, rows, 'deferred_pruned')
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
            if settle_after_replacement:
                # Historical ledger epochs are reservation keys, not necessarily
                # chain creation epochs. Never silently relabel those records.
                for row in rows:
                    if not row[4] and row[0] not in reconciled and not chain_epoch_matches(request, row):
                        return 'halt: escrow chain epoch or identity requires reconciliation'
            replacements = [row for row in rows if row[0] == epoch and not row[4]]
            # The opt-in handover retires age1 only after a funded replacement is
            # independently usable. The legacy schedule stays unchanged by default.
            for retiring in rows:
                old, _, _, escrow, settled = retiring
                if settled or old in reconciled or old > epoch - (1 if settle_after_replacement else 2):
                    continue
                attempts = db.execute('SELECT result FROM settlement WHERE epoch=?', (old,)).fetchall()
                if any(json.loads(r[0])['status'] != 409 for r in attempts):
                    return 'halt: settlement failure needs reconciliation'
                if len(attempts) >= 3:
                    # Known-busy escrows remain for manual reconciliation. They
                    # must not interrupt funding of unrelated healthy epochs.
                    continue
                if settle_after_replacement:
                    if old < epoch - 1:
                        return 'halt: stale escrow requires explicit reconciliation'
                    if not replacements:
                        # Creation below must remain reachable; never retire the
                        # old runtime before its replacement has been funded.
                        continue
                    if not settlement_window(chain) or not replacement_ready(request, replacements[0], retiring, model):
                        return 'waiting: replacement settlement prerequisites unavailable'
                    fresh = request('/v1/debug/rotation')
                    observed = fresh.get('result', {}).get('chain', {})
                    if fresh.get('status') != 200 or observed.get('epoch_index') != epoch or not settlement_window(observed):
                        return 'waiting: settlement epoch or protocol window changed'
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
            if settle_after_replacement:
                effective = request(EFFECTIVE_EPOCH_ROUTE)
                if effective.get('status') != 200:
                    return 'halt: effective chain epoch unavailable'
                try:
                    effective_epoch = positive_integer(effective['result']['epoch_group_data']['epoch_index'])
                except (KeyError, TypeError, ValueError):
                    return 'halt: effective chain epoch unavailable'
                if effective_epoch != epoch:
                    return 'waiting: latest and effective epochs differ'
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
            if settle_after_replacement and not chain_epoch_matches(request, (epoch, amount, None, escrow, 0)):
                # The successful creation and full debit remain durable. Subsequent
                # ticks only re-read this binding; they never repeat the POST.
                return 'halt: created escrow chain epoch or identity requires reconciliation'
            return 'created: reserved_units=' + str(reserved + amount)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('instance', choices=['a', 'b'])
    p.add_argument('--initialize', action='store_true')
    p.add_argument('--reconcile-settled', metavar='ESCROW_ID', type=positive_integer,
                   help='append chain-confirmed settlement proof; no transactions or funding')
    p.add_argument('--defer-pruned', metavar='ESCROW_ID', type=positive_integer,
                   help='explicitly retain stale absent/inactive escrow debit without retry or settlement claim')
    p.add_argument('--deactivate-pruned', metavar='ESCROW_ID', type=positive_integer,
                   help='close admission for a known stale chain-absent idle runtime; no settlement')
    p.add_argument('--receipt', type=Path, help='new private receipt required for --deactivate-pruned')
    p.add_argument('--amount', type=positive_integer, help='escrow amount in integer chain units')
    p.add_argument('--model', help='explicit admitted model ID')
    p.add_argument('--settle-after-replacement', action='store_true',
                   help='retire age1 escrow only after verified current-epoch replacement; opt-in')
    a = p.parse_args()
    if a.deactivate_pruned is not None:
        if a.initialize or a.reconcile_settled is not None or a.defer_pruned is not None or a.receipt is None:
            p.error('deactivation must be standalone and requires --receipt')
    elif a.receipt is not None:
        p.error('--receipt is only valid with --deactivate-pruned')
    if a.defer_pruned is not None and (a.initialize or a.reconcile_settled is not None):
        p.error('deferred disposition must be a standalone operation')
    os.umask(0o077)
    root = Path('/srv/dai/broker-tests')
    path = root / ('v6-' + a.instance) / 'rotation-10000gnk-20261013'
    if a.initialize:
        if a.reconcile_settled is not None:
            p.error('initialization and reconciliation are mutually exclusive')
        initialize(path, a.instance)
        return
    if a.reconcile_settled is None and a.defer_pruned is None and a.deactivate_pruned is None and (a.amount is None or not a.model or not a.model.strip()):
        p.error('--amount and --model are required; old service configuration must not silently resume')
    values = dict(line.split('=', 1) for line in (root / ('ds502-' + a.instance) / 'gateway.env').read_text().splitlines()
                  if line and not line.startswith('#'))
    origin = 'http://127.0.0.1:' + ('18187' if a.instance == 'a' else '18188')
    def request(route, payload=None):
        # Never forward the gateway admin credential to the chain API.
        chain_query = route in (PARAMS_ROUTE, EFFECTIVE_EPOCH_ROUTE) or route.startswith(ESCROW_ROUTE)
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
        if a.deactivate_pruned is not None:
            result = deactivate_pruned(path, a.instance, request, a.deactivate_pruned, a.receipt)
        elif a.defer_pruned is not None:
            result = reconcile_settled(path, a.instance, request, a.defer_pruned, defer_pruned=True)
        elif a.reconcile_settled is not None:
            result = reconcile_settled(path, a.instance, request, a.reconcile_settled)
        else:
            options = {'settle_after_replacement': True} if a.settle_after_replacement else {}
            result = tick(path, a.instance, request, a.amount, a.model, **options)
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
