import test from "node:test";
import assert from "node:assert/strict";
import {cardCallbackResponse} from "../feishu/callback.mjs";
test("modern Feishu card callback wraps a raw replacement card", () => {
  const card = {elements:[{tag:"markdown",content:"审批已收尾"}]};
  assert.deepEqual(JSON.parse(cardCallbackResponse(JSON.stringify(card))),{card:{type:"raw",data:card}});
  assert.deepEqual(JSON.parse(cardCallbackResponse(card)),{card:{type:"raw",data:card}});
});
