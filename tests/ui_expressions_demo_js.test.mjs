// lib/ui/expressions-demo.js, the expression editor's demo previews, on page.js and expressions.js in a stub DOM: the
// kit's own evaluation of a preview, worded as the driver's, and its path to the page with the page's hold and fields.
//
// Run from the template repo, against a render's copy:
//   UI_DIR=<render>/src/lib/ui node --test tests/ui_expressions_demo_js.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";

const UI_DIR = process.env.UI_DIR || "template/src/lib/ui";
const PAGE_JS = readFileSync(join(UI_DIR, "page.js"), "utf8");
const EXPRESSIONS_JS = readFileSync(join(UI_DIR, "expressions.js"), "utf8");
const DEMO_JS = readFileSync(join(UI_DIR, "expressions-demo.js"), "utf8");

// Just enough DOM for the editor: elements with children, classes, attributes and listeners.
class Element {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
    this.hidden = false;
    this.className = "";
    this.textContent = "";
    this.innerHTML = "";
    this.title = "";
    this.value = "";
  }
  get classList() {
    const names = () => this.className.split(/\s+/).filter(Boolean);
    const set = (list) => (this.className = list.join(" "));
    return {
      add: (c) => set([...new Set([...names(), c])]),
      remove: (c) => set(names().filter((n) => n !== c)),
      contains: (c) => names().includes(c),
      toggle: (c, force) => {
        const on = force === undefined ? !names().includes(c) : !!force;
        set(on ? [...new Set([...names(), c])] : names().filter((n) => n !== c));
        return on;
      },
    };
  }
  get firstChild() {
    return this.children[0] || null;
  }
  get scrollHeight() {
    return 18 + 20 * this.value.split("\n").length;
  }
  get clientWidth() {
    return 300;
  }
  appendChild(node) {
    return this.insertBefore(node, null);
  }
  insertBefore(node, ref) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    const at = ref ? this.children.indexOf(ref) : -1;
    if (at < 0) this.children.push(node);
    else this.children.splice(at, 0, node);
    return node;
  }
  removeChild(node) {
    this.children = this.children.filter((n) => n !== node);
    node.parentNode = null;
    return node;
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value);
  }
  getAttribute(name) {
    return name in this.attrs ? this.attrs[name] : null;
  }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  fire(type, extra) {
    const event = Object.assign({ target: this, prevented: false }, extra);
    event.preventDefault = () => (event.prevented = true);
    (this.listeners[type] || []).forEach((fn) => fn(event));
    return event;
  }
  focus() {}
  setSelectionRange(start, end) {
    this.selectionStart = start;
    this.selectionEnd = end;
  }
  // Text the tests read: this element's own text and its children's, in order.
  text() {
    return [this.textContent, ...this.children.filter((c) => !c.hidden).map((c) => c.text())].join(" ").replace(/\s+/g, " ").trim();
  }
}

function load(search) {
  const posts = [];
  let timers = [];
  let next = 1;
  const body = new Element("body");
  const ctx = {
    location: { search, hash: "" },
    document: {
      body,
      getElementById: () => null,
      querySelector: () => null,
      querySelectorAll: () => [],
      createElement: (tag) => new Element(tag),
    },
    console,
    btoa,
    atob,
    setTimeout: (fn) => {
      timers.push({ fn, id: next });
      return next++;
    },
    clearTimeout: (id) => {
      timers = timers.filter((t) => t.id !== id);
    },
    fetch: (url, opts) => {
      posts.push({ url, opts });
      return Promise.resolve({ json: () => Promise.resolve({}) });
    },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(PAGE_JS, ctx);
  vm.runInContext(EXPRESSIONS_JS, ctx);
  vm.runInContext(DEMO_JS, ctx);
  // Runs every timer due, and those they set, as time passing would.
  const flush = () => {
    for (let round = 0; round < 20 && timers.length; round++) {
      const due = timers;
      timers = [];
      due.forEach((t) => t.fn());
    }
  };
  const sent = () =>
    posts.map((p) => {
      const b = JSON.parse(p.opts.body);
      return { command: b.command, params: JSON.parse(decodeURIComponent(escape(atob(b.tParams.DATA.replace(/\n/g, ""))))) };
    });
  return { Kit: ctx.Kit, body, flush, sent, timers: () => timers };
}

// A textarea in a field, as a page places it.
function field(body) {
  const holder = body.appendChild(new Element("div"));
  return holder.appendChild(new Element("textarea"));
}

function type(box, text) {
  box.value = text;
  box.selectionStart = box.selectionEnd = text.length;
  box.fire("input");
}

const DEVICES = [{ id: 9001, name: "Sample Battery", roomName: "Demo Room" }];
const VARIABLES = {
  9001: [
    { id: 1, deviceId: 9001, name: "LEVEL", value: "62" },
    { id: 2, deviceId: 9001, name: "STATE", value: "Charging" },
    { id: 3, deviceId: 9002, name: "ON", value: "true" },
  ],
};

test("in demo mode the kit evaluates a preview the way the driver does", () => {
  const { Kit } = load("");
  Kit.expressionDemo(DEVICES, VARIABLES);
  const ev = (mode, text) => JSON.parse(JSON.stringify(Kit._demoEvaluate(mode, text)));
  assert.deepEqual(ev("equation", "PARAM{9001,1} / 4"), { rendered: "[Demo Room > Sample Battery > LEVEL] / 4", substituted: "62 / 4", result: "15.5", error: "" });
  assert.equal(ev("equation", "round(PARAM{9001,LEVEL} / 3, 1) + 0.1 + 0.2").result, "21");
  assert.equal(ev("equation", "1 / 3").result, "0.33333333333333");
  assert.equal(ev("equation", "2 ^ 60").result, "1.1529215046068e+18");
  assert.equal(ev("equation", "-PARAM{9001,1} % 5").result, "3");
  assert.equal(ev("equation", "max(1, 7, 3) + #'abc' + math.floor(2.7) + string.len(PARAM{9001,2})").result, "20");
  assert.equal(ev("equation", "c2f(20) + f2c(212)").result, "168");
  assert.equal(ev("condition", 'PARAM{9001,STATE} == "Charging" and PARAM{9001,1} > 50').result, "true");
  assert.equal(ev("condition", "PARAM{9002,ON}").result, "true", "a proxy member's variable, and true as true");
  assert.equal(ev("condition", "PARAM{9001,1} < 50 or not true").result, "false");
  assert.equal(ev("condition", '"PARAM{9001,2}" == "Charging"').result, "true", "a variable in quotes is written into the text");
  assert.equal(ev("condition", 'device_name(9001) .. "!" == "Sample Battery!" and room_name(9001) == "Demo Room"').result, "true");
  assert.equal(ev("condition", "type(nil) == 'nil' and tostring(1.50) == '1.5' and tonumber('ff', 16) == 255").result, "true");
  assert.equal(ev("condition", "false and undefinedfn() or true").result, "true", "and and or stop early");
  assert.deepEqual(ev("string", "Level PARAM{9001,1}%"), { rendered: "Level [Demo Room > Sample Battery > LEVEL]%", substituted: "Level 62%", result: "Level 62%", error: "" });
  const missing = ev("condition", "PARAM{9001,9} > 1 and PARAM{77,1}");
  assert.equal(missing.error, "variable 9 not found on device 9001");
  assert.equal(missing.substituted, "ERROR_VARIABLE_NOT_FOUND > 1 and ERROR_VARIABLE_NOT_FOUND");
  assert.equal(missing.rendered, "[Demo Room > Sample Battery > 9] > 1 and [Device 77 > 1]");
  assert.equal(ev("equation", "PARAM{77,1}").error, "device 77 not found");
  const errors = {
    "PARAM{9001,1} >": "compile error: [string \"return PARAM{9001,1} >\"]:1: unexpected symbol near '<eof>'",
    "(1 + 2": "')' expected near '<eof>'",
    "1 = 1": "'<eof>' expected near '='",
    "1 != 1": "'<eof>' expected near '!'",
    '"open': "unfinished string near '<eof>'",
    "1.2.3": "malformed number near '1.2.3'",
    "avg(1)": "runtime error: [string \"return avg(1)\"]:1: attempt to call global 'avg' (a nil value)",
    "PARAM{9001,1} > 'x'": "attempt to compare string with number",
    "PARAM{9001,2} + 1": "attempt to perform arithmetic on field '?' (a string value)",
    "floor('x')": "bad argument #1 to 'floor' (number expected, got string)",
    "nope.x": "attempt to index global 'nope' (a nil value)",
    "1 .. true": "attempt to concatenate a boolean value",
    "PARAM{9001,1}": "result is not a boolean (got number)",
  };
  Object.keys(errors).forEach((text) => assert.ok(ev("condition", text).error.endsWith(errors[text]), text + ": " + ev("condition", text).error));
  assert.equal(ev("equation", "string.format('%d', 1)").error, "Outside Composer, the preview tries only part of the syntax, and not this part.");
  assert.equal(ev("equation", "{1}").error, "Outside Composer, the preview tries only part of the syntax, and not this part.");
  assert.equal(Kit.expressionError(ev("condition", "avg(1)").error), "There's no function named avg.");
});

test("in demo mode a preview takes the driver's path to the page, with the page's hold and fields", () => {
  const { Kit, body, flush } = load("");
  Kit.demoMode(null);
  Kit.expressionDemo(DEVICES, VARIABLES, {
    hold: (expression, mode, answer) => (/^compile error/.test(answer.error) ? answer.error : ""),
    extra: (answer, mode) => ({ fitted: mode === "string" ? answer.result.slice(0, 4) : undefined, id: "stolen" }),
  });
  const prev = new Element("div");
  const results = [];
  const editor = Kit.expressionEditor(field(body), { mode: "condition", preview: prev, label: "Show when", onResult: (r) => results.push(r) });
  type(editor.textarea, "PARAM{9001,1} > 50");
  flush();
  assert.equal(results.length, 1);
  assert.equal(prev.children[0].children[3].children[1].textContent, "True");
  type(editor.textarea, "PARAM{9001,1} >");
  flush();
  assert.equal(results[1].hold, true);
  assert.equal(editor.hold, "It stops before it's finished: something should follow the last part.");
  const badge = Kit.expressionEditor(field(body), { mode: "string", singleLine: true, onResult: (r) => results.push(r) });
  type(badge.textarea, "PARAM{9001,1}%");
  flush();
  assert.equal(results[2].fitted, "62%");
  assert.match(results[2].id, /^x\d+-\d+$/, "the page's fields never replace the kit's");
});
