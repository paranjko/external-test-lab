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


def collect_inactive(directory, identity):
    """Fingerprint every retained SQLite table without inventing runtime state."""
    directory = Path(directory)
    require(isinstance(identity, str) and re.fullmatch('[1-9][0-9]*', identity),
            'exact inactive escrow identity required')
    require(directory.is_dir() and directory.resolve(strict=True) == directory,
            'qualified nonsymlink inactive directory required')
    require(not (directory / '.pg-bound').exists(), 'PostgreSQL-bound ledger is unsupported')
    paths = sorted(directory.iterdir())
    require(all(path.is_file() and path.resolve(strict=True) == path for path in paths),
            'complete nonsymlink inactive file inventory required')
    databases = {path.name for path in paths if path.suffix == '.db'}
    def logical_paths(values):
        require(all(path.is_file() and path.resolve(strict=True) == path for path in values),
                'complete nonsymlink inactive file inventory required')
        return [path for path in values if not any(path.name == name + suffix
                for name in databases for suffix in ('-wal', '-shm', '-journal'))]
    require('_meta.db' in databases, 'existing inactive metadata database required')
    with read_database(directory / '_meta.db') as meta:
        epochs = meta.execute('SELECT epoch_id FROM escrow_epoch WHERE escrow_id=?', (identity,)).fetchall()
        require(bool(epochs) and all(type(epoch) is int and epoch > 0 for (epoch,) in epochs)
                and len(set(epochs)) == len(epochs), 'complete inactive epoch binding required')
    require(all('epoch_' + str(epoch) + '.db' in databases for (epoch,) in epochs),
            'complete inactive epoch files required')
    files = {}
    for path in paths:
        if any(path.name == name + suffix for name in databases for suffix in ('-wal', '-shm', '-journal')):
            # SQLite's read transaction includes committed WAL contents
            # Physical checkpoint layout is not logical historical evidence
            continue
        if path.name in databases:
            with read_database(path) as database:
                schema = database.execute('SELECT type,name,tbl_name,sql FROM sqlite_schema '
                                          'ORDER BY type,name').fetchall()
                tables = {}
                for kind, name, _, sql in schema:
                    if kind != 'table':
                        continue
                    require(not sql or 'VIRTUAL TABLE' not in sql.upper(),
                            'virtual inactive storage tables are unsupported')
                    table = '"' + name.replace('"', '""') + '"'
                    cursor = database.execute('SELECT * FROM ' + table + ' LIMIT 0')
                    columns = {column[0].lower() for column in cursor.description}
                    alias = next((value for value in ('_rowid_', 'rowid', 'oid') if value not in columns), None)
                    require(alias is not None, 'unambiguous inactive row identity required')
                    try:
                        cursor = database.execute('SELECT retained_rows.' + alias + ',retained_rows.* FROM '
                                                  + table + ' AS retained_rows')
                    except sqlite3.OperationalError as error:
                        # WITHOUT ROWID tables have only their declared primary key
                        # Refuse every other acquisition failure, never omit identity
                        require(str(error) == 'no such column: retained_rows.' + alias,
                                'inactive row identity query failed')
                        cursor = database.execute('SELECT * FROM ' + table)
                    rows = cursor.fetchmany(1000001)
                    require(len(rows) <= 1000000, 'bounded complete inactive table required')
                    # Hash typed rows independently, then sort to preserve duplicates
                    tables[name] = {'rows': len(rows), 'sha256': digest(sorted(fingerprint([row]) for row in rows))}
                files[path.name] = {'schema_sha256': fingerprint(schema), 'tables': tables}
        else:
            with path.open('rb') as stream:
                fingerprint_hash = hashlib.sha256()
                for block in iter(lambda: stream.read(1048576), b''):
                    fingerprint_hash.update(block)
            files[path.name] = {'sha256': fingerprint_hash.hexdigest()}
    # Read-only WAL readers may create shared-memory sidecars for closed stores
    # Retain logical inventory exactly, permit only qualified SQLite sidecars
    require(logical_paths(sorted(directory.iterdir())) == logical_paths(paths),
            'inactive file inventory changed during observation')
    return {'schema': 'gdc-devshard-inactive-storage/1', 'escrow_id': identity,
            'files': files}


def collect(directory, identity, session):
    """Read only a caller-qualified SQLite session directory, never initialize it.

    PostgreSQL, missing state and symlink layouts are refused, not substituted
    The native caller must bind this directory to its actual retained volume
    """
    if session is None:
        return collect_inactive(directory, identity)
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
    if session is None:
        require(isinstance(ledger, dict) and ledger.get('schema') == 'gdc-devshard-inactive-storage/1'
                and ledger.get('escrow_id') == identity and isinstance(ledger.get('files'), dict)
                and '_meta.db' in ledger['files'], 'complete inactive storage manifest required')
        require(any(re.fullmatch(r'epoch_[1-9][0-9]*\.db', name) for name in ledger['files']),
                'inactive epoch inventory required')
        for name, content in ledger['files'].items():
            require(isinstance(name, str) and name not in ('.', '..') and '/' not in name
                    and isinstance(content, dict), 'invalid inactive file identity')
            if name.endswith('.db'):
                require(isinstance(content.get('schema_sha256'), str)
                        and re.fullmatch('[0-9a-f]{64}', content['schema_sha256'])
                        and isinstance(content.get('tables'), dict), 'complete inactive database manifest required')
                for table, rows in content['tables'].items():
                    require(isinstance(table, str) and bool(table) and isinstance(rows, dict)
                            and type(rows.get('rows')) is int and 0 <= rows['rows'] <= 1000000
                            and isinstance(rows.get('sha256'), str)
                            and re.fullmatch('[0-9a-f]{64}', rows['sha256']),
                            'complete inactive table fingerprint required')
            else:
                require(isinstance(content.get('sha256'), str)
                        and re.fullmatch('[0-9a-f]{64}', content['sha256']),
                        'complete inactive file fingerprint required')
        return
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
        if old_session is None or new_session is None:
            require(old_session is None and new_session is None
                    and original['persisted'].get('active') is False,
                    'inactive runtime binding changed')
            old, new = before_ledgers[identity], after_ledgers[identity]
            validate(old, identity, None)
            validate(new, identity, None)
            require(old == new, 'inactive retained storage changed')
            extensions[identity] = {'inactive_storage_preserved': True}
            continue
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
