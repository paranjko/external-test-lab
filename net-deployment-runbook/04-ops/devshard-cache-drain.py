#!/usr/bin/env python3
"""Fail-closed predicates for native gateway drain and restart preservation.

These functions do not fence admission, fetch samples, or authorize a restart
The lifecycle caller must obtain fresh authenticated samples under its lock
"""

import copy
import hashlib
import json
import re
import time


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Busy(ValueError):
    """Only proven positive work counters may cause another state-based wait."""


def snapshot(document):
    require(isinstance(document, dict), 'complete admin state required')
    settings = document.get('settings')
    require(isinstance(settings, dict), 'complete settings required')
    disabled = settings.get('disabled')
    require(isinstance(disabled, dict) and disabled.get('enabled') is True,
            'admission must be fenced before drain')
    rotation = settings.get('escrow_rotation')
    require(isinstance(rotation, dict) and rotation.get('enabled') is False
            and rotation.get('settlement_enabled') is False,
            'rotation and settlement must be paused before drain')
    rows = document.get('devshards')
    require(isinstance(rows, list) and rows, 'nonempty retained escrow inventory required')
    inventory = {}
    busy = False
    for row in rows:
        require(isinstance(row, dict), 'invalid retained escrow')
        identity = row.get('id')
        require(isinstance(identity, str) and re.fullmatch(r'[1-9][0-9]*', identity)
                and identity not in inventory,
                'invalid or duplicate escrow identity')
        require(type(row.get('active')) is bool and row.get('settlement_pending', False) is False,
                'invalid active state or pending settlement')
        # Admin state redacts this value, never accept a key-bearing snapshot
        require(not row.get('private_key') and not row.get('private_key_hex'),
                'unredacted state is refused')
        runtime = row.get('runtime')
        require(isinstance(runtime, dict) and runtime.get('id') == identity
                and runtime.get('active') is row['active'], 'retained runtime binding missing')
        for counter in ('active_requests', 'pending_race_cleanup', 'reserved_tokens'):
            require(type(runtime.get(counter)) is int and runtime[counter] >= 0,
                    'drain telemetry is missing or invalid')
            busy = busy or runtime[counter] > 0
        for value in ('nonce', 'balance'):
            require(type(runtime.get(value)) is int and runtime[value] >= 0,
                    'session accounting telemetry is missing')
        require(isinstance(runtime.get('session_version'), str) and runtime['session_version'],
                'session protocol identity is missing')
        persisted = copy.deepcopy(row)
        del persisted['runtime']
        inventory[identity] = {'persisted': persisted,
                               'session': {key: runtime[key] for key in
                                           ('nonce', 'balance', 'session_version')}}
    if busy:
        raise Busy('gateway still has work')
    return {'settings': copy.deepcopy(settings), 'escrows': inventory}


def confirm_drained(first, second):
    before, after = snapshot(first), snapshot(second)
    require(before == after, 'state changed between drained samples')
    return before


def confirm_preserved(drained, restarted):
    after = snapshot(restarted)
    require(drained == after, 'restart changed retained settings, escrow or session')
    digest = hashlib.sha256(json.dumps(after, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'schema': 'gdc-devshard-cache-preservation/1', 'preserved_sha256': digest,
            'escrow_count': len(after['escrows']), 'preserved': True}


def fenced_settings(original):
    """Retain complete operator settings, change only the temporary fences."""
    require(isinstance(original, dict) and isinstance(original.get('disabled'), dict)
            and isinstance(original.get('escrow_rotation'), dict), 'complete operator settings required')
    require(type(original['disabled'].get('enabled')) is bool
            and type(original['escrow_rotation'].get('enabled')) is bool
            and type(original['escrow_rotation'].get('settlement_enabled')) is bool,
            'invalid operator fences')
    result = copy.deepcopy(original)
    result['disabled']['enabled'] = True
    result['escrow_rotation']['enabled'] = False
    result['escrow_rotation']['settlement_enabled'] = False
    return result


def wait_drained(read_state, deadline, interval=0.5, clock=time.monotonic, wait=time.sleep,
                 qualify=None):
    """No HTTP retries: the caller's failed read aborts immediately."""
    require(type(interval) in (float, int) and 0 < interval <= 5, 'invalid drain poll interval')
    previous = None
    while clock() < deadline:
        state = read_state()
        require(clock() < deadline, 'drain deadline exceeded after state read, gateway remains fenced')
        try:
            current = snapshot(state)
            if qualify is not None:
                qualify(current)
            require(clock() < deadline, 'drain deadline exceeded after qualification, gateway remains fenced')
        except Busy:
            previous = None
        else:
            if previous is not None:
                require(previous == current, 'quiet escrow state changed during drain')
                return current
            previous = current
        remaining = deadline - clock()
        if remaining > 0:
            wait(min(interval, remaining))
    raise ValueError('drain deadline exceeded, gateway remains fenced')
