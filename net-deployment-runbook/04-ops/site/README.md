# Public status site JavaScript

The human-maintained source is in `src/` and uses Flow types

The runbook deploys the generated browser-native files from this directory
They remain formatted and readable, while production deployment does not need
Babel, Flow or a Node.js runtime

- `app.js` renders participants, the validator map and gateway health
- `gateway-state.js` converts gateway and probe payloads into public states
- `software-versions.js` formats component versions
- `config.js` documents the rendered configuration contract

Validate the Flow source and confirm that generated files are current:

```sh
make site-js-check
```

After editing a source file, format it and regenerate the browser files:

```sh
npx --yes prettier@3.6.2 --write 04-ops/site/src/*.js
make site-js
```
