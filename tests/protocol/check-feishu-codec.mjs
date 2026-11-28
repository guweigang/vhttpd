import fs from "node:fs";
import path from "node:path";
import { createRequire, Module } from "node:module";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
const require = createRequire(import.meta.url);
const filename = require.resolve("@larksuiteoapi/node-sdk");
const pkg = require("@larksuiteoapi/node-sdk/package.json");
assert.equal(pkg.version,"1.76.0", "Review oracle extraction when upgrading the official SDK");
const source = fs.readFileSync(filename,"utf8");
// The SDK does not export its generated protobuf codec. Expose the *official*
// implementation in a test-only Module; never ship this instrumentation.
assert.ok(source.includes("pbbp2.Frame"));
const instrumented = new Module(filename);
instrumented.filename = filename;
instrumented.paths = Module._nodeModulePaths(path.dirname(filename));
instrumented._compile(source + "\nmodule.exports.__codecOracle = pbbp2.Frame;\n", filename);
const Frame = instrumented.exports.__codecOracle;
const driver = process.argv[2];
if (!driver) throw Error("Usage: node check-feishu-codec.mjs /absolute/path/to/native-driver");
const native = (input) => execFileSync(driver, [], {input:JSON.stringify(input)+"\n",encoding:"utf8",timeout:10000}).trim();
const fixtures = [
  {SeqID:0,LogID:0,service:0,method:0,headers:[]},
  {SeqID:42,LogID:7,service:3,method:1,headers:[{key:"type",value:"event"},{key:"trace_id",value:"test"}],payload:Buffer.from('{"test":true}'),LogIDNew:"log-test"},
  {SeqID:1,LogID:0,service:9,method:0,headers:[{key:"type",value:"ping"},{key:"empty",value:""}]},
];
for (const fixture of fixtures) {
  const encoded = Buffer.from(Frame.encode(fixture).finish());
  const decoded = JSON.parse(native({operation:"decode",hex:encoded.toString("hex")}));
  assert.equal(decoded.seq_id,fixture.SeqID);
  assert.equal(decoded.log_id,fixture.LogID);
  assert.equal(decoded.service,fixture.service);
  assert.equal(decoded.method,fixture.method);
  assert.deepEqual(decoded.headers,fixture.headers);
  assert.deepEqual(decoded.payload,Array.from(fixture.payload || []));
  const output = native({operation:"encode",frame:decoded});
  const oracle = Frame.toObject(Frame.decode(Buffer.from(output,"hex")),{longs:Number,bytes:Array});
  assert.equal(oracle.SeqID,fixture.SeqID);
  assert.equal(oracle.LogID,fixture.LogID);
  assert.equal(oracle.method,fixture.method);
  assert.deepEqual(oracle.headers || [],fixture.headers);
  for (const operation of ["ack","pong"]) {
    const callback = {toast:{type:"success",content:"protocol test"},card:{type:"raw",data:{elements:[]}}};
    const reply = Frame.decode(Buffer.from(native({operation,response:JSON.stringify(callback),hex:encoded.toString("hex")}),"hex"));
    if (operation === "ack") {
      const payload = JSON.parse(Buffer.from(reply.payload).toString("utf8"));
      assert.equal(payload.code,200);
      assert.deepEqual(JSON.parse(Buffer.from(payload.data,"base64").toString("utf8")),callback);
    }
    assert.equal(Number(reply.SeqID),fixture.SeqID);
    assert.equal(Number(reply.LogID),fixture.LogID);
  }
}
for (const hex of ["", "0800", "0880"]) {
  assert.throws(() => Frame.decode(Buffer.from(hex,"hex")));
  assert.throws(() => native({operation:"decode",hex}));
}
console.log(`Feishu bidirectional codec/ACK/pong differential passed: official SDK ${pkg.version}, sha256 ${createHash("sha256").update(source).digest("hex")}`);
