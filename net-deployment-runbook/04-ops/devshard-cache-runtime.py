#!/usr/bin/env python3
"""Local native adapter, not a public endpoint or an authorized apply command.

The GDC caller must qualify the layout, hold the shared settings lock, and
provide exact approved preimages before invoking the lifecycle sequencer
"""

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


settings = module('native_settings', 'devshard-settings.py')
ledger = module('native_ledger', 'devshard-cache-ledger.py')
require = settings.require


class ListenerUnavailable(ValueError):
    """Only connection refusal/reset from an idempotent local HTTP read."""


class Journal(settings.Journal):
    """Private write-once entries, including directory durability before dispatch."""

    def __init__(self, directory):
        super().__init__(directory)
        self.sync_directory(self.directory.parent)

    @staticmethod
    def sync_directory(directory):
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def record(self, kind, value):
        result = super().record(kind, value)
        self.sync_directory(self.directory)
        return result


class Native:
    def __init__(self, identity, port):
        require(identity in ('A', 'B'), 'exact native scope required')
        require(type(port) is int and 1024 <= port <= 65535, 'invalid private listener')
        self.identity = identity
        self.directory = Path('/srv/dai/broker-tests/ds502-' + identity.lower())
        self.compose = self.directory / 'compose.json'
        require(self.directory.resolve(strict=True) == self.directory, 'symlink scope refused')
        self.secret_file = settings.instances.private_file(self.directory / 'gateway.env')
        settings.instances.secrets(self.secret_file)
        self.port = port
        self.project = 'gdc-ds502-' + identity.lower()

    def command(self, arguments, input=None, timeout=60):
        try:
            result = subprocess.run(arguments, input=input, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise ValueError('native operation deadline exceeded, outcome uncertain') from None
        if arguments[0] == 'curl' and result.returncode in (7, 52, 56):
            raise ListenerUnavailable('private listener is not ready')
        require(result.returncode == 0, 'native operation failed, no automatic retry')
        return result.stdout

    def request(self, method, path, payload=None):
        require((method, path) in {('GET', '/v1/admin/settings'), ('GET', '/v1/admin/state'),
                                  ('POST', '/v1/admin/settings')}, 'unsupported private management operation')
        values = dict(line.split('=', 1) for line in self.secret_file.read_text().splitlines()
                      if line and not line.startswith('#'))
        config = 'header = "Authorization: Bearer ' + values['DEVSHARD_ADMIN_API_KEY'] + '"\n'
        arguments = ['curl', '--silent', '--show-error', '--fail', '--connect-timeout', '5',
                     '--max-time', '30', '--noproxy', '*', '--proto', '=http', '--config', '-',
                     '--request', method, 'http://127.0.0.1:' + str(self.port) + path]
        with tempfile.TemporaryDirectory(prefix='gdc-cache-settings-') as directory:
            if payload is not None:
                file = Path(directory) / 'payload.json'
                with file.open('x') as stream:
                    os.chmod(file, 0o600)
                    json.dump(payload, stream)
                arguments += ['--header', 'Content-Type: application/json', '--data-binary', '@' + str(file)]
            operation_timeout = 35
            budget = getattr(self, '_read_deadline', None)
            if budget is not None:
                deadline, clock = budget
                remaining = deadline - clock()
                require(remaining > 0, 'private listener readiness deadline exceeded before request')
                arguments[arguments.index('--max-time') + 1] = str(min(30, remaining))
                arguments[arguments.index('--connect-timeout') + 1] = str(min(5, remaining))
                operation_timeout = remaining
            body = self.command(arguments, input=config, timeout=operation_timeout)
        try:
            return json.loads(body, object_pairs_hook=settings.instances.preview.unique_object)
        except ValueError:
            raise ValueError('native management response is invalid') from None

    def read_compose(self):
        require(self.compose.resolve(strict=True) == self.compose and self.compose.is_file(),
                'exact nonsymlink Compose target required')
        require(self.compose.stat().st_uid == os.getuid(), 'Compose must belong to the current operator')
        return self.compose.read_bytes()

    def read_settings(self):
        return self.request('GET', '/v1/admin/settings')

    def read_state(self):
        return self.request('GET', '/v1/admin/state')

    def replace_settings(self, before, desired):
        require(self.read_settings() == before, 'settings drift before private POST')
        self.request('POST', '/v1/admin/settings', desired)

    def read_ledgers(self, checkpoint):
        volume = 'gdc-ds502-' + self.identity.lower() + '-data'
        self.verify_runtime(self.identity, settings.instances.IMAGE, volume)
        metadata = json.loads(self.command(['docker', 'volume', 'inspect', '--format',
                                           '{{json .}}', volume]))
        require(metadata.get('Name') == volume and metadata.get('Driver') == 'local'
                and metadata.get('Options') in (None, {}), 'native local retained volume required')
        mount = metadata.get('Mountpoint')
        require(isinstance(mount, str) and Path(mount).is_absolute(), 'exact volume directory required')
        directory = Path(mount)
        require(directory.is_dir() and directory.resolve(strict=True) == directory,
                'nonsymlink retained volume required')
        require(not (directory / '.pg-bound').exists(), 'PostgreSQL-bound volume is unsupported')
        result = {}
        for identity, row in checkpoint['escrows'].items():
            require(row['persisted'].get('storage_path') == '/root/.devshardctl/escrow-' + identity,
                    'qualified native escrow storage path required')
            result[identity] = ledger.collect(directory / ('escrow-' + identity), identity, row['session'])
        return result

    def qualify_storage(self, state):
        require(isinstance(state, dict) and isinstance(state.get('devshards'), list)
                and state['devshards'], 'nonempty retained storage inventory required')
        checkpoint = {'escrows': {}}
        for row in state['devshards']:
            require(isinstance(row, dict) and not row.get('private_key') and not row.get('private_key_hex'),
                    'redacted retained storage inventory required')
            identity = row.get('id')
            require(isinstance(identity, str) and identity not in checkpoint['escrows'],
                    'unique retained storage identity required')
            if 'runtime' not in row and row.get('active') is False:
                require(row.get('settlement_pending', False) is False,
                        'inactive settlement must not be pending')
                checkpoint['escrows'][identity] = {'persisted': dict(row), 'session': None}
                continue
            runtime = row.get('runtime')
            require(isinstance(runtime, dict) and runtime.get('id') == identity,
                    'retained session binding required')
            session = {key: runtime.get(key) for key in ('nonce', 'balance', 'session_version')}
            require(type(session['nonce']) is int and session['nonce'] >= 0
                    and type(session['balance']) is int and session['balance'] >= 0
                    and session['session_version'] == 'v5', 'qualified retained session accounting required')
            checkpoint['escrows'][identity] = {
                'persisted': {key: value for key, value in row.items() if key != 'runtime'},
                'session': session}
        self.read_ledgers(checkpoint)

    def compose_command(self, *arguments):
        return ['docker', 'compose', '--project-name', self.project, '--file', str(self.compose), *arguments]

    def verify_runtime(self, identity, image, volume):
        require(identity == self.identity, 'instance differs')
        document = json.loads(self.read_compose(), object_pairs_hook=settings.instances.preview.unique_object)
        require(document.get('name') == self.project, 'Compose project differs')
        require(document['services']['gateway'].get('env_file') ==
                [{'path': str(self.secret_file), 'format': 'raw'}], 'native key binding differs')
        ids = self.command(self.compose_command('ps', '--all', '--quiet', 'gateway')).split()
        require(len(ids) == 1 and all(char in '0123456789abcdef' for char in ids[0]),
                'exactly one native container required')
        template = ('{"image":{{json .Config.Image}},"running":{{json .State.Running}},'
                    '"mounts":{{json .Mounts}},"labels":{{json .Config.Labels}},'
                    '"ports":{{json .NetworkSettings.Ports}},"environment":["selected"'
                    '{{range .Config.Env}}{{if or (eq . "DEVSHARD_CHAIN_ID=gonka-devnet-community") '
                    '(eq . "DEVSHARD_ROUTE_PREFIX=/devshard/v5") '
                    '(eq . "DEVSHARD_CHAT_CACHE_MAX_BYTES=1")}},{{json .}}{{end}}{{end}}]}')
        state = json.loads(self.command(['docker', 'inspect', '--format', template, ids[0]]))
        require(state['image'] == image and state['running'] is True, 'qualified running image required')
        labels = state['labels']
        require(labels.get('com.docker.compose.project') == self.project
                and labels.get('com.docker.compose.service') == 'gateway'
                and labels.get('org.gonka.test-lab.instance') == identity, 'container binding differs')
        mounts = state['mounts']
        require(len(mounts) == 1 and mounts[0].get('Type') == 'volume'
                and mounts[0].get('Name') == volume and mounts[0].get('Destination') == '/root/.devshardctl'
                and mounts[0].get('RW') is True, 'retained state volume differs')
        require(state['ports'].get('8080/tcp') == [{'HostIp': '127.0.0.1', 'HostPort': str(self.port)}],
                'private API listener differs')
        environment = state['environment']
        require('DEVSHARD_CHAIN_ID=gonka-devnet-community' in environment
                and 'DEVSHARD_ROUTE_PREFIX=/devshard/v5' in environment,
                'running chain and protocol differ')
        expected_cap = document['services']['gateway']['environment'].get('DEVSHARD_CHAT_CACHE_MAX_BYTES') == '1'
        require(('DEVSHARD_CHAT_CACHE_MAX_BYTES=1' in environment) == expected_cap,
                'running cache cap differs from Compose')

    def replace_compose(self, before, desired):
        require(self.read_compose() == before, 'Compose preimage changed')
        original = self.compose.stat()
        descriptor, path = tempfile.mkstemp(prefix='.cache-policy-', dir=self.directory)
        temporary = Path(path)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                os.fchmod(stream.fileno(), stat.S_IMODE(original.st_mode))
                os.fchown(stream.fileno(), original.st_uid, original.st_gid)
                stream.write(desired)
                stream.flush()
                os.fsync(stream.fileno())
            require(self.read_compose() == before, 'Compose changed before replace')
            os.replace(temporary, self.compose)
            directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if temporary.exists():
                temporary.unlink()

    def recreate(self, identity):
        require(identity == self.identity, 'instance differs')
        self.command(self.compose_command('up', '--detach', '--no-deps', '--force-recreate', 'gateway'), timeout=120)
        self.wait_ready()

    def wait_ready(self, timeout=90, clock=time.monotonic, wait=time.sleep):
        """Only retry read-only GET on proven listener refusal after recreation.

        Authentication, response/schema errors and operation timeouts abort
        POST, compose dispatch and inference are never repeated here
        """
        require(type(timeout) in (int, float) and 1 <= timeout <= 120, 'invalid readiness deadline')
        deadline = clock() + timeout
        previous_budget = getattr(self, '_read_deadline', None)
        self._read_deadline = (deadline, clock)
        try:
            while clock() < deadline:
                try:
                    response = self.read_settings()
                except ListenerUnavailable:
                    remaining = deadline - clock()
                    if remaining > 0:
                        wait(min(0.5, remaining))
                else:
                    require(clock() < deadline, 'private listener readiness deadline exceeded after read')
                    require(isinstance(response, dict), 'invalid settings readiness response')
                    return
        finally:
            self._read_deadline = previous_budget
        raise ValueError('private listener readiness deadline exceeded, gateway remains fenced')
