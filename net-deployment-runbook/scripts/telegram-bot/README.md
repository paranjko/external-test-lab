# Telegram API-key issuer

This is the source for the Community DevNet Telegram long-polling issuer. It
runs only on the secondary-services host. Gateway credentials and the finite
authorised key pool stay root-owned on the gateway host until deployment.

The bot assigns one key to each private Telegram account. `/key` is idempotent;
`/renew` replaces the assigned key only with another key that passes an actual
authenticated chat request. It never treats a direct MLNode response as gateway
proof.

## Operator setup

1. Create a BotFather bot and write its token to the root-owned runtime file
   `/srv/dai/gonka-devnet-bot/.env` on the gateway host, based on
   `.env.example`.
2. Generate the finite pool from the runbook secrets and install the resulting
   `gateway-key-pool.json` alongside that file. Do not commit either file.
3. Once the gateway is active, deploy the source and the two runtime secrets:

   ```bash
   ./gdc.sh telegram-bot
   ```

The deployment preserves the durable issuance database on the secondary host,
stops any old gateway-host poller, and verifies both the Telegram identity and
an authorised key before declaring success.
