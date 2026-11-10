// lib/ui/variables.js on a stub page: the store of what the driver lists and its demo answers, the tree drawn from
// it, a search's marks, the devices it opens and the lists it asks for, the ticks on variables a field uses, and a
// pick's token at the caret.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const UI_DIR = process.env.UI_DIR || "template/src/lib/ui";
const PAGE_JS = readFileSync(UI_DIR + "/page.js", "utf8");
const VARIABLES_JS = readFileSync(UI_DIR + "/variables.js", "utf8");

const ON_CONTROLLER = "?apihost=ctrl.example.invalid&driverid=42&apitoken=tok";

class Event {
  constructor(type, init) {
    this.type = type;
    this.bubbles = !!(init && init.bubbles);
  }
}

/** A page of stub elements: what the browser builds itself, and the fields it reads and writes. */
function stubDocument() {
  const docListeners = {};
  const inPage = [];
  const fire = (listeners, ev) => (listeners[ev.type] || []).slice().forEach((fn) => fn(ev));

  function element(tag, attrs = {}) {
    const classes = new Set();
    const listeners = {};
    return {
      nodeType: 1,
      tagName: tag.toUpperCase(),
      attrs: { ...attrs },
      children: [],
      parentNode: null,
      innerHTML: "",
      textContent: "",
      value: "",
      classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c) },
      setAttribute(name, value) {
        this.attrs[name] = String(value);
      },
      getAttribute(name) {
        return name in this.attrs ? this.attrs[name] : null;
      },
      appendChild(child) {
        child.parentNode = this;
        this.children.push(child);
        return child;
      },
      addEventListener(type, fn) {
        (listeners[type] = listeners[type] || []).push(fn);
      },
      /** An event the user causes here, as the browser delivers it: this element's listeners, then the page's. */
      fire(type, ev = {}) {
        ev.type = type;
        ev.target = ev.target || this;
        fire(listeners, ev);
        fire(docListeners, ev);
      },
      dispatchEvent(ev) {
        ev.target = this;
        fire(listeners, ev);
        if (ev.bubbles) fire(docListeners, ev);
        return true;
      },
      focus() {
        document.activeElement = this;
        fire(docListeners, { type: "focusin", target: this });
      },
    };
  }

  const matches = (el, selector) =>
    selector.startsWith("#")
      ? el.attrs.id === selector.slice(1)
      : selector.startsWith("[")
        ? selector.slice(1, -1) in el.attrs
        : el.tagName === selector.toUpperCase();

  const document = {
    activeElement: null,
    createElement: (tag) => element(tag),
    addEventListener(type, fn) {
      (docListeners[type] = docListeners[type] || []).push(fn);
    },
    querySelector: (selector) => inPage.find((el) => matches(el, selector)) || null,
    querySelectorAll: (selector) => inPage.filter((el) => matches(el, selector)),
    contains: (el) => inPage.includes(el),
    /** A text field in the page, its caret at the end unless given. */
    field(attrs = {}, value = "", caret) {
      const el = element(attrs.tag || "textarea", attrs);
      delete el.attrs.tag;
      el.value = value;
      el.selectionStart = el.selectionEnd = caret === undefined ? value.length : caret;
      el.setSelectionRange = function (start, end) {
        this.selectionStart = start;
        this.selectionEnd = end;
      };
      inPage.push(el);
      return el;
    },
  };
  return document;
}

/** page.js then variables.js on a stub page at `search`. */
function load(search = "") {
  const posts = [];
  const timers = [];
  const document = stubDocument();
  const ctx = {
    location: { search, hash: "" },
    history: { replaceState() {} },
    document,
    console,
    btoa,
    atob,
    Event,
    addEventListener() {},
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
    setInterval() {},
    clearTimeout() {},
    fetch: (url, opts) => {
      posts.push({ url, opts });
      return Promise.resolve({ json: () => Promise.resolve({}), text: () => Promise.resolve("") });
    },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(PAGE_JS, ctx);
  vm.runInContext(VARIABLES_JS, ctx);
  // Runs what waits on no delay, a demo answer, and leaves a call's time limit alone.
  const flush = () => {
    for (let i; (i = timers.findIndex((t) => !t.ms)) >= 0; ) timers.splice(i, 1)[0].fn();
  };
  return { Kit: ctx.Kit, document, posts, flush };
}

const decode = (data) => JSON.parse(decodeURIComponent(escape(atob(data.replace(/\n/g, "")))));
const plain = (o) => JSON.parse(JSON.stringify(o));
/** A promise's value once pending work has run, or "still waiting", so a test fails rather than hangs. */
const soon = (promise) =>
  Promise.race([promise, new Promise((resolve) => setImmediate(() => resolve("still waiting")))]);
/** Each command posted, with its params. */
const commands = (posts) =>
  posts
    .filter((p) => p.url.endsWith("/commands"))
    .map((p) => JSON.parse(p.opts.body))
    .map((body) => [body.command, decode(body.tParams.DATA)]);
const asked = (posts) => commands(posts).filter((c) => c[0] === "_GET_DEVICE_VARIABLES").map((c) => c[1].deviceId);

const DEVICES = [
  { id: 700, name: "Light", roomName: "Hall", section: "Devices", hasVariables: true, memberIds: [700, 701] },
  { id: 710, name: "Amps & Volts", roomName: "Office", section: "Devices", hasVariables: true, memberIds: [710] },
  { id: 100001, name: "Variables", roomName: "Agents", section: "Agents", hasVariables: true, memberIds: [100001] },
];
const VARIABLES = {
  700: [
    { id: 1, deviceId: 700, section: "Device", order: 1, name: "OWN", type: "STRING", value: "on" },
    { id: 2, deviceId: 701, section: "light_v2", order: 2, name: "LEVEL", type: "NUMBER", value: "<40>" },
  ],
  710: [{ id: 5, deviceId: 710, section: "Device", order: 1, name: "BRIGHTNESS", type: "NUMBER", value: "3" }],
  // No deviceId, as an older driver sends: the entry owns it.
  100001: [{ id: 2301, name: "GLOBAL_LIMIT", type: "NUMBER", value: "90" }],
};

/** A browser in a new element, with its parts. */
function browser(page, options) {
  const el = page.document.createElement("div");
  const vb = page.Kit.variableBrowser(el, options);
  const [search, tree, foot] = el.children;
  return {
    el,
    vb,
    search,
    tree,
    foot,
    type(text) {
      search.value = text;
      search.fire("input");
    },
  };
}

/** A demo page with the list loaded and a browser on it. */
function demoBrowser(options, devices = DEVICES, variables = VARIABLES) {
  const page = load("");
  page.Kit.devices.demo(devices, variables);
  const b = browser(page, options);
  b.vb.refresh();
  page.flush();
  return { ...page, ...b };
}

/** The attributes of each <button> in the tree. */
function buttons(html) {
  return [...html.matchAll(/<button ([^>]*)>/g)].map((m) => {
    const attrs = {};
    m[1].replace(/([\w-]+)="([^"]*)"/g, (_, name, value) => (attrs[name] = value));
    return attrs;
  });
}

/** Clicks the span inside the tree's button whose attributes include `want`. */
function click(b, want) {
  const attrs = buttons(b.tree.innerHTML).find((a) => Object.keys(want).every((k) => a[k] === String(want[k])));
  assert.ok(attrs, "a row with " + JSON.stringify(want));
  const button = { getAttribute: (name) => (name in attrs ? attrs[name] : null), parentNode: b.tree };
  b.tree.fire("click", { target: { getAttribute: () => null, parentNode: button } });
}

const rooms = (html) => [...html.matchAll(/class="kit-vb-room">(.*?)<\/div>/g)].map((m) => m[1]);
/** Each device row's id, with a + when it is open. */
const devicesShown = (html) =>
  [...html.matchAll(/data-device="(\d*)" aria-expanded="(true|false)"/g)].map((m) => m[1] + (m[2] === "true" ? "+" : ""));
/** Each variable row, as owner:variable. */
const variablesShown = (html) =>
  buttons(html)
    .filter((a) => "data-var" in a)
    .map((a) => a["data-owner"] + ":" + a["data-var"]);
/** The variable rows ticked as used, as owner:variable. */
const ticked = (html) =>
  buttons(html)
    .filter((a) => / kit-vb-used/.test(a.class))
    .map((a) => a["data-owner"] + ":" + a["data-var"]);

test("the store keeps the list and each entry's variables, asking for each once", async () => {
  const { Kit, posts } = load(ON_CONTROLLER);
  const changes = [];
  Kit.devices.onChange((id) => changes.push(id));
  const loaded = Kit.devices.load();
  assert.deepEqual(plain(commands(posts)), [["_GET_DEVICES", {}]]);
  assert.equal(Kit.devices.list().length, 0);
  Kit.deliver("DEVICES_DATA", { devices: DEVICES });
  assert.equal((await soon(loaded)).length, 3);
  assert.deepEqual(plain(changes), [null]);

  assert.equal(Kit.devices.variables(700), null);
  assert.equal(Kit.devices.variables("700"), null);
  const later = Kit.devices.whenVariables(700);
  assert.deepEqual(asked(posts), [700]);
  Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: "700", variables: VARIABLES[700] });
  assert.equal((await soon(later)).length, 2);
  assert.equal(Kit.devices.variables(700).length, 2);
  assert.deepEqual(plain(changes), [null, "700"]);
  assert.equal((await Kit.devices.whenVariables(700)).length, 2, "a list held answers at once");
  assert.deepEqual(asked(posts), [700]);

  assert.equal(Kit.devices.device(701).id, 700, "a member finds its entry");
  assert.equal(Kit.devices.device(999), null);
  assert.equal(Kit.devices.variable(701, 2).name, "LEVEL");
  assert.equal(Kit.devices.variable(701, "LEVEL").id, 2, "a token may name the variable");
  assert.equal(Kit.devices.variable(700, 2), null, "the variable is the proxy's, not the driver's");
  assert.equal(Kit.devices.variable(100001, 2301), null, "while the agent's variables load");
  assert.deepEqual(asked(posts), [700, 100001]);
  Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: "100001", variables: VARIABLES[100001] });
  assert.equal(Kit.devices.variable(100001, 2301).name, "GLOBAL_LIMIT", "a row without deviceId is the entry's");

  Kit.deliver("DEVICES_DATA", { devices: DEVICES });
  assert.equal(Kit.devices.variables(700), null, "a new list reads values again");
  assert.deepEqual(asked(posts), [700, 100001, 700]);

  const refused = Kit.devices.whenVariables(710);
  Kit.deliver("ERROR", { message: "unlicensed" });
  assert.equal(await soon(refused), null, "a refusal answers what waits");
  Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: "", variables: [] });
  assert.equal(Kit.devices.variables(""), null, "an answer for no device is dropped");
});

test("demo answers the two commands with the page's data", async () => {
  const { Kit, posts, flush } = load("");
  Kit.devices.demo(DEVICES, VARIABLES);
  const loaded = Kit.devices.load();
  flush();
  assert.deepEqual(plain((await soon(loaded)).map((d) => d.id)), [700, 710, 100001]);
  const later = Kit.devices.whenVariables(710);
  const none = Kit.devices.whenVariables(999);
  flush();
  assert.equal((await soon(later))[0].name, "BRIGHTNESS");
  assert.deepEqual(plain(await soon(none)), []);
  assert.equal(posts.length, 0);
});

test("the tree shows each room, its devices, and an opened device's variables by member", () => {
  const page = load("");
  const b = browser(page);
  assert.ok(b.el.classList.contains("kit-vb"));
  assert.equal(b.search.type, "search");
  assert.match(b.tree.innerHTML, /Loading devices…/);
  assert.equal(b.foot.textContent, "");

  page.Kit.devices.demo(DEVICES, VARIABLES);
  b.vb.refresh();
  page.flush();
  assert.deepEqual(rooms(b.tree.innerHTML), ["Hall", "Office", "Agents"]);
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700", "710", "100001"]);
  assert.match(b.tree.innerHTML, /Amps &amp; Volts/);
  assert.equal(b.foot.textContent, "3 of 3 devices");

  click(b, { "data-device": 700 });
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700+", "710", "100001"]);
  assert.match(b.tree.innerHTML, /Loading variables…/);
  page.flush();
  const html = b.tree.innerHTML;
  assert.deepEqual(variablesShown(html), ["700:1", "701:2"], "each names the member owning it");
  assert.deepEqual([...html.matchAll(/kit-vb-section">([^<]*)</g)].map((m) => m[1]), ["Device", "light_v2"]);
  assert.match(html, /<span class="kit-vb-value">&lt;40&gt;<\/span>/);
  assert.match(html, /title="Light &gt; LEVEL"/);

  click(b, { "data-device": 700 });
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700", "710", "100001"]);
  click(b, { "data-device": 100001 });
  page.flush();
  assert.deepEqual(variablesShown(b.tree.innerHTML), ["100001:2301"]);
});

test("names are escaped and ids reach the markup as digits only", () => {
  const evil = [{ id: '7"0 onclick="x', name: "<img src=x onerror=alert(1)>", roomName: "<b>R&D</b>" }];
  const evilVariables = { 70: [{ id: '9"><script>', deviceId: '7"0', name: "<i>V</i>", value: "<v>" }] };
  const b = demoBrowser(undefined, evil, evilVariables);
  assert.doesNotMatch(b.tree.innerHTML, /<img|<b>|onclick/);
  assert.deepEqual(rooms(b.tree.innerHTML), ["&lt;b&gt;R&amp;D&lt;/b&gt;"]);
  click(b, { "data-device": 70 });
  b.flush();
  assert.deepEqual(variablesShown(b.tree.innerHTML), ["70:9"]);
  assert.doesNotMatch(b.tree.innerHTML, /<script>|<i>|<v>/);
});

test("a search marks what it matches, opens what it finds, and counts it", () => {
  const b = demoBrowser();
  b.type("  LIG ");
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700+"], "trimmed, any case, and opened");
  assert.match(b.tree.innerHTML, /<mark class="kit-vb-hl">Lig<\/mark>ht/);
  assert.equal(b.foot.textContent, "1 of 3 devices");
  b.flush();
  assert.deepEqual(variablesShown(b.tree.innerHTML), ["700:1", "701:2"], "a device found by name shows them all");

  b.type("amp");
  assert.match(b.tree.innerHTML, /<mark class="kit-vb-hl">Amp<\/mark>s &amp; Volts/, "an entity is never cut");
  b.type("&");
  assert.match(b.tree.innerHTML, /Amps <mark class="kit-vb-hl">&amp;<\/mark> Volts/);

  b.type("level");
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700+"], "a variable's name finds a device whose list is here");
  assert.deepEqual(variablesShown(b.tree.innerHTML), ["701:2"], "showing only what matches");
  assert.match(b.tree.innerHTML, /<mark class="kit-vb-hl">LEVEL<\/mark>/);

  b.type("hall");
  assert.deepEqual(rooms(b.tree.innerHTML), ['<mark class="kit-vb-hl">Hall</mark>']);

  b.type("nothing like it");
  assert.match(b.tree.innerHTML, /No matches/);
  assert.equal(b.foot.textContent, "0 of 3 devices");
});

test("after the list reloads, a search asks again for the lists it read before, and only those", () => {
  const page = load(ON_CONTROLLER);
  const vb = browser(page);
  page.Kit.deliver("DEVICES_DATA", { devices: DEVICES });
  vb.type("bright");
  assert.deepEqual(asked(page.posts), [], "a list never read is not asked for by a search");
  page.Kit.devices.variables(710);
  page.Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: "710", variables: VARIABLES[710] });
  assert.deepEqual(devicesShown(vb.tree.innerHTML), ["710+"]);
  page.Kit.deliver("DEVICES_DATA", { devices: DEVICES });
  assert.deepEqual(asked(page.posts), [710, 710], "the reload's render asks for it again");
  page.Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: "710", variables: VARIABLES[710] });
  assert.deepEqual(variablesShown(vb.tree.innerHTML), ["710:5"]);
});

test("a search opens up to 25 devices and waits on at most 15 lists at once", () => {
  const page = load(ON_CONTROLLER);
  const many = [];
  for (let i = 1; i <= 40; i++) {
    many.push({ id: i, name: "Dev " + i, roomName: i <= 20 ? "Hall" : "Kitchen", section: "Devices" });
  }
  const b = browser(page);
  page.Kit.deliver("DEVICES_DATA", { devices: many });
  b.type("dev");
  assert.equal(devicesShown(b.tree.innerHTML).filter((d) => d.endsWith("+")).length, 0, "40 found stay closed");
  assert.equal(b.foot.textContent, "40 of 40 devices");
  assert.deepEqual(asked(page.posts), []);
  click(b, { "data-device": 33 });
  assert.ok(devicesShown(b.tree.innerHTML).includes("33+"), "a click still opens one");
  assert.deepEqual(asked(page.posts), [33]);

  b.type("hall");
  assert.equal(devicesShown(b.tree.innerHTML).filter((d) => d.endsWith("+")).length, 20, "20 found open");
  assert.equal(asked(page.posts).length, 1 + 15, "15 lists asked for");
  page.Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: "1", variables: [{ id: 1, name: "X", value: "1" }] });
  assert.equal(asked(page.posts).length, 1 + 16, "and one more as one arrives");
});

test("a click during a search turns a device from how the search shows it, for that search only", () => {
  const b = demoBrowser();
  click(b, { "data-device": 710 });
  b.type("light");
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700+"]);
  click(b, { "data-device": 700 });
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700"]);
  b.type("ligh");
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700+"], "a new search shows it as it finds it");
  b.type("");
  assert.deepEqual(devicesShown(b.tree.innerHTML), ["700", "710+", "100001"], "clearing it shows what was open");
});

test("a variable the target's tokens use is ticked, by id or by name, and typing redraws the ticks", () => {
  const page = load("");
  const field = page.document.field({ "data-tok": "1" }, "PARAM{701,2} + PARAM{ 700 , OWN }");
  page.Kit.devices.demo(DEVICES, VARIABLES);
  const b = browser(page);
  b.vb.refresh();
  page.flush();
  click(b, { "data-device": 700 });
  page.flush();
  assert.deepEqual(ticked(b.tree.innerHTML), ["700:1", "701:2"]);
  field.value = "PARAM{700,1}";
  field.fire("input");
  assert.deepEqual(ticked(b.tree.innerHTML), ["700:1"]);

  const other = page.document.field({ id: "other", "data-tok": "1" }, "PARAM{701,LEVEL}");
  const all = browser(page, { usedIn: "[data-tok]" });
  click(all, { "data-device": 700 });
  assert.deepEqual(ticked(all.tree.innerHTML), ["700:1", "701:2"], "usedIn reads every field it names");
  const one = browser(page, { usedIn: () => other });
  click(one, { "data-device": 700 });
  assert.deepEqual(ticked(one.tree.innerHTML), ["701:2"]);
});

test("a pick inserts its token at the caret of the last focused token field, and fires its input event", () => {
  const page = load("");
  const first = page.document.field({ "data-tok": "1" }, "first");
  const body = page.document.field({ "data-tok": "1" }, "a + b", 4);
  body.selectionEnd = 5;
  const inputs = [];
  body.addEventListener("input", (e) => inputs.push(e.target));
  page.Kit.devices.demo(DEVICES, VARIABLES);
  const b = browser(page);
  b.vb.refresh();
  page.flush();
  click(b, { "data-device": 700 });
  page.flush();

  body.focus();
  page.document.activeElement = null;
  click(b, { "data-owner": 701, "data-var": 2 });
  assert.equal(body.value, "a + PARAM{701,2}", "the selection is replaced");
  assert.equal(body.selectionStart, "a + PARAM{701,2}".length);
  assert.equal(body.selectionEnd, body.selectionStart);
  assert.equal(page.document.activeElement, body, "and the field has the focus back");
  assert.deepEqual(inputs, [body]);
  assert.equal(first.value, "first");
  assert.deepEqual(ticked(b.tree.innerHTML), ["701:2"], "and the pick is ticked");

  const fresh = load("");
  const only = fresh.document.field({ "data-tok": "1" }, "x");
  delete only.selectionStart;
  delete only.selectionEnd;
  fresh.Kit.devices.demo(DEVICES, VARIABLES);
  const nb = browser(fresh);
  nb.vb.refresh();
  fresh.flush();
  click(nb, { "data-device": 100001 });
  fresh.flush();
  click(nb, { "data-var": 2301 });
  assert.equal(only.value, "xPARAM{100001,2301}", "with no focus and no caret it goes at the end of the first one");
});

test("a page names the target, the token and what a pick does", () => {
  const page = load("");
  const box = page.document.field({ id: "box", tag: "input" }, "");
  page.Kit.devices.demo(DEVICES, VARIABLES);
  const picks = [];
  const bySelector = browser(page, { target: "#box", token: (v) => "[" + v.device.name + ">" + v.name + "]" });
  bySelector.vb.refresh();
  page.flush();
  click(bySelector, { "data-device": 700 });
  page.flush();
  click(bySelector, { "data-var": 1 });
  assert.equal(box.value, "[Light>OWN]");

  const given = [];
  const byFunction = browser(page, { target: (last) => (given.push(last), last || box) });
  click(byFunction, { "data-device": 700 });
  click(byFunction, { "data-var": 2 });
  assert.equal(box.value, "[Light>OWN]PARAM{701,2}");
  assert.equal(given[given.length - 1], null, "a function is given the last focused token field, here none");
  const tok = page.document.field({ "data-tok": "1" }, "");
  tok.focus();
  click(byFunction, { "data-var": 1 });
  assert.equal(tok.value, "PARAM{700,1}", "and its answer is the target");

  const own = browser(page, { onPick: (v) => picks.push(v), target: box });
  click(own, { "data-device": 700 });
  click(own, { "data-var": 2 });
  assert.equal(box.value, "[Light>OWN]PARAM{701,2}", "onPick replaces the insert");
  assert.deepEqual(plain(picks.map((v) => [v.deviceId, v.id, v.name, v.device.id])), [[701, 2, "LEVEL", 700]]);
});
