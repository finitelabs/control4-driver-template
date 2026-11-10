// The stub page the lib/ui scripts' tests run on. load() runs page.js and the named kit scripts there; flush() runs
// what waits on no delay (a demo answer, not a call's time limit), elapse() every timer as time passing would.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";

export const UI_DIR = process.env.UI_DIR || "template/src/lib/ui";
export const ON_CONTROLLER = "?apihost=ctrl.example.invalid&driverid=42&apitoken=tok";
export const decode = (data) => JSON.parse(decodeURIComponent(escape(atob(data.replace(/\n/g, "")))));
export const plain = (o) => JSON.parse(JSON.stringify(o));

class Event {
  constructor(type, init) {
    Object.assign(this, { type, bubbles: !!(init && init.bubbles) });
  }
}

const matches = (el, selector) =>
  selector.startsWith("#")
    ? el.attrs.id === selector.slice(1)
    : selector.startsWith("[")
      ? selector.slice(1, -1) in el.attrs
      : selector.startsWith(".")
        ? el.classList.contains(selector.slice(1))
        : el.tagName === selector.toUpperCase();

export class Element {
  constructor(tag, attrs = {}, ownerDocument = null) {
    Object.assign(this, { nodeType: 1, tagName: tag.toUpperCase(), attrs: { ...attrs }, ownerDocument, children: [] });
    Object.assign(this, { parentNode: null, style: {}, dataset: {}, listeners: {}, hidden: false, className: "" });
    Object.assign(this, { textContent: "", innerHTML: "", title: "", value: "" });
  }
  get classList() {
    const names = () => this.className.split(/\s+/).filter(Boolean);
    const contains = (c) => names().includes(c);
    const toggle = (c, on = !contains(c)) => {
      if (on !== contains(c)) this.className = (on ? [...names(), c] : names().filter((n) => n !== c)).join(" ");
      return !!on;
    };
    return { add: (c) => toggle(c, true), remove: (c) => toggle(c, false), contains, toggle };
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
  contains(node) {
    for (; node; node = node.parentNode) if (node === this) return true;
    return false;
  }
  closest(selector) {
    for (let el = this; el && el.attrs; el = el.parentNode) if (matches(el, selector)) return el;
    return null;
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
    const event = Object.assign({ type, target: this, prevented: false }, extra);
    event.preventDefault = () => (event.prevented = true);
    (this.listeners[type] || []).slice().forEach((fn) => fn(event));
    if (this.ownerDocument) this.ownerDocument.fire(event);
    return event;
  }
  dispatchEvent(event) {
    event.target = this;
    (this.listeners[event.type] || []).slice().forEach((fn) => fn(event));
    if (event.bubbles && this.ownerDocument) this.ownerDocument.fire(event);
    return true;
  }
  focus() {
    if (!this.ownerDocument) return;
    this.ownerDocument.activeElement = this;
    this.ownerDocument.fire({ type: "focusin", target: this });
  }
  setSelectionRange(start, end) {
    this.selectionStart = start;
    this.selectionEnd = end;
  }
  text() {
    return [this.textContent, ...this.children.filter((c) => !c.hidden).map((c) => c.text())].join(" ").replace(/\s+/g, " ").trim();
  }
}

function stubDocument() {
  const listeners = {};
  const inPage = [];
  const document = {
    activeElement: null,
    createElement: (tag) => new Element(tag, {}, document),
    addEventListener(type, fn) {
      (listeners[type] = listeners[type] || []).push(fn);
    },
    fire: (event) => (listeners[event.type] || []).slice().forEach((fn) => fn(event)),
    getElementById: (id) => inPage.find((el) => el.attrs.id === id) || null,
    querySelector: (selector) => inPage.find((el) => matches(el, selector)) || null,
    querySelectorAll: (selector) => inPage.filter((el) => matches(el, selector)),
    contains: (el) => inPage.includes(el),
    field(attrs = {}, value = "", caret) {
      const el = new Element(attrs.tag || "textarea", attrs, document);
      delete el.attrs.tag;
      el.value = value;
      el.selectionStart = el.selectionEnd = caret === undefined ? value.length : caret;
      inPage.push(el);
      return el;
    },
  };
  document.body = new Element("body", {}, document);
  return document;
}

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

export function load(search = "", { scripts = [], pageScript, answer, token, hash = "" } = {}) {
  const posts = [];
  const timers = [];
  const xhrs = [];
  let next = 1;
  const document = stubDocument();
  const socket = stubSocket();
  const later = (fn, ms, every) => (timers.push({ fn, ms, every, id: next }), next++);
  const ctx = {
    location: { search, hash },
    history: { replaceState: (s, t, url) => (ctx.location.hash = url) },
    document,
    console,
    btoa,
    atob,
    Event,
    io: { connect: () => socket },
    addEventListener() {},
    setTimeout: (fn, ms) => later(fn, ms, false),
    setInterval: (fn, ms) => later(fn, ms, true),
    clearTimeout: (id) => {
      const at = timers.findIndex((t) => t.id === id);
      if (at >= 0) timers.splice(at, 1);
    },
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
  ["page.js", ...scripts].forEach((name) => vm.runInContext(readFileSync(join(UI_DIR, name), "utf8"), ctx));
  if (pageScript) vm.runInContext(pageScript, ctx);
  const flush = () => {
    for (let i; (i = timers.findIndex((t) => !t.ms)) >= 0; ) timers.splice(i, 1)[0].fn();
  };
  const elapse = () => {
    for (let round = 0; round < 20 && timers.length; round++) timers.splice(0).forEach((t) => t.fn());
  };
  const sent = () =>
    posts.map((p) => {
      const b = JSON.parse(p.opts.body);
      return { command: b.command, params: decode(b.tParams.DATA) };
    });
  return { Kit: ctx.Kit, ctx, document, body: document.body, posts, timers, xhrs, socket, flush, elapse, sent };
}
