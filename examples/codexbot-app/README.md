# Codex Bot Pest Tests

## Install

```bash
cd vhttpd/examples/codexbot-app
composer install
```

## Run

```bash
cd vhttpd/examples/codexbot-app
composer test
```

Notes:
- This suite uses a temporary sqlite database via `VHTTPD_BOT_DB_PATH`.
- The test target is `../codexbot-app.php` and `codex.sql`.
