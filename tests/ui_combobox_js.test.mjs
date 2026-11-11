// lib/ui/combobox.js, the searchable dropdown, on page.js in a stub DOM: its markup, opening and closing by click,
// key and outside click, the search, a pick, a list that loads, and a redraw that keeps it open.
//
// Run from the template repo, against a render's copy:
//   UI_DIR=<render>/src/lib/ui node --test tests/ui_combobox_js.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { Element, load as loadKit } from "./ui_dom.mjs";

const load = () => {
  const page = loadKit("", { scripts: ["combobox.js"] });
  page.document.documentElement = { clientWidth: 1000, clientHeight: 800 };
  return page;
};

// The stub DOM parses no HTML, so a drawn control is built here as the markup describes it.
function find(root, cls) {
  for (const child of root.children) {
    if (child.classList.contains(cls)) return child;
    const deeper = find(child, cls);
    if (deeper) return deeper;
  }
  return null;
}

function mount(page, key, { search = true } = {}) {
  const doc = page.document;
  const root = doc.field({ tag: "div", "data-kit-combo": key });
  root.className = "kit-combo";
  const part = (tag, cls, parent) => {
    const el = parent.appendChild(new Element(tag, {}, doc));
    el.className = cls;
    return el;
  };
  const trigger = part("button", "kit-combo-trigger", root);
  const pop = part("div", "kit-combo-pop", root);
  const input = search ? part("input", "kit-combo-search", pop) : null;
  const list = part("div", "kit-combo-list", pop);
  [root, pop, list].forEach((el) => (el.querySelector = (sel) => find(el, sel.slice(1))));
  [pop, trigger].forEach((el) => (el.getBoundingClientRect = () => ({ top: 100, bottom: 120, right: 300, height: 150 })));
  return { root, trigger, pop, input, list };
}

const DEVICES = [
  { value: "100", label: "Kitchen > Fridge", section: "Devices" },
  { value: "101", label: "Kitchen > Oven", section: "Devices" },
  { value: "900", label: "Scheduler", section: "Agents" },
];

const labels = (html) => [...html.matchAll(/class="kit-combo-item[^"]*"[^>]*>([^<]*)</g)].map((m) => m[1]);
const sections = (html) => [...html.matchAll(/class="kit-combo-section">([^<]*)</g)].map((m) => m[1]);
const click = (page, target) => page.document.fire({ type: "click", target });
const key = (page, target, name) => {
  const event = { type: "keydown", key: name, target, prevented: false, preventDefault: () => (event.prevented = true) };
  page.document.fire(event);
  return event;
};

test("the markup is a trigger, a search box and an empty list, the label escaped and the placeholder shown with none", () => {
  const { Kit } = load();
  const html = Kit.combobox("dev", { label: "", placeholder: "Device...", items: () => DEVICES, style: "width:180px", className: "wide" });
  assert.match(html, /^<div class="kit-combo wide" data-kit-combo="dev" style="width:180px">/);
  assert.match(html, /<button type="button" class="kit-combo-trigger placeholder"[^>]*aria-expanded="false"[^>]*>Device\.\.\.<\/button>/);
  assert.match(html, /<input type="text" class="kit-combo-search"/);
  assert.match(html, /<div class="kit-combo-list" role="listbox"><\/div>/);
  const picked = Kit.combobox("dev", { label: "<b>Oven</b>", items: () => DEVICES });
  assert.match(picked, /class="kit-combo-trigger" [^>]*title="&lt;b&gt;Oven&lt;\/b&gt;">&lt;b&gt;Oven&lt;\/b&gt;</);
  assert.doesNotMatch(Kit.combobox("v", { items: () => [], search: false }), /kit-combo-search/);
});

test("a click on the trigger opens it with every choice under its section and the search focused; another closes it", () => {
  const page = load();
  page.Kit.combobox("dev", { placeholder: "Device...", items: () => DEVICES, value: "101", onPick: () => {} });
  const c = mount(page, "dev");
  click(page, c.trigger);
  assert.equal(c.root.classList.contains("open"), true);
  assert.equal(c.trigger.getAttribute("aria-expanded"), "true");
  assert.deepEqual(labels(c.list.innerHTML), ["Kitchen &gt; Fridge", "Kitchen &gt; Oven", "Scheduler"]);
  assert.deepEqual(sections(c.list.innerHTML), ["Devices", "Agents"]);
  assert.match(c.list.innerHTML, /class="kit-combo-item selected"[^>]*>Kitchen &gt; Oven/, "the picked one is marked");
  assert.equal(page.document.activeElement, c.input);
  click(page, c.trigger);
  assert.equal(c.root.classList.contains("open"), false);
  assert.equal(c.trigger.getAttribute("aria-expanded"), "false");
});

test("the search narrows the list, a section only with its matches, and says so when nothing matches", () => {
  const page = load();
  page.Kit.combobox("dev", { items: () => DEVICES, onPick: () => {} });
  const c = mount(page, "dev");
  click(page, c.trigger);
  c.input.value = "oven";
  c.input.fire("input");
  assert.deepEqual(labels(c.list.innerHTML), ["Kitchen &gt; Oven"]);
  assert.deepEqual(sections(c.list.innerHTML), ["Devices"]);
  c.input.value = "garage";
  c.input.fire("input");
  assert.match(c.list.innerHTML, /<div class="kit-combo-none">No matches<\/div>/);
});

test("Down and Enter pick, a click on a choice picks, and both close it", () => {
  const page = load();
  const picks = [];
  page.Kit.combobox("dev", { items: () => DEVICES, onPick: (value, item) => picks.push([value, item.label]) });
  const c = mount(page, "dev");
  click(page, c.trigger);
  key(page, c.input, "ArrowDown");
  key(page, c.input, "ArrowDown");
  assert.match(c.list.innerHTML, /class="kit-combo-item active"[^>]*>Kitchen &gt; Oven/);
  assert.equal(key(page, c.input, "Enter").prevented, true);
  assert.deepEqual(picks, [["101", "Kitchen > Oven"]]);
  assert.equal(c.root.classList.contains("open"), false);
  click(page, c.trigger);
  key(page, c.input, "ArrowUp");
  assert.match(c.list.innerHTML, /class="kit-combo-item active"[^>]*>Scheduler/, "Up from the top wraps to the last");
  const item = c.list.appendChild(new Element("div", { "data-index": "0" }, page.document));
  item.className = "kit-combo-item";
  click(page, item);
  assert.deepEqual(picks.at(-1), ["100", "Kitchen > Fridge"]);
  click(page, c.trigger);
  c.input.value = "sched";
  c.input.fire("input");
  key(page, c.input, "Enter");
  assert.deepEqual(picks.at(-1), ["900", "Scheduler"], "Enter takes the only match");
});

test("Escape and a click outside close it, Escape back on the trigger", () => {
  const page = load();
  page.Kit.combobox("dev", { items: () => DEVICES, onPick: () => {} });
  const c = mount(page, "dev");
  click(page, c.trigger);
  key(page, c.input, "Escape");
  assert.equal(c.root.classList.contains("open"), false);
  assert.equal(page.document.activeElement, c.trigger);
  click(page, c.trigger);
  click(page, page.body);
  assert.equal(c.root.classList.contains("open"), false);
});

test("a list still loading says so, and its refresh fills it", () => {
  const page = load();
  let rows = null;
  page.Kit.combobox("var", { items: () => rows, onPick: () => {} });
  const c = mount(page, "var");
  click(page, c.trigger);
  assert.match(c.list.innerHTML, /<div class="kit-combo-none">Loading…<\/div>/);
  rows = [{ value: "100:1", label: "LEVEL" }];
  page.Kit.combobox.refresh("var");
  assert.deepEqual(labels(c.list.innerHTML), ["LEVEL"]);
  page.Kit.combobox.refresh("other");
  assert.deepEqual(labels(c.list.innerHTML), ["LEVEL"], "a closed one's refresh changes nothing");
});

test("drawn again while open, it stays open with its search and gets the focus back", () => {
  const page = load();
  const opts = { items: () => DEVICES, onPick: () => {} };
  page.Kit.combobox("dev", opts);
  let c = mount(page, "dev");
  click(page, c.trigger);
  c.input.value = "kit";
  c.input.fire("input");
  const html = page.Kit.combobox("dev", opts);
  assert.match(html, /class="kit-combo open"/);
  assert.match(html, /aria-expanded="true"/);
  assert.match(html, /class="kit-combo-search" placeholder="Search…" value="kit"/);
  assert.deepEqual(labels(html), ["Kitchen &gt; Fridge", "Kitchen &gt; Oven"]);
  page.document.activeElement = null;
  page.flush();
  assert.equal(page.document.activeElement, c.input);
  assert.doesNotMatch(page.Kit.combobox("dev2", opts), / open"/, "only the open one");
});

test("set shows another pick on the drawn control", () => {
  const page = load();
  page.Kit.combobox("dev", { placeholder: "Device...", label: "Kitchen > Oven", items: () => DEVICES, onPick: () => {} });
  const c = mount(page, "dev");
  page.Kit.combobox.set("dev", { label: "", value: "" });
  assert.equal(c.trigger.textContent, "Device...");
  assert.equal(c.trigger.classList.contains("placeholder"), true);
  page.Kit.combobox.set("dev", { label: "Kitchen > Fridge", value: "100" });
  assert.equal(c.trigger.textContent, "Kitchen > Fridge");
  assert.equal(c.trigger.title, "Kitchen > Fridge");
  assert.equal(c.trigger.classList.contains("placeholder"), false);
});

test("a list that would leave the pane opens left and up", () => {
  const page = load();
  page.Kit.combobox("dev", { items: () => DEVICES, onPick: () => {} });
  const c = mount(page, "dev");
  page.document.documentElement = { clientWidth: 250, clientHeight: 200 };
  click(page, c.trigger);
  assert.equal(c.pop.classList.contains("flip-right"), true);
  assert.equal(c.pop.classList.contains("flip-up"), true);
});
