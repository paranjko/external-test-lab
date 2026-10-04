#!/usr/bin/env python3
"""Pure checkpoint-prefix and protocol-fee predicates, not runtime acceptance.

The caller must bind these manifests to actual retained storage under its lock
No unspecified nonce movement, ledger replacement or inference replay is allowed
"""

import hashlib
import json
import re
from contextlib import contextmanager
from pathlib import Path
import sqlite3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        require(offset < len(data), 'truncated ledger protobuf')
        byte = data[offset]
        offset += 1
        require(shift < 63 or byte < 2, 'ledger protobuf overflow')
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError('unterminated ledger protobuf')


def fields(data):
    require(isinstance(data, bytes) and len(data) <= 16 * 1024 * 1024,
            'bounded ledger protobuf required')
    offset = 0
    result = []
    while offset < len(data):
        tag, offset = varint(data, offset)
        number, wire = tag >> 3, tag & 7
        require(number > 0, 'invalid ledger protobuf field')
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire == 2:
            size, offset = varint(data, offset)
            require(size <= len(data) - offset, 'truncated ledger protobuf field')
            value = data[offset:offset + size]
            offset += size
        else:
            raise ValueError('unsupported ledger protobuf wire kind')
        result.append((number, wire, value))
    return result


def transaction_kinds(blob):
    wrapper = fields(blob)
    require(wrapper and all(number == 2 and wire == 2 for number, wire, value in wrapper),
            'qualified DiffContent transaction wrapper required')
    kinds = []
    for number, wire, value in wrapper:
        transaction = fields(value)
        require(len(transaction) == 1 and transaction[0][1] == 2,
                'exact DevshardTx oneof required')
        kinds.append(transaction[0][0])
    return kinds


def inference_events(blob):
    """Read start/terminal IDs, a successful HTTP reply need not flush Finish."""
    transaction_kinds(blob)  # Qualify the complete wrapper before projection
    result = []
    for number, wire, value in fields(blob):
        kind, _, payload = fields(value)[0]
        if kind in (1, 3, 4):
            ids = [item for field, encoding, item in fields(payload) if field == 1 and encoding == 0]
            require(len(ids) == 1 and type(ids[0]) is int and ids[0] > 0,
                    'exact retained inference identity required')
            result.append((kind, ids[0]))
    return result


def fingerprint(rows):
    # Preserve type boundaries without emitting blob or public-key contents
    return digest([[{'blob': value.hex()} if isinstance(value, bytes) else value
                    for value in row] for row in rows])


@contextmanager
def read_database(path):
    path = Path(path)
    require(path.is_file() and path.resolve(strict=True) == path,
            'existing nonsymlink ledger database required')
    connection = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=5)
    try:
        connection.execute('PRAGMA query_only=ON')
        connection.execute('BEGIN')
        yield connection
    finally:
        connection.close()


def collect(directory, identity, session):
    """Read only a caller-qualified SQLite session directory, never initialize it.

    PostgreSQL, missing state and symlink layouts are refused, not substituted
    The native caller must bind this directory to its actual retained volume
    """
    directory = Path(directory)
    require(isinstance(identity, str) and re.fullmatch('[1-9][0-9]*', identity),
            'exact ledger escrow identity required')
    require(directory.is_dir() and directory.resolve(strict=True) == directory,
            'qualified nonsymlink ledger directory required')
    require(not (directory / '.pg-bound').exists(), 'PostgreSQL-bound ledger is unsupported')
    with read_database(directory / '_meta.db') as meta:
        epochs = meta.execute('SELECT epoch_id FROM escrow_epoch WHERE escrow_id=?', (identity,)).fetchall()
        require(len(epochs) == 1 and type(epochs[0][0]) is int and epochs[0][0] > 0,
                'exact retained ledger epoch required')
        epoch = epochs[0][0]
        with read_database(directory / ('epoch_' + str(epoch) + '.db')) as database:
            records = database.execute('SELECT version,creator_addr,config_json,group_json,initial_balance,'
                                       'latest_nonce,last_finalized,status,settled_at FROM sessions '
                                       'WHERE escrow_id=?', (identity,)).fetchall()
            require(len(records) == 1, 'exact retained session required')
            version, creator, config, group, initial, nonce, finalized, status, settled = records[0]
            require(version == 'v5' and status == 'active' and settled is None,
                    'active official v5 ledger required')
            require(type(nonce) is int and 0 <= nonce <= 1000000, 'bounded ledger nonce required')
            parsed = json.loads(config)
            require(isinstance(parsed, dict), 'complete retained session config required')
            fee = parsed.get('FeePerNonce')
            require(type(fee) is int and fee >= 0, 'qualified retained nonce fee required')
            rows = database.execute('SELECT nonce,txs_proto,user_sig,post_state_root,state_hash FROM diffs '
                                    'WHERE escrow_id=? ORDER BY nonce', (identity,)).fetchall()
            require(len(rows) == nonce, 'complete retained diff prefix required')
            diffs = []
            open_inferences = set()
            started_inferences = set()
            for expected, row in enumerate(rows, 1):
                number, blob, signature, root, state_hash = row
                require(number == expected and isinstance(signature, bytes) and len(signature) == 65
                        and isinstance(root, bytes) and len(root) == 32
                        and isinstance(state_hash, bytes) and len(state_hash) == 32,
                        'complete retained signed diff required')
                for kind, inference in inference_events(blob):
                    if kind == 1:
                        require(inference not in started_inferences, 'duplicate retained inference start')
                        started_inferences.add(inference)
                        open_inferences.add(inference)
                    else:
                        require(inference in open_inferences, 'unbound retained inference terminal')
                        open_inferences.remove(inference)
                attestations = database.execute('SELECT slot_id,sig FROM signatures '
                    'WHERE escrow_id=? AND nonce=? ORDER BY slot_id', (identity, number)).fetchall()
                # Host attestations are collected per response, the release
                # can retain a user-signed diff without a host response
                # Preserve the exact observed set, never invent an attestation
                require(all(type(slot) is int and slot >= 0
                        and isinstance(sig, bytes) and len(sig) == 65 for slot, sig in attestations),
                        'invalid retained host attestation')
                diffs.append({'nonce': number, 'content_sha256': fingerprint([row]),
                              'attestations_sha256': fingerprint(attestations),
                              'host_attestation_count': len(attestations),
                              'tx_kinds': transaction_kinds(blob)})
            sealed = database.execute('SELECT * FROM sealed_inferences WHERE escrow_id=? '
                                      'ORDER BY inference_id', (identity,)).fetchall()
            manifest = {'schema': 'gdc-devshard-session-ledger/1', 'escrow_id': identity,
                        'version': version, 'epoch': epoch, 'latest_nonce': nonce, 'fee_per_nonce': fee,
                        'metadata_sha256': fingerprint([(version, creator, config, group, initial,
                                                         finalized, status, settled)]),
                        'open_inferences': sorted(open_inferences),
                        'sealed_inferences_sha256': fingerprint(sealed), 'diffs': diffs}
            validate(manifest, identity, session)
            return manifest


def validate(ledger, identity, session):
    require(isinstance(ledger, dict) and ledger.get('schema') == 'gdc-devshard-session-ledger/1',
            'qualified session ledger required')
    require(ledger.get('escrow_id') == identity and ledger.get('version') == session['session_version'] == 'v5',
            'session ledger identity or version differs')
    require(type(ledger.get('latest_nonce')) is int and ledger['latest_nonce'] == session['nonce'],
            'ledger and authenticated session nonce differ')
    require(type(ledger.get('epoch')) is int and ledger['epoch'] > 0,
            'exact retained epoch required')
    require(type(ledger.get('fee_per_nonce')) is int and ledger['fee_per_nonce'] >= 0,
            'qualified nonce fee required')
    pending = ledger.get('open_inferences')
    require(isinstance(pending, list) and all(type(value) is int and value > 0 for value in pending)
            and pending == sorted(set(pending)), 'complete retained inference closure required')
    for key in ('metadata_sha256', 'sealed_inferences_sha256'):
        require(isinstance(ledger.get(key), str) and re.fullmatch('[0-9a-f]{64}', ledger[key]),
                'complete retained ledger identity required')
    rows = ledger.get('diffs')
    require(isinstance(rows, list) and len(rows) == ledger['latest_nonce']
            and len(rows) <= 1000000, 'complete gapless diff prefix required')
    for nonce, row in enumerate(rows, 1):
        require(isinstance(row, dict) and type(row.get('nonce')) is int and row['nonce'] == nonce,
                'ledger diff ordering differs')
        for key in ('content_sha256', 'attestations_sha256'):
            require(isinstance(row.get(key), str) and re.fullmatch('[0-9a-f]{64}', row[key]),
                    'complete retained diff fingerprint required')
        kinds = row.get('tx_kinds')
        require(isinstance(kinds, list) and kinds and all(type(kind) is int and kind > 0 for kind in kinds),
                'qualified transaction kinds required')
        require(type(row.get('host_attestation_count')) is int and row['host_attestation_count'] >= 0,
                'exact observed attestation count required')


def confirm(drained, restarted, before_ledgers, after_ledgers):
    require(isinstance(drained, dict) and isinstance(restarted, dict)
            and isinstance(before_ledgers, dict) and isinstance(after_ledgers, dict),
            'complete drain and ledger checkpoints required')
    require(drained.get('settings') == restarted.get('settings'), 'retained settings changed')
    before, after = drained.get('escrows'), restarted.get('escrows')
    require(isinstance(before, dict) and before and isinstance(after, dict)
            and set(before) == set(after) == set(before_ledgers) == set(after_ledgers),
            'retained escrow inventory differs')
    extensions = {}
    for identity, original in before.items():
        restored = after[identity]
        require(original['persisted'] == restored['persisted'], 'persisted escrow changed')
        old_session, new_session = original['session'], restored['session']
        require(set(old_session) == set(new_session) == {'nonce', 'balance', 'session_version'},
                'complete session accounting required')
        for session in (old_session, new_session):
            require(type(session['nonce']) is int and session['nonce'] >= 0
                    and type(session['balance']) is int and session['balance'] >= 0,
                    'invalid session accounting')
        old, new = before_ledgers[identity], after_ledgers[identity]
        validate(old, identity, old_session)
        validate(new, identity, new_session)
        require(not old['open_inferences'] and not new['open_inferences'],
                'retained inference is not closed in the ledger')
        old_metadata = {key: value for key, value in old.items() if key not in ('diffs', 'latest_nonce')}
        new_metadata = {key: value for key, value in new.items() if key not in ('diffs', 'latest_nonce')}
        require(old_metadata == new_metadata, 'retained ledger metadata changed')
        checkpoint = old['latest_nonce']
        require(new['latest_nonce'] >= checkpoint and new['diffs'][:checkpoint] == old['diffs'],
                'retained diff prefix lost, rewritten or rewound')
        added = new['diffs'][checkpoint:]
        for row in added:
            # Release wire fields9 force turn,10 heartbeat,11 signed height ack
            require(set(row['tx_kinds']) <= {9, 10, 11} and set(row['tx_kinds']) & {10, 11},
                    'non-cadence transaction appeared while admission fenced')
        fee = len(added) * old['fee_per_nonce']
        require(old_session['balance'] - new_session['balance'] == fee,
                'balance movement is not exactly explained by retained cadence diffs')
        extensions[identity] = {'nonce_before': checkpoint, 'nonce_after': new['latest_nonce'],
                                'cadence_diffs': len(added), 'fee': fee}
    return {'schema': 'gdc-devshard-ledger-preservation/1', 'preserved': True,
            'checkpoint_sha256': digest(before_ledgers), 'after_sha256': digest(after_ledgers),
            'extensions': extensions}
