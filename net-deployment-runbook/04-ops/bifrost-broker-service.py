#!/usr/bin/env python3
"""Start the private Telegram-to-Bifrost key broker from managed environment."""
import os
import argparse
from pathlib import Path

from bifrost_key_broker import BifrostClient, Broker, serve


def env_file(path):
    values = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if not sep or not key or key in values:
            raise ValueError("invalid private broker binding file")
        values[key] = value
    return values


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} is required")
    return value


binding = env_file(required("BIFROST_BROKER_BINDING_FILE"))
client = BifrostClient(
    required("BIFROST_MANAGEMENT_URL"), required("BIFROST_ADMIN_USERNAME"), required("BIFROST_ADMIN_PASSWORD"),
    binding["BIFROST_GONKA_PROVIDER"], binding["BIFROST_GONKA_MODEL"], binding["BIFROST_GONKA_KEY_ID"],
)
broker = Broker(required("BIFROST_BROKER_DB"), client, required("BIFROST_BROKER_ENCRYPTION_KEY").encode())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--write-health-env', type=Path, help='offline operator action; create a private probe env without serving HTTP')
args = parser.parse_args()
if args.write_health_env:
    model = binding['BIFROST_GONKA_MODEL']
    if '\n' in model or '\r' in model:
        raise ValueError('invalid health model')
    # Never expose the key through stdout, process arguments or a public API.
    # Refuse an existing destination before issuing any new management request.
    fd = os.open(args.write_health_env, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        key = broker.ensure_health_key()
        output.write('DEVSHARD_API_KEYS=' + key + '\nDEVSHARD_MODEL=' + model + '\n')
        output.flush()
        os.fsync(output.fileno())
    broker.db.close()
    print('Private operator health configuration created')
else:
    serve(
        broker, required("BIFROST_BROKER_TOKEN"), required("BIFROST_BROKER_HOST"), int(required("BIFROST_BROKER_PORT")),
        required("BIFROST_EDGE_TOKEN"),
    ).serve_forever()
