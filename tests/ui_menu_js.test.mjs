// lib/ui/menu.js on a stub page: the split button's markup, closed and open, the arrow that opens it, a pick, and the
// click elsewhere and Escape that close it, each drawing the page again.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import * as dom from "./ui_dom.mjs";

const load = () => dom.load("", { scripts: ["menu.js"] });

/** An element on the stub page with these attributes. */
function el(document, attrs) {
  const node = document.createElement("button");
  Object.entries(attrs).forEach(([k, v]) => node.setAttribute(k, v));
  return node;
}
const click = (document, target) => document.fire({ type: "click", target });
const MAIN = '<button class="btn btn-primary">Update firmware</button>';

test("with nothing more to offer it is the button alone", () => {
  const { Kit } = load();
  assert.equal(Kit.splitButton("fw", MAIN, []), MAIN);
  assert.equal(Kit.splitButton("fw", "", [["Check", () => {}]]), "");
});

test("closed, it is the button and an arrow in its look; open, the menu of the other choices too", () => {
  const { Kit, document } = load();
  let drawn = 0;
  const items = [["Check for updates", () => {}], ["Update from a <URL>", () => {}]];
  const draw = () => Kit.splitButton("fw", MAIN, items, { label: "More ways to update", onChange: () => drawn++ });
  const closed = draw();
  assert.match(closed, /^<span class="kit-splitbtn"><button class="btn btn-primary">Update firmware<\/button>/);
  assert.match(closed, /class="btn btn-primary kit-splitbtn-arrow" data-kit-menu="fw" aria-label="More ways to update" aria-haspopup="menu" aria-expanded="false"/);
  assert.doesNotMatch(closed, /kit-menu"/);
  assert.match(Kit.splitButton("x", '<button class="btn btn-secondary">Check</button>', items), /btn btn-secondary kit-splitbtn-arrow/);
  click(document, el(document, { "data-kit-menu": "fw" }));
  assert.equal(Kit.menu.isOpen("fw"), true);
  assert.equal(drawn, 1, "opening draws the page again");
  const open = draw();
  assert.match(open, /aria-expanded="true"/);
  assert.match(open, /<span class="kit-menu" role="menu"><button type="button" role="menuitem" data-kit-menu-item="fw" data-index="0">Check for updates<\/button>/);
  assert.match(open, /data-index="1">Update from a &lt;URL&gt;</, "labels are escaped");
});

test("a pick closes the menu, runs its choice and draws the page again", () => {
  const { Kit, document } = load();
  const picked = [];
  let drawn = 0;
  Kit.splitButton("fw", MAIN, [["A", () => picked.push("a")], ["B", () => picked.push("b")]], { onChange: () => drawn++ });
  click(document, el(document, { "data-kit-menu": "fw" }));
  click(document, el(document, { "data-kit-menu-item": "fw", "data-index": "1" }));
  assert.deepEqual(picked, ["b"]);
  assert.equal(Kit.menu.isOpen("fw"), false);
  assert.equal(drawn, 2);
});

test("the arrow again, a click elsewhere or Escape closes it", () => {
  const { Kit, document } = load();
  let drawn = 0;
  Kit.splitButton("fw", MAIN, [["A", () => {}]], { onChange: () => drawn++ });
  const arrow = el(document, { "data-kit-menu": "fw" });
  click(document, arrow);
  click(document, arrow);
  assert.equal(Kit.menu.isOpen("fw"), false, "the arrow closes what it opened");
  click(document, arrow);
  click(document, el(document, { class: "elsewhere" }));
  assert.equal(Kit.menu.isOpen("fw"), false);
  click(document, arrow);
  document.fire({ type: "keydown", key: "Escape" });
  assert.equal(Kit.menu.isOpen("fw"), false);
  assert.equal(drawn, 6);
  click(document, el(document, { class: "elsewhere" }));
  document.fire({ type: "keydown", key: "Escape" });
  assert.equal(drawn, 6, "with nothing open, nothing is drawn again");
});
