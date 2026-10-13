#!/usr/bin/env python3
"""Collect one explicitly authorized stable-route observation; never submit funds."""
import re
import secrets
import json
import argparse
import os
import stat
import time
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('probe redirects are forbidden')


class HTTPTransport:
    """One request per call, bounded response, no redirects or ambient proxies."""
    def __init__(self, completion_url, admission_url, accounting_url, key, opener=None):
        from urllib.request import ProxyHandler
        self.urls = dict(completion=completion_url, admission=admission_url, accounting=accounting_url)
        for name, value in self.urls.items():
            parsed = urlsplit(value)
            if (parsed.scheme not in ('http', 'https') or not parsed.hostname
                    or parsed.username or parsed.password or parsed.fragment):
                raise ValueError('invalid probe URL')
            if parsed.scheme == 'http' and parsed.hostname not in ('127.0.0.1', '::1'):
                raise ValueError('plaintext probe URLs must be loopback')
            if name == 'completion' and (parsed.path != '/v1/chat/completions' or parsed.query):
                raise ValueError('stable completion URL required')
        if not isinstance(key, str) or re.fullmatch(r'sk-gdc-[A-Za-z0-9_-]+', key) is None:
            raise ValueError('stable credential required')
        self.key = key
        self.opener = opener or build_opener(ProxyHandler({}), NoRedirect())

    def __call__(self, route, payload):
        if route not in self.urls or (route == 'completion') != (payload is not None):
            raise ValueError('invalid probe operation')
        headers = {'Accept': 'application/json'}
        data = None
        if route == 'completion':
            headers.update({'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json'})
            data = json.dumps(payload).encode()
        req = Request(self.urls[route], data=data, headers=headers,
                      method='POST' if data is not None else 'GET')
        with self.opener.open(req, timeout=5) as response:
            if response.status != 200:
                raise ValueError('probe HTTP failure')
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise ValueError('oversized probe response')
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise ValueError('probe JSON object required')
            if route != 'completion':
                return body
            identities = {}
            for field, header in (('request_id', 'X-Request-Id'), ('escrow_id', 'X-Devshard-ID')):
                values = response.headers.get_all(header, [])
                if len(values) != 1:
                    raise ValueError('ambiguous native identity')
                identities[field] = values[0]
            return {'status': response.status, 'body': body, **identities}


def integer(value):
    if type(value) is not int or value < 0:
        raise ValueError('invalid counter')
    return value


def finished(snapshot, model, escrow):
    """Read native schema6 counters, scoped to the returned escrow and model."""
    if (integer(snapshot['schema_version']) != 6 or integer(snapshot['recording_errors']) != 0
            or integer(snapshot['writer_errors']) != 0):
        raise ValueError('accounting unavailable')
    totals = {}
    if not isinstance(snapshot['participants'], list):
        raise ValueError('invalid participants')
    for participant in snapshot['participants']:
        if (participant['model'] != model or not isinstance(participant['participant'], str)
                or not participant['participant'] or not isinstance(participant['counters'], list)):
            raise ValueError('accounting model mismatch')
        for counter in participant['counters']:
            counter_escrow = counter['escrow_id']
            if (not isinstance(counter_escrow, str)
                    or re.fullmatch(r'[1-9][0-9]*', counter_escrow) is None):
                raise ValueError('invalid accounting escrow')
            key = counter['key']
            slot = integer(key['slot_id'])
            count = integer(counter['count'])
            if not isinstance(key['disposition'], str) or not key['disposition']:
                raise ValueError('invalid accounting disposition')
            if counter_escrow == escrow and key['disposition'] == 'finished_used':
                identity = (participant['participant'], slot)
                totals[identity] = totals.get(identity, 0) + count
    return totals


def validate(observation, now_ms):
    """Fail closed on drift/ambiguity; this is an observation, not settlement proof.

    The collector must supply native accounting before and after its one stable
    request plus independent admission readbacks. Aggregate increments cannot
    prove exclusive attribution under concurrent traffic, so retain that limit
    explicitly and do not invent the legacy exact-once admission receipt.
    """
    try:
        now_ms = integer(now_ms)
        start = integer(observation['started_ms'])
        end = integer(observation['finished_ms'])
        if not start <= end <= now_ms or now_ms - start > 30000:
            raise ValueError('stale observation')
        model = observation['model']
        gateway = observation['gateway']
        if not isinstance(model, str) or not model or gateway not in ('A', 'B'):
            raise ValueError('invalid route binding')
        for admission in (observation['admission_before'], observation['admission_after']):
            if (admission['available'] is not True or admission['gateway'] != gateway
                    or admission['model'] != model or admission['protocol'] != 'v6'):
                raise ValueError('admission binding unavailable')
        response = observation['response']
        if response['status'] != 200:
            raise ValueError('completion failed')
        request_id = response['request_id']
        escrow = response['escrow_id']
        if (not isinstance(request_id, str)
                or re.fullmatch(r'[A-Za-z0-9._:-]{1,128}', request_id) is None
                or not isinstance(escrow, str) or re.fullmatch(r'[1-9][0-9]*', escrow) is None):
            raise ValueError('native identity missing')
        body = response['body']
        if (not isinstance(body, dict) or body.get('error') or body['model'] != model or not body['choices']
                or not isinstance(body['choices'][0]['message']['content'], str)
                or not body['choices'][0]['message']['content'].strip()):
            raise ValueError('invalid completion')
        before, after = observation['accounting_before'], observation['accounting_after']
        if integer(before['epoch_index']) == 0 or before['epoch_index'] != integer(after['epoch_index']):
            raise ValueError('epoch changed')
        old, new = finished(before, model, escrow), finished(after, model, escrow)
        if any(new.get(key, 0) < value for key, value in old.items()):
            raise ValueError('accounting reset')
        delta = sum(new.values()) - sum(old.values())
        if delta != 1:
            raise ValueError('accounting increment ambiguous')
        return {'state': 'OBSERVED', 'reason': 'stable_completion_with_native_accounting_increment',
                'gateway': gateway, 'model': model, 'protocol': 'v6',
                'request_id': request_id, 'escrow_id': escrow, 'finished_ms': end,
                'finished_used_delta': delta, 'exclusive_attribution_proven': False}
    except (KeyError, TypeError, ValueError, IndexError):
        return {'state': 'UNAVAILABLE', 'reason': 'stable_observation_unproved'}


def collect(request, model, gateway, clock):
    """Collect one bounded observation with an injected, non-retrying transport.

    Transport names are fixed: admission/accounting are read-only observations
    of the selected native route; completion is the authenticated stable route.
    A transport failure after dispatch is not retried. No credentials, prompts
    or response content are returned in the public observation.
    """
    unavailable = {'state': 'UNAVAILABLE', 'reason': 'stable_observation_unproved'}
    try:
        if gateway not in ('A', 'B') or not isinstance(model, str) or not model.strip():
            return unavailable
        started = integer(clock())
        admission = request('admission', None)
        if (admission['available'] is not True or admission['gateway'] != gateway
                or admission['model'] != model or admission['protocol'] != 'v6'):
            return unavailable
        before = request('accounting', None)
        finished(before, model, '')  # Refuse unavailable accounting before traffic.
        if integer(before['epoch_index']) == 0 or clock() - started > 5000:
            return unavailable
        response = request('completion', {'model': model, 'max_tokens': 8,
            'messages': [{'role': 'user', 'content': 'Reply OK [stable-readiness:' + secrets.token_hex(16) + ']'}]})
        if response['status'] != 200:
            return unavailable
        after = request('accounting', None)
        admission_after = request('admission', None)
        ended = integer(clock())
        return validate({'started_ms': started, 'finished_ms': ended, 'model': model,
            'gateway': gateway, 'admission_before': admission, 'admission_after': admission_after,
            'response': response, 'accounting_before': before, 'accounting_after': after}, ended)
    except (KeyError, TypeError, ValueError, IndexError, OSError):
        return unavailable


def read_config(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.geteuid()):
            raise ValueError('private operator-owned regular file with mode0600 required')
        raw = source.read(16385)
        if len(raw) > 16384:
            raise ValueError('oversized configuration')
        config = json.loads(raw)
    if not isinstance(config, dict) or set(config) != {
            'completion_url', 'admission_url', 'accounting_url', 'key', 'model', 'gateway'}:
        raise ValueError('invalid configuration fields')
    return config


def publish_health(path, result, now_ms):
    """Atomically publish sanitized observation, never legacy traffic readiness.

    Use a separate stable health file: the legacy timer owns gateway-health.json.
    A failed probe replaces the preceding observation instead of preserving a
    misleading last-success sample. Consumers must still enforce freshness.
    """
    now_ms = integer(now_ms)
    observed = result.get('state') == 'OBSERVED'
    payload = {
        'schema_version': 1, 'contract': 'stable_native_observation',
        'state': 'OBSERVED' if observed else 'UNAVAILABLE',
        'readiness': 'STABLE_OBSERVED' if observed else 'UNAVAILABLE',
        'checked_at': datetime.fromtimestamp(now_ms / 1000, timezone.utc).isoformat(),
        'exclusive_attribution_proven': False,
    }
    # Never copy arbitrary error text, transport payloads or configuration.
    payload['reason'] = ('stable_completion_with_native_accounting_increment' if observed
                         else 'stable_observation_unproved')
    if observed:
        for field in ('gateway', 'model', 'protocol', 'request_id', 'escrow_id',
                      'finished_ms', 'finished_used_delta'):
            payload[field] = result[field]
    directory = os.path.dirname(os.path.abspath(path))
    descriptor, temporary = tempfile.mkstemp(prefix='.stable-health-', dir=directory)
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(payload, output, sort_keys=True)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, help='private mode0600 JSON configuration')
    parser.add_argument('--execute', action='store_true', help='explicitly authorize one inference probe')
    parser.add_argument('--health-output', help='optional separate stable health JSON file (not the legacy timer output)')
    args = parser.parse_args(argv)
    if not args.execute:
        parser.error('--execute is required; no probe was sent')
    try:
        config = read_config(args.config)
        transport = HTTPTransport(config['completion_url'], config['admission_url'],
                                  config['accounting_url'], config['key'])
        result = collect(transport, config['model'], config['gateway'], lambda: time.time_ns() // 1_000_000)
    except (ValueError, TypeError, OSError):
        result = {'state': 'UNAVAILABLE', 'reason': 'stable_probe_configuration_invalid'}
    if args.health_output:
        try:
            publish_health(args.health_output, result, time.time_ns() // 1_000_000)
        except (ValueError, TypeError, OSError):
            result = {'state': 'UNAVAILABLE', 'reason': 'stable_health_publication_failed'}
    print(json.dumps(result, sort_keys=True))
    return 0 if result['state'] == 'OBSERVED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
