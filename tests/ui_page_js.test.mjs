// lib/ui/page.js's parts that need no page: the body a command carries, where it goes, how a push's params read, and
// what deliver() does with the properties card's two commands.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const PAGE_JS = process.env.UI_PAGE_JS || "template/src/lib/ui/page.js";
const CODE = readFileSync(PAGE_JS, "utf8");

function load(search) {
  const posts = [];
  const timers = [];
  const ctx = {
    location: { search },
    // No page: every element lookup comes back empty.
    document: { getElementById: () => null },
    console,
    btoa,
    atob,
    setTimeout: (fn) => timers.push(fn),
    fetch: (url, opts) => {
      posts.push({ url, opts });
      return Promise.resolve({ json: () => Promise.resolve({}) });
    },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(CODE, ctx);
  return { ctx, posts, timers };
}

const decode = (data) => JSON.parse(decodeURIComponent(escape(atob(data.replace(/\n/g, "")))));

test("a command's body is UTF-8 base64 broken every 76 characters", () => {
  const { ctx } = load("?apihost=ctrl.example.invalid&driverid=42&apitoken=tok");
  const params = { text: "café 日本 💡 <a&b>", long: "x".repeat(500) };
  const body = ctx.encodeParams(params);
  const lines = body.split("\n");
  assert.ok(lines.length > 1);
  lines.slice(0, -1).forEach((line) => assert.equal(line.length, 76));
  assert.ok(lines[lines.length - 1].length <= 76);
  assert.deepEqual(decode(body), params);
});

test("sendCommand posts to the driver's commands with the token", async () => {
  const { ctx, posts } = load("?apihost=ctrl.example.invalid&driverid=42&apitoken=tok");
  await ctx.sendCommand("_SET_PROPERTY", { property: "Mode", value: "Auto" });
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, "https://ctrl.example.invalid/api/v1/items/42/commands");
  assert.equal(posts[0].opts.headers.Authorization, "Bearer tok");
  const body = JSON.parse(posts[0].opts.body);
  assert.equal(body.command, "_SET_PROPERTY");
  assert.equal(body.async, false);
  assert.deepEqual(decode(body.tParams.DATA), { property: "Mode", value: "Auto" });
});

test("an apihost with its own scheme is used as given", () => {
  const { ctx } = load("?apihost=" + encodeURIComponent("http://127.0.0.1:8765/") + "&driverid=1&apitoken=t");
  assert.equal(ctx.apiOrigin(), "http://127.0.0.1:8765");
});

test("outside Composer a command goes to the page's demo answer, later", () => {
  const { ctx, posts, timers } = load("");
  const answered = [];
  assert.equal(ctx.demoMode((command, params) => answered.push([command, params])), true);
  ctx.sendCommand("_GET_CONFIG");
  assert.equal(posts.length, 0);
  assert.equal(answered.length, 0);
  timers.forEach((fn) => fn());
  assert.deepEqual(answered.map(([command, params]) => [command, { ...params }]), [["_GET_CONFIG", {}]]);
});

test("a push's params read as one object", () => {
  const { ctx } = load("");
  const one = ctx.commandParams({ params: { param: { name: "payload", value: { static: "{}" } } } });
  assert.deepEqual({ ...one }, { payload: "{}" });
  const many = ctx.commandParams({ params: { param: [{ name: "a", value: "1" }, { name: "b" }, { value: "x" }] } });
  assert.deepEqual({ ...many }, { a: "1", b: "" });
  assert.deepEqual({ ...ctx.commandParams({}) }, {});
});

test("deliver feeds the properties card, then the page's handler", () => {
  const { ctx } = load("");
  const seen = [];
  ctx.gHandlers = { CONFIG_DATA: (params) => seen.push(params.config), BOOM: () => { throw new Error("x"); } };
  ctx.deliver("CONFIG_DATA", { config: "{}", properties: JSON.stringify([{ name: "Mode", value: "Off" }]) });
  assert.equal(ctx.gProps.list[0].name, "Mode");
  assert.deepEqual(seen, ["{}"]);
  ctx.deliver("PROPERTY_ERROR", { payload: JSON.stringify({ property: "Mode", error: "Mode has no choice Slow." }) });
  assert.equal(ctx.gProps.errors.Mode, "Mode has no choice Slow.");
  ctx.deliver("BOOM", {});
  ctx.deliver("UNHANDLED", {});
});

test("esc makes text safe for HTML", () => {
  const { ctx } = load("");
  assert.equal(ctx.esc(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  assert.equal(ctx.esc(null), "");
});
