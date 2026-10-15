import copy
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('switcher', Path(__file__).with_name('v6-gateway-release-switch.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
OLD = 'ghcr.io/paranjko/external-test-lab/devshard-gateway@sha256:' + '1' * 64
NEW = 'ghcr.io/paranjko/external-test-lab/devshard-gateway@sha256:' + '2' * 64


class SwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.campaign = self.root / 'campaign'
        self.campaign.mkdir()
        with sqlite3.connect(self.campaign / 'ledger.sqlite') as db:
            db.execute('CREATE TABLE binding (instance TEXT, budget INTEGER)')
            db.execute('INSERT INTO binding VALUES (?, ?)', ('a', 5000))
        (self.root / 'compose.yaml').write_text('image: ' + OLD + '\n')
        (self.root / 'operator.env').write_text('fixture=true\n')
        volume = self.root / 'volume'
        volume.mkdir()
        (volume / 'state.sqlite').write_bytes(b'preserved fixture')
        self.container = {'State': {'Running': True}, 'Config': {'Image': OLD}, 'Image': 'old-id',
            'Mounts': [{'Type': 'volume', 'Name': 'gdc-v6-a-data',
                        'Destination': '/root/.devshardctl', 'Source': str(volume)}]}
        self.image = {'Architecture': 'amd64', 'Os': 'linux', 'RepoDigests': [NEW], 'Id': 'new-id'}
        self.settings = {'escrow_rotation': {'enabled': False}, 'redundancy': {'floor': 1000}}
        self.state = {'devshards': [{'id': 123, 'active': True}], 'limiter': {'in_flight_requests': 0}}
        self.timer = 'active'
        self.events = []

    def fake_run(self, *args):
        # Deny every unexpected external command; never reach SSH or real Docker.
        self.events.append(args)
        if args == ('docker', 'image', 'inspect', NEW):
            return json.dumps([self.image])
        if args == ('docker', 'inspect', 'gdc-v6-a-gateway-1'):
            return json.dumps([self.container])
        if args == ('docker', 'ps', '--filter', 'volume=gdc-v6-a-data', '--format', '{{.Names}}'):
            return 'gdc-v6-a-gateway-1'
        if args == ('systemctl', 'show', 'gdc-v6-budget-a.timer', '--property=ActiveState', '--value'):
            return self.timer
        if args == ('systemctl', 'show', 'gdc-v6-budget-a.service', '--property=ActiveState', '--value'):
            return 'inactive'
        if args == ('systemctl', 'stop', 'gdc-v6-budget-a.timer'):
            self.timer = 'inactive'
            return ''
        if args == ('systemctl', 'start', 'gdc-v6-budget-a.timer'):
            self.timer = 'active'
            return ''
        if args == ('docker', 'stop', '--time', '120', 'gdc-v6-a-gateway-1'):
            self.assertFalse(self.state['devshards'][0]['active'])
            self.container['State']['Running'] = False
            return ''
        if args == ('docker', 'compose', '--env-file', str(self.root / 'operator.env'),
                    '-f', str(self.root / 'compose.yaml'), 'up', '-d', '--no-deps', 'gateway'):
            self.assertTrue((self.root / 'backup/gateway-state/state.sqlite').exists())
            self.container['Config']['Image'] = NEW
            self.container['Image'] = 'new-id'
            self.container['State']['Running'] = True
            return ''
        raise AssertionError('unexpected command: ' + repr(args))

    def api(self, route, post=False):
        if route == '/v1/admin/settings' and not post:
            return copy.deepcopy(self.settings)
        if route == '/v1/admin/state' and not post:
            return copy.deepcopy(self.state)
        if route in ('/v1/admin/devshards/123/activate', '/v1/admin/devshards/123/deactivate') and post:
            self.state['devshards'][0]['active'] = route.endswith('/activate')
            return copy.deepcopy(self.state['devshards'][0])
        raise AssertionError('unexpected API: ' + route)

    def invoke(self, apply=True):
        return module.switch(self.root, self.campaign, 'a', OLD, NEW, self.api,
                             self.root / 'backup' if apply else None, self.fake_run)

    def test_dry_run_never_mutates(self):
        self.assertFalse(self.invoke(False)['applied'])
        self.assertTrue(all('inspect' in event or 'show' in event or 'ps' in event for event in self.events))
        self.assertFalse((self.root / 'backup').exists())

    def test_exclusive_switch_preserves_state_and_timer(self):
        before = module.ledger(self.campaign, 'a')
        result = self.invoke()
        self.assertTrue(result['applied'])
        self.assertEqual(module.ledger(self.campaign, 'a'), before)
        self.assertEqual(self.timer, 'active')
        self.assertTrue(self.state['devshards'][0]['active'])
        self.assertEqual((self.root / 'backup/gateway-state/state.sqlite').read_bytes(), b'preserved fixture')
        self.assertEqual((self.root / 'backup').stat().st_mode & 0o777, 0o700)
        self.assertTrue((self.root / 'backup/receipt.json').exists())

    def test_paused_timer_stays_paused(self):
        self.timer = 'inactive'
        self.assertEqual(self.invoke()['timer_after'], 'inactive')
        self.assertNotIn(('systemctl', 'start', 'gdc-v6-budget-a.timer'), self.events)

    def test_b_uses_its_own_volume_and_budget(self):
        with sqlite3.connect(self.campaign / 'ledger.sqlite') as db:
            db.execute("UPDATE binding SET instance = 'b'")
        self.container['Mounts'][0]['Name'] = 'gdc-v6-b-data'
        def b_run(*args):
            translated = tuple(arg.replace('gdc-v6-b-', 'gdc-v6-a-').replace(
                'gdc-v6-budget-b.', 'gdc-v6-budget-a.') for arg in args)
            result = self.fake_run(*translated)
            return result.replace('gdc-v6-a-gateway-1', 'gdc-v6-b-gateway-1') if args[:2] == ('docker', 'ps') else result
        result = module.switch(self.root, self.campaign, 'b', OLD, NEW, self.api,
                               self.root / 'backup', b_run)
        self.assertEqual(result['instance'], 'b')
        self.assertEqual(self.container['Mounts'][0]['Name'], 'gdc-v6-b-data')

    def test_other_volume_writer_refused(self):
        original = self.fake_run
        def other(*args):
            if args[:2] == ('docker', 'ps'):
                return 'gdc-v6-a-gateway-1\nother-writer'
            return original(*args)
        self.fake_run = other
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.timer, 'active')

    def test_platform_and_layout_fail_before_pause(self):
        for mutate in (lambda: self.image.update(Architecture='arm64'),
                       lambda: self.container.update(Mounts=[])):
            mutate()
            with self.assertRaises(ValueError):
                self.invoke()
            self.assertEqual(self.timer, 'active')
            self.image['Architecture'] = 'amd64'

    def test_inflight_timeout_does_not_stop_writer(self):
        self.state['limiter']['in_flight_requests'] = 1
        def bounded(predicate, timeout=120):
            if not predicate():
                raise TimeoutError()
        with patch.object(module, 'wait_for', bounded), self.assertRaises(TimeoutError):
            self.invoke()
        self.assertTrue(self.container['State']['Running'])
        self.assertEqual(self.timer, 'inactive')

    def test_missing_counter_is_not_zero(self):
        self.state['limiter'] = {}
        with self.assertRaises(KeyError):
            self.invoke()
        self.assertTrue(self.container['State']['Running'])
        self.assertEqual(self.timer, 'inactive')

    def test_readback_failure_keeps_rotation_paused(self):
        original = self.fake_run
        def race(*args):
            result = original(*args)
            if args[:2] == ('docker', 'compose'):
                self.settings['unexpected'] = True
            return result
        self.fake_run = race
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.timer, 'inactive')
        self.assertFalse((self.root / 'backup/receipt.json').exists())

    def test_existing_receipt_and_stale_image_rejected(self):
        (self.root / 'backup').mkdir()
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.timer, 'active')
        self.container['Config']['Image'] = NEW
        with self.assertRaises(ValueError):
            self.invoke(False)


if __name__ == '__main__':
    unittest.main()
