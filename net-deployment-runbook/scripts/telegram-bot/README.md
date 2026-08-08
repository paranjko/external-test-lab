# Telegram API-key issuer

This is the source for the Community DevNet Telegram long-polling issuer. It
runs on the configured gateway host during one-participant bootstrap and moves
to the configured secondary-services host later. Gateway credentials and the finite authorised
key pool stay root-owned on the gateway host until deployment.

The bot assigns one key to each private Telegram account. `/key` is idempotent;
`/renew` replaces the assigned key only with another key that passes an actual
authenticated chat request. It never treats a direct MLNode response as gateway
proof.

## Operator setup

1. Create a BotFather bot and write its token to the runbook's root `.env`,
   created from the root `.env.example`. There is no bot-specific `.env`.
2. Generate the finite pool from the runbook secrets and install the resulting
   `gateway-key-pool.json` alongside that file. Do not commit either file.
3. Once the gateway is active, deploy the source and the two runtime secrets:

   ```bash
   ./gdc.sh telegram-bot
   ```

The deployment renders an internal `bot.env`, preserves the durable issuance
database on the target host, stops any old gateway-host poller, and verifies
both the Telegram identity and an authorised key before declaring success.
