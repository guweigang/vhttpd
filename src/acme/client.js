// vhttpd supplies URL-scoped ACME I/O and keeps account and TLS files private.
const acmeText = (value) => new TextEncoder().encode(value);
const acmeBytes = (value) => Uint8Array.from(value.match(/../g), (byte) => parseInt(byte, 16));
const acmeSigning = { name: "ECDSA", hash: "SHA-256" };
const acmeCurve = { name: "ECDSA", namedCurve: "P-256" };

function acmeJoin(...parts) {
  const result = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function acmeDer(tag, ...parts) {
  const body = acmeJoin(...parts);
  const length = body.length < 128 ? [body.length] :
    body.length < 256 ? [0x81, body.length] : [0x82, body.length >> 8, body.length & 255];
  return acmeJoin(Uint8Array.from([tag, ...length]), body);
}

const acmeSeq = (...parts) => acmeDer(0x30, ...parts);
const acmeOid = (value) => acmeDer(0x06, acmeBytes(value));
const acmeBits = (bytes) => acmeDer(0x03, Uint8Array.of(0), bytes);
const acmeB64 = (value) => Buffer.from(value).toString("base64");
const acmeUrl64 = (value) => acmeB64(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const acmeJson64 = (value) => acmeUrl64(acmeText(JSON.stringify(value)));

function acmeDerInt(value) {
  let offset = 0;
  while (offset < value.length - 1 && value[offset] === 0) offset++;
  const bytes = value.slice(offset);
  return acmeDer(0x02, bytes[0] & 128 ? acmeJoin(Uint8Array.of(0), bytes) : bytes);
}

async function acmeCsr(domain, keys, spki) {
  const subject = acmeSeq(acmeDer(0x31, acmeSeq(acmeOid("550403"), acmeDer(0x0c, acmeText(domain)))));
  const san = acmeSeq(acmeOid("551d11"), acmeDer(0x04, acmeSeq(acmeDer(0x82, acmeText(domain)))));
  const attributes = acmeDer(0xa0, acmeSeq(acmeOid("2a864886f70d01090e"), acmeDer(0x31, acmeSeq(san))));
  const request = acmeSeq(acmeDer(0x02, Uint8Array.of(0)), subject, spki, attributes);
  const signature = new Uint8Array(await crypto.subtle.sign(acmeSigning, keys.privateKey, request));
  if (signature.length !== 64) throw new Error("invalid Web Crypto ES256 signature size");
  const derSignature = acmeSeq(acmeDerInt(signature.slice(0, 32)), acmeDerInt(signature.slice(32)));
  return acmeUrl64(acmeSeq(request, acmeSeq(acmeOid("2a8648ce3d040302")), acmeBits(derSignature)));
}

function acmeRead(bytes, cursor) {
  const start = cursor.offset;
  if (start + 2 > bytes.length) throw new Error("truncated certificate DER");
  const tag = bytes[cursor.offset++];
  let length = bytes[cursor.offset++];
  if (length & 128) {
    const width = length & 127;
    if (width < 1 || width > 3 || cursor.offset + width > bytes.length) throw new Error("invalid certificate DER length");
    length = 0;
    for (let i = 0; i < width; i++) length = length * 256 + bytes[cursor.offset++];
  }
  const end = cursor.offset + length;
  if (end > bytes.length) throw new Error("truncated certificate DER value");
  const body = bytes.slice(cursor.offset, end);
  cursor.offset = end;
  return { tag, body, encoded: bytes.slice(start, end) };
}

function acmeItems(bytes) {
  const cursor = { offset: 0 };
  const items = [];
  while (cursor.offset < bytes.length) items.push(acmeRead(bytes, cursor));
  return items;
}

function acmeTime(item) {
  const text = new TextDecoder().decode(item.body);
  const width = item.tag === 0x17 ? 2 : 4;
  if (![0x17, 0x18].includes(item.tag) || text.length !== width + 11 || !/^\d+Z$/.test(text)) {
    throw new Error("unsupported X.509 validity time");
  }
  let year = Number(text.slice(0, width));
  if (width === 2) year += year < 50 ? 2000 : 1900;
  const part = (offset) => Number(text.slice(width + offset, width + offset + 2));
  const [month, day, hour, minute, second] = [part(0), part(2), part(4), part(6), part(8)];
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day ||
      date.getUTCHours() !== hour || date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second) {
    throw new Error("invalid X.509 validity time");
  }
  return date.getTime() / 1000;
}

globalThis.acmeCertificateInfo = (pem, domain, expectedSpki) => {
  const leaf = pem.match(/-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----/);
  if (!leaf) throw new Error("certificate chain does not contain a leaf");
  const certificate = acmeItems(Buffer.from(leaf[1].replace(/\s/g, ""), "base64"));
  const fields = acmeItems(acmeItems(certificate[0].body)[0].body);
  if (fields[0].tag === 0xa0) fields.shift();
  const validity = acmeItems(fields[3].body);
  if (expectedSpki && acmeB64(fields[5].encoded) !== expectedSpki) throw new Error("certificate public key differs from CSR");
  const wrappedExtensions = fields.find((field) => field.tag === 0xa3);
  const extensions = wrappedExtensions ? acmeItems(acmeItems(wrappedExtensions.body)[0].body) : [];
  const san = extensions.map((extension) => acmeItems(extension.body)).find(
    (extension) => acmeB64(extension[0].body) === "VR0R",
  );
  const names = san ? acmeItems(acmeItems(san[san.length - 1].body)[0].body) : [];
  if (!names.some((name) => name.tag === 0x82 && new TextDecoder().decode(name.body).toLowerCase() === domain)) {
    throw new Error("certificate SAN does not include the configured domain");
  }
  return { not_before: acmeTime(validity[0]), not_after: acmeTime(validity[1]) };
};

async function acmeIssue(options, savedAccount) {
  const request = (method, url, data = "") => JSON.parse(acmeRequest(method, url, data));
  const expect = (response, step) => {
    if (response.status >= 200 && response.status < 300) return response;
    let problem = "";
    try { problem = JSON.parse(response.body).type || ""; } catch {}
    throw new Error("ACME " + step + " failed: HTTP " + response.status + " " + problem);
  };
  const directory = JSON.parse(expect(request("GET", options.directory), "directory").body);
  let account = savedAccount ? JSON.parse(savedAccount) : null;
  if (account && account.directory !== options.directory) throw new Error("saved ACME account uses a different directory");
  if (!account) {
    const keys = await crypto.subtle.generateKey(acmeCurve, true, ["sign", "verify"]);
    account = { directory: options.directory, key: await crypto.subtle.exportKey("jwk", keys.privateKey), kid: "" };
    acmeSaveAccount(JSON.stringify(account));
  }
  const key = await crypto.subtle.importKey("jwk", account.key, acmeCurve, false, ["sign"]);
  const { crv, kty, x, y } = account.key;
  const jwk = { crv, kty, x, y };
  let nonce;
  const post = async (url, payload, step, useJwk = false) => {
    if (typeof url !== "string" || !url) throw new Error("missing ACME URL for " + step);
    for (let retry = 0; retry < 3; retry++) {
      if (!nonce) nonce = expect(request("HEAD", directory.newNonce), "nonce").nonce;
      if (!nonce) throw new Error("ACME response has no replay nonce");
      const protectedHeader = { alg: "ES256", nonce, url, ...(useJwk ? { jwk } : { kid: account.kid }) };
      const protectedValue = acmeJson64(protectedHeader);
      const payloadValue = payload === null ? "" : acmeJson64(payload);
      const signature = new Uint8Array(await crypto.subtle.sign(acmeSigning, key, acmeText(protectedValue + "." + payloadValue)));
      if (signature.length !== 64) throw new Error("invalid Web Crypto ES256 signature size");
      const response = request("POST", url, JSON.stringify({
        protected: protectedValue, payload: payloadValue, signature: acmeUrl64(signature),
      }));
      nonce = response.nonce;
      if (response.status === 400 && response.body.includes("urn:ietf:params:acme:error:badNonce")) continue;
      return expect(response, step);
    }
    throw new Error("ACME rejected three replay nonces");
  };
  const poll = async (url, step, complete) => {
    const deadline = Date.now() + 90000;
    while (Date.now() < deadline) {
      const response = await post(url, null, step);
      const value = JSON.parse(response.body);
      if (complete(value.status)) return value;
      if (!["pending", "processing", "ready"].includes(value.status)) {
        throw new Error("ACME " + step + " reached status " + value.status);
      }
      const seconds = /^\d+$/.test(response.retry_after) ? Number(response.retry_after) :
        (Date.parse(response.retry_after) - Date.now()) / 1000;
      acmeSleep(Math.min(30000, Math.max(1000, (Number.isFinite(seconds) ? seconds : 1) * 1000)));
    }
    throw new Error("ACME " + step + " polling timed out");
  };

  if (!account.kid) {
    const payload = { termsOfServiceAgreed: true };
    if (options.email) payload.contact = ["mailto:" + options.email];
    const response = await post(directory.newAccount, payload, "new account", true);
    if (!response.location) throw new Error("new ACME account has no Location");
    account.kid = response.location;
    acmeSaveAccount(JSON.stringify(account));
  }
  const orderReply = await post(directory.newOrder, {
    identifiers: [{ type: "dns", value: options.domain }],
  }, "new order");
  const order = JSON.parse(orderReply.body);
  for (const url of order.authorizations) {
    const authorization = JSON.parse((await post(url, null, "authorization")).body);
    if (authorization.identifier?.type !== "dns" || authorization.identifier.value !== options.domain || authorization.wildcard) {
      throw new Error("unexpected ACME authorization identifier");
    }
    if (authorization.status === "valid") continue;
    const challenge = authorization.challenges.find((item) => item.type === "http-01");
    if (!challenge || !/^[A-Za-z0-9_-]{1,256}$/.test(challenge.token)) throw new Error("no usable HTTP-01 challenge");
    const thumbprint = acmeUrl64(await crypto.subtle.digest("SHA-256", acmeText(JSON.stringify(jwk))));
    acmeChallenge(challenge.token, challenge.token + "." + thumbprint);
    try {
      await post(challenge.url, {}, "HTTP-01");
      await poll(url, "authorization", (status) => status === "valid");
    } finally {
      acmeChallenge("", "");
    }
  }
  const ready = await poll(orderReply.location, "order readiness", (status) => status === "ready");
  const tlsKeys = await crypto.subtle.generateKey(acmeCurve, true, ["sign", "verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", tlsKeys.publicKey));
  const csr = await acmeCsr(options.domain, tlsKeys, spki);
  await post(ready.finalize, { csr }, "finalize");
  const valid = await poll(orderReply.location, "certificate issuance", (status) => status === "valid");
  const chain = (await post(valid.certificate, null, "download certificate")).body;
  const dates = acmeCertificateInfo(chain, options.domain, acmeB64(spki));
  if (dates.not_after <= Date.now() / 1000 || dates.not_after <= dates.not_before) {
    throw new Error("issued certificate has invalid expiry");
  }
  const privateKey = acmeB64(await crypto.subtle.exportKey("pkcs8", tlsKeys.privateKey));
  const pem = chain.trim() + "\n-----BEGIN PRIVATE KEY-----\n" +
    privateKey.match(/.{1,64}/g).join("\n") + "\n-----END PRIVATE KEY-----\n";
  return { pem, ...dates };
}

globalThis.acmeIssue = acmeIssue;
