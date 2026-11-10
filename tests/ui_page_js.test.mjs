// lib/ui/page.js on a stub page: the body a command carries and where it goes, a push as one object, the properties
// card's commands, calls and their answers, another item on the same link, the live-link and demo banners, the tabs
// in the address, the dev login, and that a page's own functions leave the kit's alone.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const UI_DIR = process.env.UI_DIR || "template/src/lib/ui";
const CODE = readFileSync(UI_DIR + "/page.js", "utf8");

/** An element that takes what the kit does to it. */
function element(tag) {
  const classes = new Set();
  return {
    tagName: tag,
    hidden: false,
    textContent: "",
    innerHTML: "",
    className: "",
    dataset: {},
    style: {},
    listeners: {},
    children: [],
    parentNode: null,
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      toggle: (c, on) => ((on ?? !classes.has(c)) ? classes.add(c) : classes.delete(c)),
      contains: (c) => classes.has(c),
    },
    addEventListener(type, fn) {
      this.listeners[type] = fn;
    },
    insertBefore(child) {
      this.children.unshift(child);
    },
    closest: () => null,
    contains: () => false,
  };
}

/** A socket.io connection the test drives: handlers by event, and what the kit emits. */
function stubSocket() {
  return {
    handlers: {},
    emitted: [],
    io: { engine: { id: "e1" } },
    on(ev, fn) {
      this.handlers[ev] = fn;
    },
    off() {},
    emit(...args) {
      this.emitted.push(args);
    },
    disconnect() {},
  };
}

/**
 * page.js loaded on a stub page at `search`. `answer(url)` answers each fetch's JSON; the default makes every
 * subscription at once, as "<item>/<path>".
 */
function load(search, { pageScript, answer, token, hash = "" } = {}) {
  const posts = [];
  const timers = [];
  const xhrs = [];
  const body = element("body");
  const socket = stubSocket();
  const document = {
    body,
    activeElement: null,
    createElement: element,
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const ctx = {
    location: { search, hash },
    history: { replaceState: (s, t, url) => (ctx.location.hash = url) },
    document,
    console,
    btoa,
    atob,
    io: { connect: () => socket },
    addEventListener() {},
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
    setInterval: (fn, ms) => timers.push({ fn, ms, every: true }),
    clearTimeout() {},
    XMLHttpRequest: class {
      open(method, url, sync) {
        xhrs.push({ method, url, sync });
      }
      setRequestHeader() {}
      send(body) {
        xhrs[xhrs.length - 1].body = body;
        this.responseText = JSON.stringify({ token });
      }
    },
    fetch: (url, opts) => {
      posts.push({ url, opts });
      const sub = url.match(/items\/(\w+)\/(datatoui|properties)\?/);
      const json = answer ? answer(url) : sub ? { subscriptionId: sub[1] + "/" + sub[2] } : {};
      return Promise.resolve({ json: () => Promise.resolve(json), text: () => Promise.resolve("") });
    },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(CODE, ctx);
  if (pageScript) vm.runInContext(pageScript, ctx);
  return { Kit: ctx.Kit, ctx, posts, timers, xhrs, socket, body };
}

const decode = (data) => JSON.parse(decodeURIComponent(escape(atob(data.replace(/\n/g, "")))));
const plain = (o) => JSON.parse(JSON.stringify(o));
const settle = () => new Promise((resolve) => setImmediate(resolve));
const ON_CONTROLLER = "?apihost=ctrl.example.invalid&driverid=42&apitoken=tok";
/** A push as the controller's socket delivers it, from lib.ui.page's send. */
const push = (command, data) => ({ data: { devicecommand: { command, params: { param: [{ name: "json", value: { static: JSON.stringify(data) } }] } } } });
const commands = (posts) => posts.filter((p) => p.url.endsWith("/commands")).map((p) => JSON.parse(p.opts.body).command);

test("a command's body is UTF-8 base64 broken every 76 characters", () => {
  const { Kit } = load(ON_CONTROLLER);
  const params = { text: "café 日本 💡 <a&b>", long: "x".repeat(500) };
  const body = Kit.encodeParams(params);
  const lines = body.split("\n");
  assert.ok(lines.length > 1);
  lines.slice(0, -1).forEach((line) => assert.equal(line.length, 76));
  assert.ok(lines[lines.length - 1].length <= 76);
  assert.deepEqual(decode(body), params);
});

test("sendCommand posts to the driver's commands with the token", async () => {
  const { Kit, posts } = load(ON_CONTROLLER);
  await Kit.sendCommand("_SET_PROPERTY", { property: "Mode", value: "Auto" });
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, "https://ctrl.example.invalid/api/v1/items/42/commands");
  assert.equal(posts[0].opts.headers.Authorization, "Bearer tok");
  const body = JSON.parse(posts[0].opts.body);
  assert.equal(body.command, "_SET_PROPERTY");
  assert.equal(body.async, false);
  assert.deepEqual(decode(body.tParams.DATA), { property: "Mode", value: "Auto" });
});

test("an apihost with its own scheme is used as given", async () => {
  const { Kit, posts } = load("?apihost=" + encodeURIComponent("http://127.0.0.1:8765/") + "&driverid=1&apitoken=t");
  await Kit.sendCommand("_GET_CONFIG");
  assert.equal(posts[0].url, "http://127.0.0.1:8765/api/v1/items/1/commands");
});

test("a page's own str, esc, api and sendCommand leave the kit's alone", async () => {
  const pageScript = `
    function str() { return "page"; }
    function esc() { return "page"; }
    function api() { throw new Error("page api"); }
    function sendCommand() { throw new Error("page sendCommand"); }
    var encodeParams = null;
  `;
  const { Kit, posts } = load(ON_CONTROLLER, { pageScript });
  assert.equal(Kit.esc("<b>"), "&lt;b&gt;");
  await Kit.sendCommand("_GET_CONFIG", { a: 1 });
  assert.equal(posts.length, 1);
  assert.deepEqual(decode(JSON.parse(posts[0].opts.body).tParams.DATA), { a: 1 });
});

test("outside Composer a command goes to the page's demo answer, later, and a component's own answer comes first", () => {
  const { Kit, posts, timers, body } = load("");
  const answered = [];
  assert.equal(Kit.demoMode((command, params) => answered.push(["page", command, params])), true);
  Kit.demoAnswer("_GET_DEVICES", (command) => answered.push(["kit", command]));
  Kit.sendCommand("_GET_CONFIG");
  Kit.sendCommand("_GET_DEVICES");
  assert.equal(posts.length, 0);
  assert.equal(answered.length, 0);
  timers.forEach((t) => t.fn());
  assert.deepEqual(plain(answered), [["page", "_GET_CONFIG", {}], ["kit", "_GET_DEVICES"]]);
  const demo = body.children.find((el) => el.className.includes("kit-demo"));
  assert.equal(demo.hidden, false, "the demo banner shows");
});

test("in demo mode connectDriver asks what a connect asks, and the demo answer reaches the page's handlers", () => {
  const { Kit, timers, posts } = load("");
  const card = element("div");
  Kit.initPropertiesCard(card);
  const seen = [];
  Kit.demoMode((command) => {
    if (command === "_GET_PROPERTIES") Kit.deliver("PROPERTIES", { properties: [{ name: "Mode", value: "Off" }] });
    if (command === "_GET_STATUS") Kit.deliver("STATUS", { text: "Connected" });
  });
  Kit.connectDriver({ handlers: { STATUS: (status) => seen.push(status.text) }, onConnect: () => Kit.sendCommand("_GET_STATUS") });
  while (timers.length) timers.shift().fn();
  assert.deepEqual(seen, ["Connected"]);
  assert.equal(Kit._properties.list[0].name, "Mode");
  assert.equal(posts.length, 0);
});

test("a push's params read as one object", () => {
  const { Kit } = load("");
  const one = Kit._commandParams({ params: { param: { name: "payload", value: { static: "{}" } } } });
  assert.deepEqual(plain(one), { payload: "{}" });
  const many = Kit._commandParams({ params: { param: [{ name: "a", value: "1" }, { name: "b" }, { value: "x" }] } });
  assert.deepEqual(plain(many), { a: "1", b: "" });
  assert.deepEqual(plain(Kit._commandParams({})), {});
});

test("a push reaches a component's listener, then the page's handler, as the object the driver sent", async () => {
  const { Kit, socket } = load(ON_CONTROLLER);
  const seen = [];
  Kit.listen("STATE", (data) => seen.push(["kit", data]));
  await Kit.connectDriver({ handlers: { STATE: (data) => seen.push(["page", data]), BOOM: () => { throw new Error("x"); } } });
  socket.handlers.connect();
  await settle();
  socket.handlers["42/datatoui"](push("STATE", { level: 72.5, on: false, name: "007" }));
  socket.handlers["42/datatoui"](push("BOOM", {}));
  socket.handlers["42/datatoui"](push("UNHANDLED", {}));
  assert.deepEqual(plain(seen), [["kit", { level: 72.5, on: false, name: "007" }], ["page", { level: 72.5, on: false, name: "007" }]]);
});

test("the properties card asks the driver for its properties on each connect, and shows them and a refusal", async () => {
  const { Kit, posts, socket, timers } = load(ON_CONTROLLER);
  const card = element("div");
  Kit.initPropertiesCard(card);
  await Kit.connectDriver({});
  socket.handlers.connect();
  await settle();
  assert.deepEqual(commands(posts), ["_GET_PROPERTIES"]);
  socket.handlers["42/datatoui"](push("PROPERTIES", { properties: [{ name: "Mode", value: "Off", choices: ["Off", "Auto"] }] }));
  assert.equal(Kit._properties.list[0].name, "Mode");
  assert.match(card.innerHTML, /data-prop="Mode"><option selected>Off<\/option><option>Auto<\/option>/);
  socket.handlers["42/datatoui"](push("PROPERTY_ERROR", { property: "Mode", error: "Mode has no choice Slow." }));
  assert.equal(Kit._properties.errors.Mode, "Mode has no choice Slow.");
  // A property changed in Composer redraws its field.
  socket.handlers["42/properties"]({ data: { devicecommand: { command: "UPDATE_PROPERTY", name: "Mode", value: "Auto" } } });
  socket.handlers["42/properties"]({ data: { devicecommand: { command: "UPDATE_PROPERTY", name: "Log Level", value: "4 - Debug" } } });
  assert.match(card.innerHTML, /<option selected>Auto<\/option>/);
  // A change can change the list too, so the card asks again, once for the burst.
  const asks = timers.filter((t) => t.ms === 300);
  assert.equal(asks.length, 1);
  asks[0].fn();
  await settle();
  assert.deepEqual(commands(posts), ["_GET_PROPERTIES", "_GET_PROPERTIES"]);
});

test("call resolves with its answer push, with null when none comes in time, and with the refusal an ERROR push carries", async () => {
  const { Kit, posts, socket, timers } = load(ON_CONTROLLER);
  await Kit.connectDriver({});
  socket.handlers.connect();
  await settle();
  const answered = Kit.call("_SAVE", { a: 1 }, "SAVED", 5000);
  socket.handlers["42/datatoui"](push("SAVED", { id: 3 }));
  assert.deepEqual(plain(await answered), { id: 3 });
  assert.equal(commands(posts).at(-1), "_SAVE");
  const late = Kit.call("_SAVE", {}, "SAVED", 5000);
  timers.filter((t) => t.ms === 5000).forEach((t) => t.fn());
  assert.equal(await late, null);
  const refused = Kit.call("_SAVE", {}, "SAVED", 5000);
  socket.handlers["42/datatoui"](push("ERROR", { message: "Full" }));
  assert.deepEqual(plain(await refused), { error: "Full" });
});

test("the live-link banner shows when no push comes within 10 s of a connect and on a drop, and the next push clears it", async () => {
  const { Kit, socket, timers, body } = load(ON_CONTROLLER);
  await Kit.connectDriver({});
  socket.handlers.connect();
  await settle();
  const link = () => body.children.find((el) => el.className.includes("kit-link"));
  assert.equal(link(), undefined, "nothing until something is wrong");
  timers.filter((t) => t.ms === 10000).forEach((t) => t.fn());
  assert.equal(link().hidden, false);
  assert.match(link().textContent, /No live connection to the driver/);
  socket.handlers["42/datatoui"](push("STATE", {}));
  assert.equal(link().hidden, true);
  socket.handlers.disconnect();
  assert.equal(link().hidden, false);
  // Reconnected, the banner waits for fresh state.
  socket.handlers.connect();
  await settle();
  assert.equal(link().hidden, false);
  socket.handlers["42/datatoui"](push("STATE", {}));
  assert.equal(link().hidden, true);
});

test("a poll sends its command on its timer", async () => {
  const { Kit, posts, timers } = load(ON_CONTROLLER);
  await Kit.connectDriver({ poll: { command: "_GET_STATE", every: 30000 } });
  const poll = timers.find((t) => t.every);
  assert.equal(poll.ms, 30000);
  poll.fn();
  await settle();
  assert.deepEqual(commands(posts), ["_GET_STATE"]);
});

test("another item on the same link subscribes once, hears its own pushes, and answers its calls", async () => {
  const { Kit, posts, socket } = load(ON_CONTROLLER);
  await Kit.connectDriver({});
  socket.handlers.connect();
  await settle();
  const other = Kit.follow(77);
  const heard = [];
  other.on((command, data) => heard.push([command, data]));
  assert.equal(await other.open(), true);
  assert.equal(await other.open(), true);
  assert.equal(posts.filter((p) => p.url.includes("items/77/datatoui")).length, 1, "one subscription, kept");
  const answered = other.call("_GET_STATE", {}, "STATE", 5000);
  assert.ok(posts.some((p) => p.url.endsWith("items/77/commands")));
  socket.handlers["77/datatoui"](push("STATE", { looks: 2 }));
  assert.deepEqual(plain(await answered), { looks: 2 });
  assert.deepEqual(plain(heard), [["STATE", { looks: 2 }]]);
  assert.equal(Kit.follow("77"), other, "one link per item");
});

test("with the hash option the open tab is kept in the address, its detail too, and a tab set can be built per state", () => {
  const nav = element("div");
  const { Kit, ctx } = load(ON_CONTROLLER, { hash: "#measurements/energy" });
  ctx.document.querySelector = (sel) => (sel === ".nav" ? nav : sel.includes('data-panel="measurements"') ? {} : null);
  const switched = [];
  Kit.initTabs((name, detail) => switched.push([name, detail]), { hash: true });
  assert.deepEqual(switched, [["measurements", "energy"]], "the address opens its tab and detail");
  Kit.switchTab("status");
  assert.equal(ctx.location.hash, "#status", "a switch is written to the address; the hashchange shows it");
  Kit.setDetail("solar");
  assert.equal(ctx.location.hash, "#status/solar");
  Kit.setTabs([["device", "Device"], ["exposes", "Exposes"]], "device");
  assert.match(nav.innerHTML, /<div class="nav-tab active" data-panel="device">Device<\/div><div class="nav-tab" data-panel="exposes">Exposes<\/div>/);
});

test("opened with a controller and no token, the page logs in through the dev proxy's saved login", () => {
  const { Kit, xhrs } = load("?apihost=" + encodeURIComponent("http://127.0.0.1:8765") + "&driverid=9", { token: "proxy-token" });
  assert.equal(Kit.apiToken, "proxy-token");
  assert.deepEqual(plain(xhrs), [{ method: "POST", url: "http://127.0.0.1:8765/api/v1/localjwt", sync: false, body: "{}" }]);
  const composer = load(ON_CONTROLLER, { token: "unused" });
  assert.equal(composer.Kit.apiToken, "tok");
  assert.equal(composer.xhrs.length, 0, "Composer's token is used as given");
});

test("ago reads a time as how long ago it was", () => {
  const { Kit } = load("");
  const now = Math.floor(Date.now() / 1000);
  assert.equal(Kit.ago(now), "just now");
  assert.equal(Kit.ago(now - 90), "1 min ago");
  assert.equal(Kit.ago(now - 7200), "2 h ago");
  assert.equal(Kit.ago(null), "");
});

test("esc makes text safe for HTML", () => {
  const { Kit } = load("");
  assert.equal(Kit.esc(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  assert.equal(Kit.esc(null), "");
  assert.equal(Kit.str(0), "0");
  assert.equal(Kit.str(undefined), "");
});
