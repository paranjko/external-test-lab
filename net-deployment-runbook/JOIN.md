# Community DevNet Join node runbook

## 1. Add ssh alias for Node

```bash
cat >> ~/.ssh/config <<EOL
Host gdc-my-node-full
  HostName <IP>
  Port <PORT> 
  User root
# or
Host gdc-my-node-net
  HostName <IP>
  Port <PORT> 
  User root
Host gdc-my-node-gpu
  HostName <IP>
  Port <PORT> 
  User root
EOL
```

## 2. Get join script

```bash
wget -o phase-join.sh https://github.com/paranjko/external-test-lab/raw/refs/heads/main/net-deployment-runbook/scripts/phase-join.sh
```

Optional verify script
```bash
gh attestation verify phase-join.sh -R paranjko/external-test-lab
```

## 3. Get join script

```bash
bash phase-join.sh gdc-my-node-full 2>&1 | tee phase-join.log
# or
bash phase-join.sh gdc-my-node-net gdc-my-node-gpu 2>&1 | tee phase-join.log
```

If you get some error, please create an issue with your log `phase-join.log` https://github.com/paranjko/external-test-lab/issues
