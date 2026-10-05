#!/usr/bin/env python3
"""Real installed agent in disposable Host layouts, synthetic Docker transport."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "gdc-runtime-monitoring-fixture:%s" % os.getpid()
CODE = r'''
import importlib.util,json,os,pathlib,subprocess
root=pathlib.Path('/tmp/runtime-monitoring')
root.mkdir()
tools=root/'bin';tools.mkdir()
dispatcher=tools/'dispatch'
dispatcher.write_text(r"""#!/usr/bin/env python3
import importlib.util,json,os,pathlib,subprocess,sys
root=pathlib.Path('/tmp/runtime-monitoring')
args=sys.argv[1:];kind=pathlib.Path(sys.argv[0]).name
scenario=(root/'scenario').read_text()
container='a'*64
def require(ok):
    if not ok:
        (root/'unexpected').write_text(json.dumps([kind,args]))
        raise SystemExit(97)
if kind=='systemctl':
    require(args in [['daemon-reload'],['enable','--now','gdc-version-collector@fixture.timer'],['start','gdc-version-collector@fixture.service']])
    if args[0]=='start':
        raise SystemExit(subprocess.run(['/usr/local/libexec/gdc-collect-versions','fixture']).returncode)
elif kind=='curl':
    require(args==['-fsS','--max-time','10','http://127.0.0.1:8000/v1/versions'])
    print(json.dumps({'api_version':{'application_name':'api','version':'0.2.14','commit':'fixture'},'node_version':{'application_name':'node','version':'0.2.14','commit':'fixture'},'mlnodes':[]}))
elif kind=='docker':
    if args[:1]==['ps']:
        require(len(args)==7 and args[1:3]==['--filter','label=com.docker.compose.project=fixture'] and args[3]=='--filter' and args[-2:]==['--format','{{.ID}}'])
        component=args[4].removeprefix('label=com.docker.compose.service=')
        require(component in ['tmkms','node','api','mlnode','versiond','explorer','proxy'])
        if scenario=='docker-unavailable': raise SystemExit(1)
        if scenario=='docker-partial':
            if component=='versiond': print(container)
            raise SystemExit(1)
        if scenario=='ambiguous' and component=='versiond': print('c'*64)
        if component=='versiond': print(container)
    elif args[:2]==['inspect','--format']:
        require(args[-1]==container or (scenario=='ambiguous' and args[2]=='{{.Config.Image}}' and args[-1]=='c'*64))
        if args[2]=='{{.Config.Image}}': print('official-fixture/versiond:0.2.14')
        else:
            require(args[2]=='{{json .Id}}\n{{json .Config.Image}}\n{{json .State.Running}}')
            print(json.dumps(container));print(json.dumps('official-fixture/versiond:0.2.14'));print('true')
    elif args[:2]==['exec',container]:
        if args[2:]==['wget','-qO-','-T','5','http://127.0.0.1:8080/healthz']:
            if scenario=='failed': raise SystemExit(1)
            print(json.dumps([{'name':'v5','status':'stopped' if scenario=='stopped' else 'running','port':5002}]))
        elif len(args)==5 and args[2:4]==['sh','-c']:
            # The installed executable has no .py suffix.
            from importlib.machinery import SourceFileLoader
            loader=SourceFileLoader('runtime','/usr/local/libexec/gdc-inspect-devshard-runtime')
            spec=importlib.util.spec_from_loader('runtime',loader)
            module=importlib.util.module_from_spec(spec);loader.exec_module(module)
            require(args[4]==module.PROBE)
            if scenario!='stopped': print('321\t/opt/versiond/bin/v5/devshardd\t999\t'+'b'*64)
        else:
            require(len(args)==7 and args[2:4]==['sh','-c'] and 'exec timeout 5 "$1" --print-binary-version' in args[4] and args[5:]==['sh','/proc/321/exe'])
            print('v5.0.2')
    else: require(False)
else: require(False)
""")
dispatcher.chmod(0o755)
for name in ['systemctl','curl','docker','ssh','scp','rsync']:
    (tools/name).symlink_to(dispatcher)
environment=dict(os.environ,PATH=str(tools)+':/usr/local/bin:/usr/bin:/bin',PYTHONDONTWRITEBYTECODE='1')
env=root/'agent.env';env.write_text('GDC_MONITOR_HOST=fixture\n')
metrics=pathlib.Path('/var/lib/node_exporter/textfile_collector/gdc-component-versions.prom')
for layout in ['flat','legacy']:
    host=pathlib.Path('/srv/dai/deploy')
    if layout=='legacy':host=host/'fixture'
    host.mkdir(parents=True,exist_ok=True)
    marker=host/'identity-retained';marker.write_bytes(b'retained Host state')
    (root/'scenario').write_text('running')
    subprocess.run(['bash','/workspace/04-ops/agent/install-agent.sh','fixture',str(env)],check=True,env=environment)
    before=metrics.read_text()
    assert 'version="v5.0.2"' in before and 'binary_sha256="'+'b'*64+'"' in before
    assert 'archive_sha256="unreported"' in before and 'source="process"' in before
    assert '/opt/' not in before and 'start_ticks' not in before
    for scenario in ['running','docker-unavailable','running','docker-partial','running','ambiguous','running','failed','running','stopped','running']:
        (root/'scenario').write_text(scenario)
        subprocess.run(['/usr/local/libexec/gdc-collect-versions','fixture'],check=True,env=environment)
        observed=metrics.read_text()
        assert ('gdc_devshard_runtime_info' in observed)==(scenario=='running')
        assert ('gdc_devshard_runtime_scrape_success{host="fixture"} 0' in observed)==(scenario in ['failed','docker-unavailable','docker-partial','ambiguous'])
        assert marker.read_bytes()==b'retained Host state'
        assert not (root/'unexpected').exists(), (root/'unexpected').read_text()
print('PASS installed agent, flat/legacy Host retention, observed binary identity and failed/stopped/recovery collection, synthetic Docker transport')
'''

try:
    subprocess.run(["docker", "build", "--pull=false", "-f", str(ROOT / "test/Dockerfile"),
                    "-t", IMAGE, str(ROOT)], check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run(["docker", "run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL",
                    "--cap-add=CHOWN", "--cap-add=DAC_OVERRIDE", "--cap-add=FOWNER",
                    "--security-opt=no-new-privileges", "--user=0",
                    "--tmpfs=/tmp:rw,exec,nosuid,size=128m", "--tmpfs=/srv:rw,nosuid,size=128m",
                    "--tmpfs=/usr/local/libexec:rw,exec,nosuid,size=16m",
                    "--tmpfs=/etc/systemd/system:rw,nosuid,size=16m",
                    "--tmpfs=/var/lib/node_exporter:rw,nosuid,size=16m",
                    "--entrypoint=python3", IMAGE, "-c", CODE], capture_output=True, text=True)
    print(result.stdout, end="")
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
finally:
    subprocess.run(["docker", "image", "rm", IMAGE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
