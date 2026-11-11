// lib/ui/color.js on a stub page: the swatch that takes a color input's place and follows its value, the popover's
// offered and recent colors, the hex box and sliders setting the input as a pick would, Enter and an outside click
// keeping the color, Esc putting it back or handing it to the page, and the dropper picking a picture's pixel over its
// backdrop.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";
import * as dom from "./ui_dom.mjs";

const COLOR_JS = readFileSync(join(dom.UI_DIR, "color.js"), "utf8");

// The stub DOM, extended for markup: the popover is built from HTML and read back with selectors.
const { Element } = dom;
const simple = (part) => {
  const attrs = [...part.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)].map((m) => [m[1], m[2]]);
  part = part.replace(/\[[^\]]*\]/g, "");
  const tag = (part.match(/^[a-z]+/i) || [""])[0].toUpperCase();
  const classes = [...part.matchAll(/\.([\w-]+)/g)].map((m) => m[1]);
  const id = (part.match(/#([\w-]+)/) || [])[1];
  return (el) =>
    (!tag || el.tagName === tag) &&
    classes.every((c) => el.classList.contains(c)) &&
    (!id || el.attrs.id === id) &&
    attrs.every(([name, value]) => {
      const have = name.startsWith("data-") ? el.dataset[name.slice(5)] ?? el.attrs[name] : el.attrs[name];
      return value === undefined ? have !== undefined : String(have) === value;
    });
};
const selectorFn = (selector) => {
  const parts = selector.trim().split(/\s+/).map(simple);
  return (el) => {
    if (!parts[parts.length - 1](el)) return false;
    let i = parts.length - 2;
    for (let p = el.parentNode; p && i >= 0; p = p.parentNode) if (p.attrs && parts[i](p)) i--;
    return i < 0;
  };
};
const descendants = (el) => el.children.flatMap((c) => [c, ...descendants(c)]);
Object.assign(Element.prototype, {
  querySelectorAll(selector) {
    return descendants(this).filter(selectorFn(selector));
  },
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  },
  closest(selector) {
    const ok = selectorFn(selector);
    for (let el = this; el && el.attrs; el = el.parentNode) if (ok(el)) return el;
    return null;
  },
  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  },
  select() {},
  getBoundingClientRect() {
    return this.rect || { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
  },
});
Object.defineProperty(Element.prototype, "nextElementSibling", {
  get() {
    const kids = this.parentNode ? this.parentNode.children : [];
    return kids[kids.indexOf(this) + 1] || null;
  },
});
Object.defineProperty(Element.prototype, "offsetWidth", { get: () => 264 });

const VOID = new Set(["input", "img", "br"]);
/** Builds `html` as children of `parent`: tags, attributes and text, enough for the popover's markup. */
function parse(html, parent, document) {
  parent.children = [];
  const stack = [parent];
  for (const m of html.matchAll(/<\/(\w+)>|<(\w+)([^>]*)>|([^<]+)/g)) {
    const top = stack[stack.length - 1];
    if (m[1]) stack.pop();
    else if (m[2]) {
      const attrs = {};
      for (const a of m[3].matchAll(/([\w-]+)(?:="([^"]*)")?/g)) attrs[a[1]] = a[2] === undefined ? "" : a[2];
      const el = new Element(m[2], attrs, document);
      el.className = attrs.class || "";
      el.hidden = "hidden" in attrs;
      Object.keys(attrs)
        .filter((k) => k.startsWith("data-"))
        .forEach((k) => (el.dataset[k.slice(5)] = attrs[k]));
      top.appendChild(el);
      if (!VOID.has(m[2]) && !m[3].endsWith("/")) stack.push(el);
    } else top.textContent += m[4];
  }
}

/** page.js and color.js on a stub page with a color input `id` holding `value`, its label before it. */
function load({ value = "#109eff", inputClass = "" } = {}) {
  const page = dom.load("");
  const { ctx, document } = page;
  const listeners = {};
  document.addEventListener = (t, fn) => (listeners[t] = listeners[t] || []).push(fn);
  document.removeEventListener = (t, fn) => (listeners[t] = (listeners[t] || []).filter((f) => f !== fn));
  document.fire = (event) => (listeners[event.type] || []).slice().forEach((fn) => fn(event));
  document.listeners = listeners;
  document.documentElement = { clientWidth: 1000, clientHeight: 800 };
  const make = document.createElement;
  document.createElement = (tag) => {
    const el = make(tag);
    let html = "";
    Object.defineProperty(el, "innerHTML", {
      get: () => html,
      set: (v) => parse((html = v), el, document),
    });
    return el;
  };
  const native = { value: "" };
  class HTMLInputElement {}
  Object.defineProperty(HTMLInputElement.prototype, "value", {
    get() {
      return this.nativeValue ?? native.value;
    },
    set(v) {
      this.nativeValue = String(v);
    },
  });
  const store = {};
  Object.assign(ctx, {
    HTMLInputElement,
    MutationObserver: class {
      observe() {}
    },
    localStorage: { getItem: (k) => store[k] ?? null, setItem: (k, v) => (store[k] = v) },
    scrollX: 0,
    scrollY: 0,
  });
  vm.runInContext(COLOR_JS, ctx);
  const field = page.body.appendChild(new Element("div", {}, document));
  const label = field.appendChild(new Element("label", { for: "c" }, document));
  label.textContent = "Tile color";
  label.htmlFor = "c";
  const input = field.appendChild(new Element("input", { id: "c", type: "color" }, document));
  input.id = "c";
  input.className = inputClass;
  Object.defineProperty(input, "value", {
    configurable: true,
    get() {
      return input.nativeValue ?? "";
    },
    set(v) {
      input.nativeValue = String(v);
    },
  });
  input.nativeValue = value;
  document.querySelector = (selector) => (selector === 'label[for="c"]' ? label : null);
  const inputs = [];
  input.addEventListener("input", () => inputs.push(input.nativeValue));
  return { ...page, Kit: ctx.Kit, ctx, field, label, input, inputs, store, listeners };
}
const popOf = (body) => body.children.find((c) => c.classList.contains("kit-color")) || null;
const key = (page, k) => page.document.fire({ type: "keydown", key: k, preventDefault() {} });

test("Kit.color reads and writes hex, rgb and hsl", () => {
  const { Kit } = load();
  assert.equal(Kit.color.normal(" 1af "), "#11AAFF");
  assert.equal(Kit.color.normal("#12"), null);
  assert.deepEqual([...Kit.color.rgb("#109EFF")], [16, 158, 255]);
  assert.equal(Kit.color.hex([16, 158, 255.4]), "#109EFF");
  assert.equal(Kit.color.fromHsl(Kit.color.hsl("#109EFF")), "#109EFF");
  assert.equal(Kit.color.fromHsl({ h: 0, s: 1, l: 0.5 }), "#FF0000");
});

test("the swatch takes the input's place, carries its label and follows its value", () => {
  const { Kit, field, label, input } = load();
  Kit.colorPicker(input);
  const swatch = field.children[1];
  assert.equal(swatch.className, "kit-swatch");
  assert.equal(swatch.id, "c-swatch");
  assert.equal(label.htmlFor, "c-swatch");
  assert.equal(swatch.getAttribute("aria-label"), "Tile color");
  assert.equal(input.hidden, true);
  assert.equal(swatch.firstChild.style.background, "#109eff");
  input.value = "#00ff00";
  assert.equal(swatch.firstChild.style.background, "#00ff00", "a value set from code repaints it");
  input.className = "no-color";
  input.value = "#00ff00";
  assert.ok(swatch.classList.contains("no-color"), "a no-color input crosses it out");
});

test("the popover offers the page's colors and the recent ones, and a chip, the hex box or a slider picks", () => {
  const page = load();
  const { Kit, input, inputs, body } = page;
  Kit.colorPicker(input, { offer: () => [{ title: "This look", colors: ["#FFFFFF", "#109EFF"] }], recentKey: "r" });
  page.store.r = JSON.stringify(["#00FF00", "nope"]);
  input.kitSwatch.fire("click");
  const pop = popOf(body);
  assert.ok(pop.classList.contains("kit-pop"));
  assert.deepEqual(pop.querySelectorAll(".kit-color-label").map((l) => l.textContent), ["This look", "Recent"]);
  assert.deepEqual(pop.querySelectorAll(".kit-color-chip").map((c) => c.dataset.hex), ["#FFFFFF", "#109EFF", "#00FF00"]);
  assert.ok(pop.querySelector('.kit-color-chip[data-hex="#109EFF"]').classList.contains("on"), "the input's color is marked");
  pop.fire("click", { target: pop.querySelector('.kit-color-chip[data-hex="#FFFFFF"]') });
  assert.deepEqual(inputs, ["#ffffff"], "a chip sets the input and fires its input event");
  const box = pop.querySelector(".kit-color-hex input");
  box.value = "#12";
  box.fire("input");
  assert.ok(box.classList.contains("input-error"));
  box.value = "f00";
  box.fire("input");
  assert.deepEqual(inputs, ["#ffffff", "#ff0000"]);
  const [h, s, l] = pop.querySelectorAll(".kit-color-slider input");
  assert.deepEqual([h.value, s.value, l.value], [0, 100, 50]);
  h.value = "120";
  h.fire("input");
  assert.deepEqual(inputs.at(-1), "#00ff00", "a slider picks too");
  assert.equal(h.nextElementSibling.textContent, "120");
});

test("Enter or a click outside keeps the color and remembers it; Esc puts it back or hands it to the page", () => {
  const page = load();
  const { Kit, input, body, store } = page;
  Kit.colorPicker(input, { recentKey: "r" });
  input.kitSwatch.fire("click");
  let box = popOf(body).querySelector(".kit-color-hex input");
  box.value = "#123456";
  box.fire("input");
  box.fire("keydown", { key: "Enter" });
  assert.equal(popOf(body), null, "Enter closes it");
  assert.deepEqual(JSON.parse(store.r), ["#123456"], "and the color is a recent one");
  input.kitSwatch.fire("click");
  box = popOf(body).querySelector(".kit-color-hex input");
  box.value = "#abcdef";
  box.fire("input");
  key(page, "Escape");
  assert.equal(popOf(body), null);
  assert.equal(input.value, "#123456", "Esc puts the color it opened on back");
  const cancelled = [];
  Kit.colorPicker.close();
  input.kitColor.onCancel = (start) => cancelled.push(start);
  input.kitSwatch.fire("click");
  key(page, "Escape");
  assert.deepEqual(cancelled, ["#123456"], "or hands Esc to the page");
  input.kitSwatch.fire("click");
  page.document.fire({ type: "mousedown", target: body, button: 0 });
  assert.equal(popOf(body), null, "a click outside closes it");
  input.kitSwatch.fire("click");
  input.kitSwatch.fire("click");
  assert.equal(popOf(body), null, "its swatch toggles it");
});

test("the dropper shows only with a picture, outlines its area, and picks a pixel over the backdrop", () => {
  const page = load();
  const { Kit, input, body, document } = page;
  Kit.colorPicker(input);
  input.kitSwatch.fire("click");
  assert.equal(popOf(body).querySelector(".kit-color-dropper").hidden, true, "no dropper without a picture");
  Kit.colorPicker.close();
  const area = body.appendChild(new Element("div", {}, document));
  const img = area.appendChild(new Element("img", {}, document));
  Object.assign(img, { naturalWidth: 2, naturalHeight: 2, rect: { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 } });
  // A half see-through red pixel over a white backdrop reads as pink.
  img.kitPixels = { getContext: () => ({ getImageData: () => ({ data: [255, 0, 0, 128] }) }) };
  input.kitColor.dropper = { when: () => true, image: () => img, area: () => area, backdrop: () => [255, 255, 255] };
  input.kitSwatch.fire("click");
  const drop = popOf(body).querySelector(".kit-color-dropper");
  assert.equal(drop.hidden, false);
  drop.fire("click");
  assert.ok(area.classList.contains("kit-color-target"), "the area is outlined while it is armed");
  assert.equal(drop.getAttribute("aria-pressed"), "true");
  const event = { type: "mousedown", target: img, button: 0, clientX: 80, clientY: 20, preventDefault() {} };
  page.document.fire(event);
  assert.equal(input.value, "#ff7f7f");
  assert.ok(popOf(body), "a pick keeps the picker open");
  assert.equal(area.classList.contains("kit-color-target"), false, "and disarms the dropper");
  drop.fire("click");
  key(page, "Escape");
  assert.ok(popOf(body), "Esc while armed only disarms it");
  assert.equal(drop.getAttribute("aria-pressed"), "false");
});
