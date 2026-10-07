#!/usr/bin/env python3
"""Pure prefix negative controls, actual ledger acquisition is a separate gate."""

import copy
import importlib.util
from pathlib import Path
import unittest
import json
import sqlite3
import tempfile


spec = importlib.util.spec_from_file_location('ledger', Path(__file__).resolve().parents[1]
                                            / '04-ops/devshard-cache-ledger.py')
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)


class LedgerContracts(unittest.TestCase):
    def setUp(self):
        self.before = {'settings': {'unknown': 7}, 'escrows': {'42': {
            'persisted': {'id': '42', 'active': True, 'unknown': 9},
            'session': {'nonce': 2, 'balance': 10000, 'session_version': 'v5'}}}}
        self.after = copy.deepcopy(self.before)
        self.after['escrows']['42']['session'].update(nonce=4, balance=8000)
        self.old = {'42': {'schema': 'gdc-devshard-session-ledger/1', 'escrow_id': '42',
            'version': 'v5', 'epoch': 1, 'latest_nonce': 2, 'fee_per_nonce': 1000, 'open_inferences': [],
            'metadata_sha256': 'a' * 64, 'sealed_inferences_sha256': 'b' * 64,
            'diffs': [self.row(1, [1]), self.row(2, [2, 3])]}}
        self.new = copy.deepcopy(self.old)
        self.new['42'].update(latest_nonce=4)
        self.new['42']['diffs'] += [self.row(3, [9, 10]), self.row(4, [11])]

    def row(self, nonce, kinds):
        return {'nonce': nonce, 'content_sha256': str(nonce) * 64,
                'attestations_sha256': 'c' * 64, 'host_attestation_count': 1, 'tx_kinds': kinds}

    def confirm(self):
        return ledger.confirm(self.before, self.after, self.old, self.new)

    def test_exact_prefix_plus_retained_cadence_fees(self):
        receipt = self.confirm()
        self.assertTrue(receipt['preserved'])
        self.assertEqual(receipt['extensions']['42']['fee'], 2000)
        self.assertEqual(receipt['extensions']['42']['cadence_diffs'], 2)

    def test_no_extension_preserves_exact_accounting(self):
        self.after = copy.deepcopy(self.before)
        self.new = copy.deepcopy(self.old)
        self.assertEqual(self.confirm()['extensions']['42']['fee'], 0)

    def test_prefix_rewrite_signature_loss_or_unknown_metadata_refuse(self):
        for mutate in (
            lambda v: v['diffs'][0].update(content_sha256='f' * 64),
            lambda v: v['diffs'][0].update(attestations_sha256='f' * 64),
            lambda v: v['diffs'][0].update(host_attestation_count=0),
            lambda v: v.update(metadata_sha256='f' * 64),
            lambda v: v.update(sealed_inferences_sha256='f' * 64),
            lambda v: v.update(epoch=2),
            lambda v: v.update(unknown_new_metadata=True),
        ):
            saved = copy.deepcopy(self.new)
            mutate(self.new['42'])
            with self.assertRaises(ValueError):
                self.confirm()
            self.new = saved

    def test_rollback_gap_missing_evidence_and_stale_nonce_refuse(self):
        for mutate in (
            lambda v: v.update(latest_nonce=1),
            lambda v: v['diffs'].pop(1),
            lambda v: v['diffs'][2].update(nonce=5),
            lambda v: v['diffs'][2].pop('content_sha256'),
            lambda v: v.update(version='v4'),
            lambda v: v.update(fee_per_nonce=True),
        ):
            saved = copy.deepcopy(self.new)
            mutate(self.new['42'])
            with self.assertRaises(ValueError):
                self.confirm()
            self.new = saved

    def test_inference_or_unknown_extension_is_never_a_heartbeat(self):
        for kinds in ([1], [3], [9], [10, 14], [12], [True], []):
            self.new['42']['diffs'][2]['tx_kinds'] = kinds
            with self.assertRaises(ValueError):
                self.confirm()

    def test_any_unexplained_debit_credit_or_untyped_balance_refuses(self):
        for balance in (8001, 7999, 10001, True, '8000', -1):
            self.after['escrows']['42']['session']['balance'] = balance
            with self.assertRaises(ValueError):
                self.confirm()

    def test_settings_inventory_and_persisted_fields_cannot_drift(self):
        for mutate in (
            lambda v: v['settings'].update(unknown=8),
            lambda v: v['escrows']['42']['persisted'].update(unknown=10),
            lambda v: v.update(escrows={}),
        ):
            saved = copy.deepcopy(self.after)
            mutate(self.after)
            with self.assertRaises(ValueError):
                self.confirm()
            self.after = saved

    def test_unclosed_or_untyped_inference_evidence_never_proves_preservation(self):
        for value in ([2], [True], [2, 1], [1, 1], None):
            self.old['42']['open_inferences'] = value
            with self.assertRaises(ValueError):
                self.confirm()


class SQLiteCollectorContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        with sqlite3.connect(self.directory / '_meta.db') as database:
            database.execute('CREATE TABLE escrow_epoch(escrow_id TEXT,epoch_id INTEGER)')
            database.execute('INSERT INTO escrow_epoch VALUES(?,?)', ('42', 1))
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('CREATE TABLE sessions(escrow_id TEXT,version TEXT,creator_addr TEXT,'
                             'config_json TEXT,group_json TEXT,initial_balance INTEGER,latest_nonce INTEGER,'
                             'last_finalized INTEGER,status TEXT,settled_at INTEGER)')
            database.execute('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?)',
                             ('42', 'v5', 'synthetic-public-address', json.dumps({'FeePerNonce': 1000}),
                              '[]', 10000, 2, 0, 'active', None))
            database.execute('CREATE TABLE diffs(escrow_id TEXT,nonce INTEGER,txs_proto BLOB,user_sig BLOB,'
                             'post_state_root BLOB,state_hash BLOB)')
            for nonce, blob in ((1, b'\x12\x04\x0a\x02\x08\x01'),
                                (2, b'\x12\x04\x1a\x02\x08\x01')):
                database.execute('INSERT INTO diffs VALUES(?,?,?,?,?,?)',
                                 ('42', nonce, blob, b'u' * 65, b'r' * 32, b'h' * 32))
            database.execute('CREATE TABLE signatures(escrow_id TEXT,nonce INTEGER,slot_id INTEGER,sig BLOB)')
            database.execute('INSERT INTO signatures VALUES(?,?,?,?)', ('42', 1, 0, b's' * 65))
            database.execute('CREATE TABLE sealed_inferences(escrow_id TEXT,inference_id INTEGER)')
        self.session = {'nonce': 2, 'balance': 8000, 'session_version': 'v5'}

    def collect(self):
        return ledger.collect(self.directory, '42', self.session)

    def test_actual_sqlite_reads_do_not_modify_database_or_invent_attestations(self):
        original = {path.name: path.read_bytes() for path in self.directory.iterdir()}
        manifest = self.collect()
        self.assertEqual(manifest['latest_nonce'], 2)
        self.assertEqual(manifest['open_inferences'], [])
        self.assertEqual([row['host_attestation_count'] for row in manifest['diffs']], [1, 0])
        self.assertEqual([row['tx_kinds'] for row in manifest['diffs']], [[1], [3]])
        self.assertEqual({path.name: path.read_bytes() for path in self.directory.iterdir()}, original)
        self.assertNotIn('synthetic-public-address', json.dumps(manifest))

    def test_missing_file_and_symlink_never_initialize_or_follow_another_store(self):
        path = self.directory / '_meta.db'
        saved = self.directory / 'retained.db'
        path.rename(saved)
        with self.assertRaises(ValueError):
            self.collect()
        self.assertFalse(path.exists())
        path.symlink_to(saved)
        with self.assertRaises(ValueError):
            self.collect()

    def test_postgres_scope_and_stale_authenticated_nonce_refuse(self):
        self.session['nonce'] = 3
        with self.assertRaisesRegex(ValueError, 'nonce differ'):
            self.collect()
        self.session['nonce'] = 2
        (self.directory / '.pg-bound').touch()
        with self.assertRaisesRegex(ValueError, 'PostgreSQL'):
            self.collect()

    def test_gap_corrupt_signature_and_schema_loss_refuse(self):
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('UPDATE diffs SET user_sig=? WHERE nonce=2', (b'incomplete',))
        with self.assertRaisesRegex(ValueError, 'signed diff'):
            self.collect()
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('DELETE FROM diffs WHERE nonce=2')
        with self.assertRaisesRegex(ValueError, 'prefix'):
            self.collect()

    def test_protobuf_unknown_wrapper_truncation_and_duplicate_oneof_refuse(self):
        for blob in (b'\x12', b'\x12\x05\x52\x00', b'\x00', b'\x12\x04\x52\x00\x5a\x00',
                     b'\x1a\x02\x52\x00'):
            with self.assertRaises(ValueError):
                ledger.transaction_kinds(blob)

    def test_database_context_is_query_only(self):
        with ledger.read_database(self.directory / '_meta.db') as database:
            with self.assertRaises(sqlite3.OperationalError):
                database.execute('DELETE FROM escrow_epoch')

    def test_ambiguous_epoch_mapping_refuses(self):
        with sqlite3.connect(self.directory / '_meta.db') as database:
            database.execute('INSERT INTO escrow_epoch VALUES(?,?)', ('42', 2))
        with self.assertRaisesRegex(ValueError, 'epoch'):
            self.collect()

    def test_actual_pending_inference_is_not_hidden_by_zero_request_counters(self):
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('UPDATE diffs SET txs_proto=? WHERE nonce=2',
                             (b'\x12\x02\x52\x00',))
        self.assertEqual(self.collect()['open_inferences'], [1])

    def test_inactive_storage_preserves_every_table_and_unknown_file(self):
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('CREATE TABLE retained_unknown(value BLOB)')
            database.execute('INSERT INTO retained_unknown VALUES(?)', (b'private-retained-content',))
        (self.directory / 'retained.snapshot').write_bytes(b'private-retained-snapshot')
        original = {path.name: path.read_bytes() for path in self.directory.iterdir()}
        manifest = ledger.collect(self.directory, '42', None)
        self.assertEqual(manifest['schema'], 'gdc-devshard-inactive-storage/1')
        self.assertEqual(manifest['files']['epoch_1.db']['tables']['retained_unknown']['rows'], 1)
        self.assertEqual(set(manifest['files']), set(original))
        self.assertNotIn('private-retained', json.dumps(manifest))
        self.assertNotIn('latest_nonce', manifest)
        self.assertEqual({path.name: path.read_bytes() for path in self.directory.iterdir()}, original)
        checkpoint = {'settings': {}, 'escrows': {'42': {'persisted': {'id': '42', 'active': False},
                                                       'session': None}}}
        ledgers = {'42': manifest}
        self.assertTrue(ledger.confirm(checkpoint, checkpoint, ledgers, ledgers)['preserved'])
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('UPDATE retained_unknown SET value=?', (b'changed',))
        changed = {'42': ledger.collect(self.directory, '42', None)}
        with self.assertRaisesRegex(ValueError, 'inactive retained storage changed'):
            ledger.confirm(checkpoint, checkpoint, ledgers, changed)

    def test_inactive_missing_epoch_symlink_and_reactivation_refuse(self):
        manifest = ledger.collect(self.directory, '42', None)
        checkpoint = {'settings': {}, 'escrows': {'42': {'persisted': {'id': '42', 'active': False},
                                                       'session': None}}}
        restored = copy.deepcopy(checkpoint)
        restored['escrows']['42']['session'] = self.session
        with self.assertRaisesRegex(ValueError, 'inactive runtime binding changed'):
            ledger.confirm(checkpoint, restored, {'42': manifest}, {'42': manifest})
        epoch = self.directory / 'epoch_1.db'
        saved = self.directory / 'saved.db'
        epoch.rename(saved)
        with self.assertRaisesRegex(ValueError, 'epoch files'):
            ledger.collect(self.directory, '42', None)
        epoch.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, 'nonsymlink'):
            ledger.collect(self.directory, '42', None)

    def test_inactive_logical_fingerprint_survives_wal_checkpoint_without_losing_rows(self):
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('PRAGMA journal_mode=WAL')
            database.execute('PRAGMA wal_autocheckpoint=0')
            database.execute('CREATE TABLE history(value BLOB)')
            database.executemany('INSERT INTO history VALUES(?)', [(b'first',), (b'first',), (b'second',)])
            database.commit()
            before = ledger.collect(self.directory, '42', None)
            self.assertEqual(before['files']['epoch_1.db']['tables']['history']['rows'], 3)
            database.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            self.assertEqual(ledger.collect(self.directory, '42', None), before)
            database.execute('DELETE FROM history WHERE rowid=1')
            database.commit()
            self.assertNotEqual(ledger.collect(self.directory, '42', None), before)

    def test_inactive_incomplete_or_untyped_manifest_is_not_preservation_evidence(self):
        original = ledger.collect(self.directory, '42', None)
        for mutate in (
            lambda value: value['files'].pop('epoch_1.db'),
            lambda value: value['files']['_meta.db'].pop('schema_sha256'),
            lambda value: value['files']['_meta.db']['tables']['escrow_epoch'].update(rows=True),
            lambda value: value['files']['_meta.db']['tables']['escrow_epoch'].update(sha256='not-a-hash'),
        ):
            manifest = copy.deepcopy(original)
            mutate(manifest)
            with self.assertRaises(ValueError):
                ledger.validate(manifest, '42', None)

    def test_closed_wal_store_allows_reader_sidecars_but_preserves_logical_inventory(self):
        for name in ('_meta.db', 'epoch_1.db'):
            database = sqlite3.connect(self.directory / name)
            database.execute('PRAGMA journal_mode=WAL')
            database.close()
        self.assertEqual({path.name for path in self.directory.iterdir()}, {'_meta.db', 'epoch_1.db'})
        first = ledger.collect(self.directory, '42', None)
        self.assertEqual(set(first['files']), {'_meta.db', 'epoch_1.db'})
        self.assertEqual(ledger.collect(self.directory, '42', None), first)

    def test_inactive_implicit_row_identity_is_preserved_not_only_column_values(self):
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('CREATE TABLE historical_events(payload TEXT)')
            database.execute('INSERT INTO historical_events(rowid,payload) VALUES(11,?)', ('retained',))
        before = ledger.collect(self.directory, '42', None)
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('UPDATE historical_events SET rowid=22')
        self.assertNotEqual(ledger.collect(self.directory, '42', None), before)

    def test_inactive_without_rowid_and_shadowed_alias_keep_exact_identity(self):
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('CREATE TABLE keyed_history(id TEXT PRIMARY KEY,payload BLOB) WITHOUT ROWID')
            database.execute('INSERT INTO keyed_history VALUES(?,?)', ('one', b'retained'))
            database.execute('CREATE TABLE shadowed_history(_rowid_ TEXT,payload BLOB)')
            database.execute('INSERT INTO shadowed_history(rowid,_rowid_,payload) VALUES(11,?,?)',
                             ('shadow', b'retained'))
        before = ledger.collect(self.directory, '42', None)
        self.assertEqual(before, ledger.collect(self.directory, '42', None))
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('UPDATE shadowed_history SET rowid=22')
        self.assertNotEqual(before, ledger.collect(self.directory, '42', None))
        with sqlite3.connect(self.directory / 'epoch_1.db') as database:
            database.execute('UPDATE keyed_history SET id=?', ('two',))
        self.assertNotEqual(before, ledger.collect(self.directory, '42', None))

    def test_missing_duplicate_or_unbound_inference_identity_refuses(self):
        for blob in (b'\x12\x02\x1a\x00', b'\x12\x04\x1a\x02\x08\x02',
                     b'\x12\x04\x0a\x02\x08\x01'):
            with sqlite3.connect(self.directory / 'epoch_1.db') as database:
                database.execute('UPDATE diffs SET txs_proto=? WHERE nonce=2', (blob,))
            with self.assertRaises(ValueError):
                self.collect()


if __name__ == '__main__':
    unittest.main()
