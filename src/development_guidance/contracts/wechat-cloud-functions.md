# WeChat cloud compatibility applications

The `wechat-cloud-functions` Desktop template ships the repository's compatibility library with the application. Inspect the bound `lib/cloud` sources and the selected runtime's vjsx contract before choosing an API.

## Create or adopt

For an empty workspace, install the template through `application_install_prepare` and `application_install_apply`. The component includes `app.mjs`, `cloudfunctions/hello/index.js`, `lib/application.mjs`, `lib/cloud/*.mjs`, SQL schema files and `client/vhttpd.js`.

For an existing application, inventory its cloud functions and dependencies first. Retain its application ID, function files and component entry. Compare its compatibility library with the template's shipped sources and prepare only the required changes. Function entries use CommonJS `exports.main`. The loader supplies `require('wx-server-sdk')` and supported Node compatibility modules. It rejects ESM or package exports in cloud-function dependencies. Inspect `lib/cloud/loader.mjs` for the exact supported module contract.

## Server API and identity

The runtime supplies `cloud.init`, `cloud.getWXContext`, `cloud.callFunction` and `cloud.database`. Init and database options accept the implemented `env` and `throwOnNotFound` fields. Function calls accept `name`, object `data` and supported `config` fields. Function calls within an active database transaction are rejected.

The bundled database implementation supports collection and document operations, bounded queries, mutations and `runTransaction`. Read `lib/cloud/database.mjs` for supported predicates and mutation commands. Field projections, aggregation, watch, nested transactions, `startTransaction`, `serverDate` and explicit collection creation return `NOT_SUPPORTED`.

Storage methods require configured storage. Read `lib/cloud/storage.mjs` for upload, download, delete and temporary URL options and limits. Unsupported options fail explicitly. `cloud.openapi` calls return `NOT_SUPPORTED`. Preserve structured error codes when diagnosing compatibility failures.

## Verify and release

GET `/healthz` invokes the bundled hello function using a diagnostic identity. It verifies function loading and SDK invocation. Authenticated business verification additionally needs WeChat application credentials, the configured database resource and matching SQL schema. Credentials belong in the target configuration managed through Desktop. The health probe's identity is for that probe.

The supplied client supports login, function calls and storage calls against the vhttpd HTTPS service. Inspect `client/vhttpd.js` for callback, Promise and session behavior. Check POST `/auth/login` and POST `/functions/<name>` with an authorized test account when login is configured. Record separately which database and storage operations were exercised.

Use the revision workflow and verify the real function response. Over Relay, wait for `runtime_status.readiness` after start acceptance. Release the entire component, including compatibility libraries and function dependencies, with the application release tools. Verify the same function remotely, then verify the restored version after rollback.
