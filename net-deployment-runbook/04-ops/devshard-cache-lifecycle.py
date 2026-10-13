#!/usr/bin/env python3
"""Journalled cache-only lifecycle sequencing, requiring a qualified adapter.

No live transport or command-line apply is exposed by this module
The adapter must hold the instance lock and verify actual runtime bindings
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import time


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


policy = module('cache_policy', 'devshard-cache-policy.py')
drain = module('cache_drain', 'devshard-cache-drain.py')
ledger = module('cache_ledger', 'devshard-cache-ledger.py')
require = drain.require


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def settings_views(effective, persisted):
    """Qualify complete views, allowing only the release's nonstored ChainGRPC.

    GatewayStore LoadState/UpdateSettings omit ChainGRPC, while the settings
    endpoint exposes the effective runtime value, keep both views intact
    """
    require(isinstance(effective, dict) and isinstance(persisted, dict),
            'complete effective and persisted settings required')
    if effective == persisted:
        return
    projection = dict(effective)
    endpoint = projection.pop('chain_grpc', None)
    require(isinstance(endpoint, str) and bool(endpoint.strip())
            and 'chain_grpc' not in persisted and projection == persisted,
            'effective and persisted settings differ outside runtime chain_grpc')


def perform(adapter, journal, identity, expected_compose, expected_settings,
            timeout=120, clock=time.monotonic, wait=time.sleep):
    require(type(timeout) in (int, float) and 1 <= timeout <= 900, 'invalid drain deadline')
    original_bytes = adapter.read_compose()
    preview, desired_bytes = policy.preview(original_bytes, identity, expected_compose)
    require(preview['delta'], 'unchanged cache policy, refuse lifecycle mutation')
    original_settings = adapter.read_settings()
    require(digest(original_settings) == expected_settings, 'settings preimage changed')
    original_state = adapter.read_state()
    require(isinstance(original_state, dict), 'complete initial admin state required')
    original_persisted = original_state.get('settings')
    settings_views(original_settings, original_persisted)
    fenced = drain.fenced_settings(original_settings)
    persisted_fenced = drain.fenced_settings(original_persisted)
    adapter.verify_runtime(identity, preview['image'], preview['state_volume'])
    adapter.qualify_storage(original_state)
    journal.record('prepared', {'identity': identity, 'compose_before': expected_compose,
                               'compose_desired': preview['desired_sha256'],
                               'settings_before': expected_settings, 'settings_fenced': digest(fenced),
                               'original_settings': original_settings,
                               'original_persisted_settings': original_persisted})
    def read_fenced_state():
        # Bracket each persisted-state sample with fresh effective reads
        require(adapter.read_settings() == fenced, 'effective settings drift during drain')
        state = adapter.read_state()
        require(isinstance(state, dict) and state.get('settings') == persisted_fenced,
                'persisted settings drift during drain')
        require(adapter.read_settings() == fenced, 'effective settings drift during drain')
        return state
    def qualify_closed(checkpoint):
        manifests = adapter.read_ledgers(checkpoint)
        require(set(manifests) == set(checkpoint['escrows']), 'complete drain ledger inventory required')
        pending = False
        for escrow, row in checkpoint['escrows'].items():
            ledger.validate(manifests[escrow], escrow, row['session'])
            if row['session'] is not None:
                pending = pending or bool(manifests[escrow]['open_inferences'])
        if pending:
            raise drain.Busy('retained inference still awaits its protocol terminal')
    # A dispatch record must be durable before any corresponding mutation
    try:
        journal.record('fence-dispatch', {'settings_before': expected_settings})
        adapter.replace_settings(original_settings, fenced)
        require(adapter.read_settings() == fenced, 'admission fence readback mismatch')
        drain_deadline = clock() + timeout
        quiet = drain.wait_drained(read_fenced_state, drain_deadline, clock=clock, wait=wait,
                                   qualify=qualify_closed)
        before_ledgers = adapter.read_ledgers(quiet)
        require(clock() < drain_deadline, 'drain deadline exceeded before checkpoint, gateway remains fenced')
        require(all(quiet['escrows'][escrow]['session'] is None or not row['open_inferences']
                    for escrow, row in before_ledgers.items()),
                'inference closure changed before checkpoint')
        journal.record('drained', {'state_sha256': digest(quiet), 'escrow_count': len(quiet['escrows']),
                                  'checkpoint': quiet, 'ledgers': before_ledgers})
        require(adapter.read_compose() == original_bytes, 'Compose drift while draining')
        adapter.verify_runtime(identity, preview['image'], preview['state_volume'])
        require(clock() < drain_deadline, 'drain deadline exceeded before Compose dispatch, gateway remains fenced')
        journal.record('compose-dispatch', {'before_sha256': expected_compose,
                                           'desired_sha256': preview['desired_sha256']})
        adapter.replace_compose(original_bytes, desired_bytes)
        require(adapter.read_compose() == desired_bytes, 'Compose write readback mismatch')
        journal.record('recreate-dispatch', {'identity': identity})
        adapter.recreate(identity)
        adapter.verify_runtime(identity, preview['image'], preview['state_volume'])
        restore_deadline = clock() + timeout
        restarted = drain.wait_drained(read_fenced_state, restore_deadline, clock=clock, wait=wait,
                                       qualify=qualify_closed)
        preservation = ledger.confirm(quiet, restarted, before_ledgers, adapter.read_ledgers(restarted))
        require(clock() < restore_deadline, 'preservation deadline exceeded, gateway remains fenced')
        require(adapter.read_compose() == desired_bytes, 'Compose drift after recreation')
        require(adapter.read_settings() == fenced, 'settings drift before restoration')
        require(clock() < restore_deadline, 'restoration deadline exceeded, gateway remains fenced')
        journal.record('restore-dispatch', {'settings_before': digest(fenced),
                                           'settings_desired': expected_settings})
        adapter.replace_settings(fenced, original_settings)
        require(adapter.read_settings() == original_settings, 'operator settings restoration mismatch')
        restored_state = adapter.read_state()
        require(isinstance(restored_state, dict) and restored_state.get('settings') == original_persisted,
                'persisted operator settings restoration mismatch')
    except Exception:
        journal.record('terminal', {'outcome': 'INCONCLUSIVE', 'automatic_retry': False,
                                   'automatic_restore': False})
        raise
    receipt = {'schema': 'gdc-devshard-cache-lifecycle/1', 'identity': identity,
               'outcome': 'PASS', 'compose_after_sha256': preview['desired_sha256'],
               'settings_restored_sha256': expected_settings,
               'preserved_state_sha256': digest(quiet), 'escrow_count': len(quiet['escrows']),
               'ledger_preservation': preservation}
    journal.record('terminal', receipt)
    return receipt
