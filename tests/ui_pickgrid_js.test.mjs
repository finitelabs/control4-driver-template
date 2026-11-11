// lib/ui/pickgrid.js on a stub page: the grid's cells for pictures, words, dark and photo pictures and tags, a pick
// and its mark across a refill, an empty grid's words, and the drop zone taking a file chosen, dropped or pasted.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import * as dom from "./ui_dom.mjs";

// The stub DOM, extended: attribute selectors, fragments, a textContent that clears, and a file input's click.
const { Element } = dom;
const matchOne = (el, part) => {
  const tag = (part.match(/^[a-z]+/i) || [""])[0].toUpperCase();
  const attrs = [...part.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)].map((m) => [m[1], m[2]]);
  return (
    (!tag || el.tagName === tag) &&
    attrs.every(([name, value]) => {
      const have = name.startsWith("data-") ? el.dataset[name.slice(5)] : el.attrs[name];
      return value === undefined ? have !== undefined : String(have) === value;
    })
  );
};
const descendants = (el) => el.children.flatMap((c) => [c, ...descendants(c)]);
Object.assign(Element.prototype, {
  querySelectorAll(selector) {
    return descendants(this).filter((el) => matchOne(el, selector));
  },
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  },
  closest(selector) {
    for (let el = this; el && el.attrs; el = el.parentNode) if (matchOne(el, selector)) return el;
    return null;
  },
  click() {
    this.clicks = (this.clicks || 0) + 1;
  },
});
const insert = Element.prototype.insertBefore;
Element.prototype.insertBefore = function (node, ref) {
  if (node.tagName !== "#FRAGMENT") return insert.call(this, node, ref);
  node.children.slice().forEach((c) => insert.call(this, c, ref));
  return node;
};

function load() {
  const page = dom.load("", { scripts: ["pickgrid.js"] });
  page.document.createDocumentFragment = () => new Element("#fragment", {}, page.document);
  return page;
}
/** An element in the page whose textContent, set, clears its children, as the real one does. */
function box(page, tag = "div") {
  const el = page.body.appendChild(new Element(tag, {}, page.document));
  let text = "";
  Object.defineProperty(el, "textContent", {
    get: () => text,
    set: (v) => ((el.children = []), (text = v)),
  });
  return el;
}
const cells = (grid) => grid.children.filter((c) => c.tagName === "BUTTON");

test("the grid draws pictures, words, dark and photo pictures and tags, and reports a pick", () => {
  const page = load();
  const el = box(page);
  const picks = [];
  const grid = page.Kit.pickGrid(el, { onPick: (id) => picks.push(id), empty: "No pictures yet." });
  assert.ok(el.classList.contains("kit-pickgrid"));
  grid.fill([
    { id: "mdi:battery", title: "Battery", src: "data:x" },
    { id: "pack:fan", src: "data:y", dark: true },
    { id: "mine:p1", src: "data:z", photo: true, tag: "SVG" },
    { id: "mine:p2", text: "Gone" },
  ]);
  const [a, b, c, d] = cells(el);
  assert.equal(a.className, "kit-pick");
  assert.equal(a.title, "Battery");
  assert.equal(a.children[0].src, "data:x");
  assert.equal(b.className, "kit-pick dark");
  assert.equal(b.title, "pack:fan", "a cell with no title is named by its id");
  assert.equal(c.className, "kit-pick photo");
  assert.equal(c.children[1].className, "kit-pick-tag");
  assert.equal(c.children[1].textContent, "SVG");
  assert.equal(d.children[0].className, "kit-pick-text");
  assert.equal(d.children[0].textContent, "Gone");
  el.fire("click", { target: b.children[0] });
  assert.deepEqual(picks, ["pack:fan"]);
  assert.equal(grid.cell("mine:p1"), c);
});

test("a mark follows the picked id across a refill, and an empty grid says so", () => {
  const page = load();
  const el = box(page);
  const grid = page.Kit.pickGrid(el, { empty: "No pictures yet." });
  grid.fill([{ id: "a", src: "x" }, { id: "b", src: "y" }]);
  grid.mark("b");
  assert.deepEqual(cells(el).map((c) => c.classList.contains("on")), [false, true]);
  grid.fill([{ id: "b", src: "y" }, { id: "c", src: "z" }]);
  assert.deepEqual(cells(el).map((c) => c.classList.contains("on")), [true, false], "a refill keeps the mark");
  grid.set({ id: "c", src: "late" });
  assert.equal(cells(el)[1].children[0].src, "late", "set redraws a cell in place");
  grid.set({ id: "b", text: "B" });
  assert.equal(cells(el)[0].classList.contains("on"), true, "keeping its mark");
  grid.set({ id: "gone", src: "x" });
  assert.equal(cells(el).length, 2, "and leaves a grid without that id alone");
  grid.fill([]);
  assert.equal(el.children.length, 1);
  assert.equal(el.children[0].className, "empty");
  assert.equal(el.children[0].textContent, "No pictures yet.");
  grid.fill([], "Searching…");
  assert.equal(el.children[0].textContent, "Searching…", "a fill may say something else");
});

test("the drop zone takes a file chosen, dropped or pasted, and shows a drag over it", () => {
  const page = load();
  const zone = box(page);
  const choose = zone.appendChild(new Element("button", {}, page.document));
  const files = [];
  let pasting = false;
  page.Kit.dropZone(zone, { onFile: (f) => files.push(f.name), choose, accept: "image/*", pasteWhen: () => pasting });
  assert.ok(zone.classList.contains("kit-drop"));
  const input = zone.children.find((c) => c.type === "file");
  assert.equal(input.hidden, true);
  assert.equal(input.accept, "image/*");
  choose.fire("click");
  assert.equal(input.clicks, 1, "the button opens the chooser");
  input.files = [{ name: "chosen.png" }];
  input.fire("change");
  zone.fire("dragover");
  assert.ok(zone.classList.contains("over"));
  const drop = zone.fire("drop", { dataTransfer: { files: [{ name: "dropped.png" }] } });
  assert.equal(drop.prevented, true);
  assert.equal(zone.classList.contains("over"), false);
  const paste = (target) =>
    page.document.fire({
      type: "paste",
      target,
      clipboardData: { items: [{ kind: "file", type: "image/png", getAsFile: () => ({ name: "pasted.png" }) }] },
      preventDefault() {},
    });
  paste(page.body);
  pasting = true;
  paste(new Element("textarea"));
  paste(page.body);
  assert.deepEqual(files, ["chosen.png", "dropped.png", "pasted.png"], "a paste counts only when asked and outside a text box");
});
