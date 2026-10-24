#!/usr/bin/env bash
# Entry point for running all e2e tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== vhttpd E2E Test Suite ==="
echo ""

node --test --test-concurrency=1 "${SCRIPT_DIR}/../../examples/wechat-cloud-functions/tests/unit.test.mjs" "${SCRIPT_DIR}/../../examples/wechat-cloud-functions/tests/miniprogram.test.mjs"
node --test "${SCRIPT_DIR}/logging_contract_test.mjs"
node --test "${SCRIPT_DIR}/../protocol/feishu-stream-generation.test.mjs"
php "${SCRIPT_DIR}/../protocol/feishu-generation-receipt.php"
php "${SCRIPT_DIR}/../protocol/feishu-message-update.php"
php "${SCRIPT_DIR}/../protocol/feishu-one-shot-reply.php"
node --test "${SCRIPT_DIR}/../protocol/feishu-one-shot-reply.test.mjs"
python3 "${SCRIPT_DIR}/executor_lane_warmup_probe_test.py"
python3 "${SCRIPT_DIR}/executor_lane_warmup_probe.py"
node --test "${SCRIPT_DIR}/provider_ws_upstream_probe_test.mjs"
node --test "${SCRIPT_DIR}/managed_worker_pid_lifecycle_test.mjs"
node --test "${SCRIPT_DIR}/pid_file_lifecycle_test.mjs"
node --test "${SCRIPT_DIR}/admin_browser_login_test.mjs"
node --test "${SCRIPT_DIR}/feishu_external_creation_test.mjs"
node --test "${SCRIPT_DIR}/feishu_bridge_revocation_test.mjs"
node --test "${SCRIPT_DIR}/feishu_bridge_capacity_test.mjs"
node --test "${SCRIPT_DIR}/feishu_bridge_queue_test.mjs"
node --test "${SCRIPT_DIR}/feishu_sent_publication_test.mjs"
node --test "${SCRIPT_DIR}/feishu_message_update_test.mjs"
node --test "${SCRIPT_DIR}/feishu_one_shot_reply_test.mjs"
php "${SCRIPT_DIR}/../../php/package/tests/feishu_creation_test.php"
node --test "${SCRIPT_DIR}/admin_http_metrics_test.mjs"
node --test "${SCRIPT_DIR}/../admin-ui/"*.test.cjs
node --test "${SCRIPT_DIR}/admin_common_config_test.mjs"
node --test "${SCRIPT_DIR}/admin_relay_config_test.mjs"
node --test "${SCRIPT_DIR}/admin_relay_cross_include_test.mjs"
node --test "${SCRIPT_DIR}/relay_connection_identity_test.mjs"
php "${SCRIPT_DIR}/../../php/package/tests/stream_dispatch_example_test.php"
bash "${SCRIPT_DIR}/smoke_test.sh"
bash "${SCRIPT_DIR}/config_acceptance_test.sh"

echo ""
echo "=== All E2E tests passed ==="
