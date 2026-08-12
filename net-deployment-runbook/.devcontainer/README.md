# JOIN cleanroom

```bash
make cleanroom cmd='ssh -T gdc-node1'
make cleanroom cmd='bash'
```

For an independent Host proof, run the join only from the recreated cleanroom
workspace and a dedicated operator home. The command imports the public
bootstrap; do not mount, copy, or reuse Genesis operator state:

```bash
make cleanroom cmd='GDC_HOME=/workspaces/external-join ./gdc.sh host join <ssh-alias>'
```

Share only the resulting sanitized `join-acceptance-<ssh-alias>` bundle with a
public observer for Gate A. The cleanroom checks that the image and workspace
contain no `.env`, account/keyring, mnemonic, run, or generated runtime state;
it proves filesystem isolation, not a live independent-operator PASS by itself.
