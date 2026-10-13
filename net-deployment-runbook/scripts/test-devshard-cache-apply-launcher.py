#!/usr/bin/env python3
"""Strict mocked GDC transport, not live apply acceptance."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


root = Path(__file__).resolve().parents[1]


class LauncherContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / 'bin'
        self.bin.mkdir()
        scripts = self.directory / 'scripts'
        scripts.mkdir()
        self.phase = scripts / 'phase-gateway-settings.sh'
        shutil.copyfile(root / 'scripts/phase-gateway-settings.sh', self.phase)
        (scripts / 'lib.sh').write_text('load_project() { ROOT="$GDC_TEST_ROOT"; }\n'
            'topology_contains_node() { [[ "$1" == gdc-node0 || "$1" == gdc-node4 ]]; }\n'
            'die() { printf "%s\\n" "$*" >&2; exit 2; }\n')
        self.log = self.directory / 'calls.jsonl'
        wrapper = '''#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['GDC_TEST_LOG'], 'a') as stream:
    stream.write(json.dumps([name, args]) + '\\n')
stage = '/srv/dai/ops/gdc-gateway-settings-test'
root = os.environ['GDC_TEST_ROOT']
if name == 'scp':
    groups = [
        [root + '/04-ops/' + x for x in ('devshard-settings.py','devshard-instances.py')],
        [root + '/04-ops/devshard-cache-policy.py'],
        [root + '/04-ops/' + x for x in ('devshard-cache-apply.py','devshard-cache-runtime.py',
          'devshard-cache-lifecycle.py','devshard-cache-drain.py','devshard-cache-ledger.py')],
    ]
    allowed = [['-q', *group, node + ':' + stage + '/04-ops/']
               for node in ('gdc-node0','gdc-node4') for group in groups]
    allowed += [['-q', root + '/scripts/devshard-preview.py', node + ':' + stage + '/scripts/']
                for node in ('gdc-node0','gdc-node4')]
    if args not in allowed:
        sys.exit(99)
elif name == 'ssh' and len(args) == 3 and args[:2] in (['-n','gdc-node0'],['-n','gdc-node4']):
    identity = 'A' if args[1] == 'gdc-node4' else 'B'
    port = '18087' if identity == 'A' else '18088'
    path = '/srv/dai/broker-tests/ds502-' + identity.lower() + '/compose.json'
    command = args[2]
    harmless = {"install -d -m 0700 '" + stage + "'",
                "install -d -m 0700 '" + stage + "/04-ops' '" + stage + "/scripts'",
                "chmod 0700 '" + stage + "/04-ops/'*.py '" + stage + "/scripts/'*.py"}
    before = ('b' if os.environ.get('GDC_TEST_NOOP') else 'a') * 64
    digest = "test ! -L '" + path + "' && test \\\"$(readlink -f '" + path + "')\\\" = '" + path + "' && sha256sum '" + path + "'"
    prefix = ['python3',stage + '/04-ops/devshard-cache-apply.py']
    preview = prefix + ['--preview','--id',identity,'--port',port,'--expected-compose-sha256',before]
    settings = ('d' if os.environ.get('GDC_TEST_SETTINGS_DRIFT') else 'c') * 64
    words = shlex.split(command)
    if command in harmless:
        pass
    elif command == digest:
        print(before + '  ' + path)
    elif words == preview:
        result = {'schema':'gdc-devshard-cache-lifecycle-preview/1','id':identity,'port':int(port),
            'applied':False,'before_sha256':before,'desired_sha256':'b'*64,
            'settings_before_sha256':settings,'qualified_storage':True,
            'state_volume':'gdc-ds502-' + identity.lower() + '-data',
            'image':'ghcr.io/gonka-ai/devshard-gateway@sha256:735240e2f8dfa77c27caf72d4442019c31b33546e047c92ff34bd8286857e4e2',
            'delta':[] if os.environ.get('GDC_TEST_NOOP') else
                    [{'field':'DEVSHARD_CHAT_CACHE_MAX_BYTES','before':None,'after':'1'}]}
        if os.environ.get('GDC_TEST_WRONG_IMAGE'):
            result['image'] = 'unqualified:image'
        if os.environ.get('GDC_TEST_WRONG_VOLUME'):
            result['state_volume'] = 'other-state'
        print(json.dumps(result))
    elif (len(words) == 13 and words[:12] == prefix + ['--apply','--id',identity,'--port',port,
        '--expected-compose-sha256',before,'--expected-settings-sha256',settings,'--evidence'] and
        words[12].startswith(stage + '/evidence-' + identity + '-apply-')):
        if os.environ.get('GDC_TEST_UNCERTAIN'):
            sys.exit(2)
        if os.environ.get('GDC_TEST_NOOP'):
            result = {'schema':'gdc-devshard-cache-policy/1','id':identity,'outcome':'NO_CHANGE',
                'applied':False,'delta':[],'before_sha256':before,'desired_sha256':'b'*64,
                'settings_sha256':settings}
        else:
            result = {'schema':'gdc-devshard-cache-lifecycle/1','identity':identity,'outcome':'PASS',
                'compose_after_sha256':'b'*64,'settings_restored_sha256':settings,
                'ledger_preservation':{'schema':'gdc-devshard-ledger-preservation/1','preserved':True}}
        print(json.dumps(result))
    else:
        sys.exit(99)
else:
    sys.exit(99)
'''
        for name in ('ssh', 'scp', 'curl'):
            target = self.bin / name
            target.write_text(wrapper)
            target.chmod(0o755)
        self.targets = [{'id':identity, 'node':node, 'port':port,
            'secret_file':'/srv/dai/broker-tests/ds502-' + identity.lower() + '/gateway.env'}
            for identity, node, port in (('A','gdc-node4',18087),('B','gdc-node0',18088))]
        self.approvals = [{'id':t['id'], 'node':t['node'], 'port':t['port'],
            'compose_before_sha256':'a'*64, 'compose_desired_sha256':'b'*64,
            'settings_before_sha256':'c'*64} for t in self.targets]

    def execute(self, action='apply', approvals=True, **changes):
        env = {'PATH':str(self.bin) + ':' + os.environ['PATH'], 'HOME':str(self.directory),
            'GDC_TEST_ROOT':str(root), 'GDC_TEST_LOG':str(self.log),
            'GDC_HOME':str(self.directory / 'gdc'), 'GDC_RUN_ID':'test',
            'GDC_GATEWAY_SETTINGS_POLICY':'fresh-inference-lifecycle',
            'GDC_GATEWAY_SETTINGS_TARGETS':json.dumps(self.targets)}
        if approvals:
            env['GDC_GATEWAY_CACHE_APPROVALS'] = json.dumps(self.approvals)
        env.update(changes)
        return subprocess.run(['bash',str(self.phase),action],env=env,text=True,capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def apply_calls(self):
        return [row for row in self.calls() if row[0] == 'ssh' and ' --apply ' in row[1][-1]]

    def test_missing_mismatched_duplicate_or_extra_approval_refuses_before_transport(self):
        self.assertNotEqual(self.execute(approvals=False).returncode,0)
        self.assertFalse(self.log.exists())
        original = json.loads(json.dumps(self.approvals))
        for mutation in (lambda a:a[0].update(node='gdc-node0'), lambda a:a[0].update(port=18088),
                         lambda a:a[0].update(extra=True), lambda a:a.pop(), lambda a:a.append(a[0])):
            self.approvals = json.loads(json.dumps(original))
            mutation(self.approvals)
            self.assertNotEqual(self.execute().returncode,0)
            self.assertFalse(self.log.exists())

    def test_fresh_preview_needs_no_approval_and_never_dispatches_apply(self):
        result = self.execute('preview',approvals=False)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.apply_calls(),[])
        self.assertNotIn('curl',[row[0] for row in self.calls()])

    def test_exact_approval_applies_each_target_once_and_retains_private_receipts(self):
        result = self.execute()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(self.apply_calls()),2)
        receipts = list((self.directory/'gdc/runs/test/gateway-cache-lifecycle-apply').glob('*.json'))
        self.assertEqual(len(receipts),4)
        self.assertTrue(all(file.stat().st_mode & 0o777 == 0o600 for file in receipts))

    def test_stale_compose_desired_or_settings_never_dispatches_apply(self):
        for field in ('compose_before_sha256','compose_desired_sha256','settings_before_sha256'):
            original = self.approvals[0][field]
            self.approvals[0][field] = 'e'*64
            result = self.execute()
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(self.apply_calls(),[])
            self.approvals[0][field] = original

    def test_same_approved_desired_state_reapply_is_noop(self):
        result = self.execute(GDC_TEST_NOOP='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(self.apply_calls()),2)
        self.assertIn('NO_CHANGE',result.stdout)

    def test_unqualified_image_or_volume_refuses_before_apply(self):
        for environment in ('GDC_TEST_WRONG_IMAGE','GDC_TEST_WRONG_VOLUME'):
            self.assertNotEqual(self.execute(**{environment:'1'}).returncode,0)
            self.assertEqual(self.apply_calls(),[])

    def test_uncertain_apply_stops_remaining_targets_without_retry(self):
        result = self.execute(GDC_TEST_UNCERTAIN='1')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len(self.apply_calls()),1)

    def test_legacy_or_unknown_instance_is_refused_before_transport(self):
        self.targets[0]['secret_file'] = '/srv/dai/broker-tests/legacy/gateway.env'
        self.assertNotEqual(self.execute().returncode,0)
        self.assertFalse(self.log.exists())

    def test_unmanaged_second_target_refuses_before_any_first_target_transport(self):
        self.targets[1]['node'] = 'unmanaged-node'
        self.approvals[1]['node'] = 'unmanaged-node'
        self.assertNotEqual(self.execute().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_unsafe_run_id_refuses_before_transport_or_local_receipt_directory(self):
        self.assertNotEqual(self.execute(GDC_RUN_ID='../unsafe').returncode, 0)
        self.assertFalse(self.log.exists())
        self.assertFalse((self.directory / 'gdc').exists())

    def test_unexpected_remote_command_negative_control(self):
        raw = self.phase.read_text()
        anchor = "install -d -m 0700 '$stage'"
        self.assertEqual(raw.count(anchor),1)
        self.phase.write_text(raw.replace(anchor,anchor + '; unexpected-command'))
        self.assertEqual(self.execute('preview',approvals=False).returncode,99)


if __name__ == '__main__':
    unittest.main()
