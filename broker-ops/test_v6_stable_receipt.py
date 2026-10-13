import copy
import importlib.util
from pathlib import Path
import unittest
import io
from email.message import Message
from unittest.mock import Mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import tempfile
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).with_name('v6-stable-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class ReceiptTest(unittest.TestCase):
    def setUp(self):
        admission = {'available': True, 'gateway': 'A', 'model': 'model', 'protocol': 'v6'}
        accounting = {'schema_version': 6, 'recording_errors': 0, 'writer_errors': 0,
            'epoch_index': 7, 'participants': [{'participant': 'host', 'model': 'model',
            'counters': [{'escrow_id': '123', 'key': {'slot_id': 0, 'disposition': 'finished_used'}, 'count': 1}]}]}
        self.value = {'started_ms': 1000, 'finished_ms': 2000, 'model': 'model', 'gateway': 'A',
            'admission_before': copy.deepcopy(admission), 'admission_after': copy.deepcopy(admission),
            'response': {'status': 200, 'request_id': 'native-request', 'escrow_id': '123',
                'body': {'model': 'model', 'choices': [{'message': {'content': 'OK'}}]}},
            'accounting_before': copy.deepcopy(accounting), 'accounting_after': copy.deepcopy(accounting)}
        self.value['accounting_after']['participants'][0]['counters'][0]['count'] = 2

    def test_observation_does_not_invent_exact_once_or_settlement(self):
        result = receipt.validate(self.value, 2100)
        self.assertEqual(result['state'], 'OBSERVED')
        self.assertFalse(result['exclusive_attribution_proven'])
        self.assertNotIn('admission_id', result)
        self.assertNotIn('body', result)

    def test_published_success_retains_observation_limit(self):
        result = receipt.validate(self.value, 2100)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stable-health.json'
            receipt.publish_health(path, result, 2100)
            published = json.loads(path.read_text())
        self.assertEqual(published['readiness'], 'STABLE_OBSERVED')
        self.assertEqual(published['request_id'], 'native-request')
        self.assertEqual(published['gateway'], 'A')
        self.assertFalse(published['exclusive_attribution_proven'])
        self.assertNotIn('admission_id', published)
        self.assertNotIn('TRAFFIC_READY', json.dumps(published))

    def test_drift_and_missing_evidence_refuse(self):
        cases = [('admission_after', 'gateway', 'B'), ('admission_after', 'available', False),
            ('admission_before', 'protocol', 'v5'), ('response', 'status', 503),
            ('response', 'request_id', ''), ('response', 'escrow_id', 'other'), ('response', 'body', []),
            ('accounting_after', 'epoch_index', 8), ('accounting_after', 'writer_errors', 1),
            ('accounting_before', 'participants', None)]
        for section, field, value in cases:
            with self.subTest(section=section, field=field):
                changed = copy.deepcopy(self.value)
                changed[section][field] = value
                self.assertEqual(receipt.validate(changed, 2100)['state'], 'UNAVAILABLE')
        for field in self.value:
            changed = copy.deepcopy(self.value)
            del changed[field]
            self.assertEqual(receipt.validate(changed, 2100)['state'], 'UNAVAILABLE')

    def test_counter_reset_no_progress_or_multiple_completions_refuse(self):
        for count in (0, 1, 3, -1, True, '2'):
            changed = copy.deepcopy(self.value)
            changed['accounting_after']['participants'][0]['counters'][0]['count'] = count
            self.assertEqual(receipt.validate(changed, 2100)['state'], 'UNAVAILABLE')

    def test_other_escrow_does_not_prove_this_response(self):
        self.value['accounting_after']['participants'][0]['counters'][0]['escrow_id'] = '124'
        self.assertEqual(receipt.validate(self.value, 2100)['state'], 'UNAVAILABLE')

    def test_stale_and_future_observations_refuse(self):
        for now in (1999, 31001):
            self.assertEqual(receipt.validate(self.value, now)['state'], 'UNAVAILABLE')

    def transport(self, calls, fail=None):
        counts = {'admission': 0, 'accounting': 0}
        def request(route, payload):
            calls.append((route, payload))
            if route == fail:
                raise TimeoutError('uncertain response')
            if route == 'completion':
                self.assertEqual(payload['model'], 'model')
                self.assertEqual(payload['max_tokens'], 8)
                return copy.deepcopy(self.value['response'])
            self.assertIsNone(payload)
            suffix = 'before' if counts[route] == 0 else 'after'
            counts[route] += 1
            return copy.deepcopy(self.value[route + '_' + suffix])
        return request

    def test_collector_sends_once_and_sanitizes_result(self):
        calls = []
        result = receipt.collect(self.transport(calls), 'model', 'A', lambda: 2000)
        self.assertEqual(result['state'], 'OBSERVED')
        self.assertEqual([x[0] for x in calls], ['admission', 'accounting', 'completion', 'accounting', 'admission'])
        self.assertNotIn('choices', str(result))
        self.assertNotIn('messages', str(result))

    def test_collector_refuses_fence_before_dispatch(self):
        self.value['admission_before']['available'] = False
        calls = []
        self.assertEqual(receipt.collect(self.transport(calls), 'model', 'A', lambda: 2000)['state'], 'UNAVAILABLE')
        self.assertEqual([x[0] for x in calls], ['admission'])

    def test_collector_does_not_retry_uncertain_dispatch(self):
        calls = []
        self.assertEqual(receipt.collect(self.transport(calls, 'completion'), 'model', 'A', lambda: 2000)['state'], 'UNAVAILABLE')
        self.assertEqual(sum(route == 'completion' for route, _ in calls), 1)

    def test_collector_accounting_failure_sends_no_completion(self):
        calls = []
        self.assertEqual(receipt.collect(self.transport(calls, 'accounting'), 'model', 'A', lambda: 2000)['state'], 'UNAVAILABLE')
        self.assertNotIn('completion', [x[0] for x in calls])

    def test_collector_stale_preflight_sends_no_completion(self):
        times = iter([1000, 7000])
        calls = []
        self.assertEqual(receipt.collect(self.transport(calls), 'model', 'A', lambda: next(times))['state'], 'UNAVAILABLE')
        self.assertNotIn('completion', [x[0] for x in calls])

    def test_malformed_preflight_counters_prevent_dispatch(self):
        original = copy.deepcopy(self.value)
        for field, invalid in (('count', -1), ('count', True), ('count', '1'),
                               ('escrow_id', 123), ('escrow_id', ''),
                               ('key', {}), ('key', {'slot_id': -1, 'disposition': 'finished_used'})):
            with self.subTest(field=field, invalid=invalid):
                self.value = copy.deepcopy(original)
                self.value['accounting_before']['participants'][0]['counters'][0][field] = invalid
                calls = []
                result = receipt.collect(self.transport(calls), 'model', 'A', lambda: 2000)
                self.assertEqual(result['state'], 'UNAVAILABLE')
                self.assertNotIn('completion', [route for route, _ in calls])


class TransportTest(unittest.TestCase):
    def test_real_redirect_does_not_forward_credentials(self):
        calls = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                calls.append((self.path, self.headers.get('Authorization')))
                self.send_response(307)
                self.send_header('Location', '/unexpected')
                self.send_header('Content-Length', '0')
                self.end_headers()

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            base = 'http://127.0.0.1:' + str(server.server_port)
            transport = receipt.HTTPTransport(base + '/v1/chat/completions', base + '/admission',
                                               base + '/accounting', 'sk-gdc-fixture')
            with self.assertRaises(ValueError):
                transport('completion', {})
            self.assertEqual(calls, [('/v1/chat/completions', 'Bearer sk-gdc-fixture')])
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

    def transport(self, raw=b'{}', headers=None):
        response = io.BytesIO(raw)
        response.status = 200
        response.headers = headers or Message()
        opener = Mock()
        opener.open.return_value = response
        return receipt.HTTPTransport('https://fixture.invalid/v1/chat/completions',
            'http://127.0.0.1:18186/v1/admission-status',
            'http://127.0.0.1:19191/api/v1/epochs/current/participants',
            'sk-gdc-fixture', opener), opener

    def test_readonly_endpoints_never_receive_credential(self):
        for route in ('admission', 'accounting'):
            transport, opener = self.transport()
            self.assertEqual(transport(route, None), {})
            request = opener.open.call_args.args[0]
            self.assertIsNone(request.get_header('Authorization'))
            self.assertEqual(request.method, 'GET')
            self.assertIsNone(request.data)

    def test_completion_preserves_exact_native_identity(self):
        headers = Message()
        headers['X-Request-Id'] = 'native'
        headers['X-Devshard-ID'] = '123'
        transport, opener = self.transport(headers=headers)
        result = transport('completion', {'model': 'model'})
        self.assertEqual(result['request_id'], 'native')
        self.assertEqual(result['escrow_id'], '123')
        self.assertEqual(opener.open.call_args.args[0].get_header('Authorization'), 'Bearer sk-gdc-fixture')
        opener.open.assert_called_once()

    def test_missing_and_duplicate_identity_refused(self):
        for count in (0, 2):
            headers = Message()
            for _ in range(count):
                headers['X-Request-Id'] = 'native'
            headers['X-Devshard-ID'] = '123'
            transport, _ = self.transport(headers=headers)
            with self.assertRaises(ValueError):
                transport('completion', {})

    def test_unbounded_and_non_object_json_refused(self):
        for raw in (b'x' * (1024 * 1024 + 1), b'[]', b'invalid'):
            transport, _ = self.transport(raw)
            with self.assertRaises(ValueError):
                transport('accounting', None)

    def test_redirect_refused(self):
        with self.assertRaises(ValueError):
            receipt.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.invalid')

    def test_unsafe_completion_origin_refused(self):
        for url in ('http://external.invalid/v1/chat/completions',
                    'https://user:secret@fixture.invalid/v1/chat/completions',
                    'https://fixture.invalid/v1/admin/escrows'):
            with self.assertRaises(ValueError):
                receipt.HTTPTransport(url, 'http://127.0.0.1/a', 'http://127.0.0.1/b', 'sk-gdc-fixture')


class CLITest(unittest.TestCase):
    def test_health_failure_replaces_previous_observation_without_private_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stable-health.json'
            path.write_text('{"state":"OBSERVED"}')
            receipt.publish_health(path, {'state': 'UNAVAILABLE', 'reason': 'private-error',
                                         'key': 'private-key'}, 2000)
            value = json.loads(path.read_text())
            self.assertEqual(value['state'], 'UNAVAILABLE')
            self.assertEqual(value['contract'], 'stable_native_observation')
            self.assertFalse(value['exclusive_attribution_proven'])
            self.assertNotIn('private', path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_configuration_failure_publishes_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stable-health.json'
            with patch.object(receipt, 'read_config', side_effect=ValueError('secret')), \
                 patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(receipt.main(['--config', '/fixture', '--execute',
                                             '--health-output', str(path)]), 1)
            self.assertEqual(json.loads(path.read_text())['readiness'], 'UNAVAILABLE')

    def test_failed_atomic_replace_preserves_previous_file_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stable-health.json'
            path.write_text('old')
            with patch.object(receipt.os, 'replace', side_effect=OSError('disk failure')):
                with self.assertRaises(OSError):
                    receipt.publish_health(path, {'state': 'UNAVAILABLE'}, 2000)
            self.assertEqual(path.read_text(), 'old')
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_missing_execution_opt_in_does_not_read_key(self):
        with patch.object(receipt, 'read_config') as read, patch('sys.stderr', new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as error:
                receipt.main(['--config', '/not-read'])
        self.assertEqual(error.exception.code, 2)
        read.assert_not_called()

    def test_private_config_permissions_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'probe.json'
            value = {name: 'fixture' for name in ('completion_url', 'admission_url', 'accounting_url', 'key', 'model', 'gateway')}
            path.write_text(json.dumps(value))
            path.chmod(0o600)
            self.assertEqual(receipt.read_config(path), value)
            path.chmod(0o640)
            with self.assertRaises(ValueError):
                receipt.read_config(path)
            path.chmod(0o600)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                receipt.read_config(link)

    def test_configuration_error_does_not_print_secret(self):
        with patch.object(receipt, 'read_config', side_effect=ValueError('private-key')), \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(receipt.main(['--config', '/fixture', '--execute']), 1)
        self.assertNotIn('private-key', output.getvalue())
        self.assertEqual(json.loads(output.getvalue())['state'], 'UNAVAILABLE')


if __name__ == '__main__':
    unittest.main()
