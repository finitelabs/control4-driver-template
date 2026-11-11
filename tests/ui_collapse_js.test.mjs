// lib/ui/collapse.js on a stub page: a set's open state by key over its default, the markup a page draws its groups
// and their toggle-all button with, and the clicks that turn a group or every group and draw the page again.
//
// Run from the template repo, against a render's copy:
//   make render-ui-js NAME=ui

import { test } from "node:test";
import assert from "node:assert/strict";
import * as dom from "./ui_dom.mjs";

const load = () => dom.load("", { scripts: ["collapse.js"] });

/** An element on the stub page with these attributes, inside `parent` when given. */
function el(document, attrs, parent) {
  const node = document.createElement("div");
  Object.entries(attrs).forEach(([k, v]) => node.setAttribute(k, v));
  if (parent) parent.appendChild(node);
  return node;
}
const click = (document, target) => document.fire({ type: "click", target });

test("a group's state is its own once turned, else the set's default", () => {
  const { Kit } = load();
  const set = Kit.collapse("ledger");
  assert.equal(set.isOpen("1:0x0006"), true, "open unless told otherwise");
  set.toggle("1:0x0006");
  assert.equal(set.isOpen("1:0x0006"), false);
  assert.equal(set.isOpen("1:0x0702"), true, "the others keep the default");
  assert.equal(set.anyOpen(["1:0x0006", "1:0x0702"]), true);
  assert.equal(set.anyOpen(["1:0x0006"]), false);
  set.setAll(false);
  assert.equal(set.isOpen("1:0x0702"), false, "a new default reaches every group");
  set.toggle("1:0x0702");
  set.setAll(false);
  assert.equal(set.isOpen("1:0x0702"), false, "and drops what was turned by hand");
  assert.equal(Kit.collapse("closed", { open: false }).isOpen("x"), false, "a set can start closed");
});

test("a group draws its head, then its body, open or not", () => {
  const { Kit } = load();
  const set = Kit.collapse("set:<a>");
  assert.equal(set.head('1:"x"'), 'data-kit-collapse="set:&lt;a&gt;" data-key="1:&quot;x&quot;"', "names and keys are escaped");
  assert.equal(
    set.group("k", "<div>H</div>", "<p>B</p>", "lg-kids"),
    '<div class="kit-collapse open"><div>H</div><div class="kit-collapse-body lg-kids"><p>B</p></div></div>'
  );
  set.toggle("k");
  assert.match(set.group("k", "", ""), /^<div class="kit-collapse"><div class="kit-collapse-body">/);
  assert.equal(Kit.collapse.caret(), '<span class="kit-caret">▸</span>');
  assert.equal(Kit.collapse.caret(true), '<span class="kit-caret none"></span>', "a row with nothing to open keeps the caret's place");
});

test("the toggle-all button offers what a click would do to what is on screen", () => {
  const { Kit } = load();
  const set = Kit.collapse("ledger");
  assert.equal(set.toggleAll([]), "", "no groups, no button");
  assert.match(set.toggleAll(["a", "b"]), /data-kit-collapse-all="ledger" data-open="false">Collapse all</);
  set.toggle("a");
  assert.match(set.toggleAll(["a", "b"]), />Collapse all</, "one still open");
  set.toggle("b");
  assert.match(set.toggleAll(["a", "b"]), /data-open="true">Expand all</, "none open");
});

test("a click on a head turns its group and draws the page again; Expand all turns them all", () => {
  const { Kit, document } = load();
  let drawn = 0;
  const set = Kit.collapse("ledger", { onChange: () => drawn++ });
  const head = el(document, { "data-kit-collapse": "ledger", "data-key": "1:0x0006" });
  const caret = el(document, { class: "kit-caret" }, head);
  click(document, caret);
  assert.equal(set.isOpen("1:0x0006"), false, "a click inside the head counts");
  assert.equal(drawn, 1);
  click(document, head);
  assert.equal(set.isOpen("1:0x0006"), true);
  const all = el(document, { "data-kit-collapse-all": "ledger", "data-open": "false" });
  click(document, all);
  assert.equal(set.anyOpen(["1:0x0006", "2:0x0402"]), false);
  assert.equal(drawn, 3);
  click(document, el(document, { class: "elsewhere" }));
  click(document, el(document, { "data-kit-collapse": "unknown", "data-key": "x" }));
  assert.equal(drawn, 3, "other clicks, and a set no page made, change nothing");
});

test("sets are apart: a click turns only its own", () => {
  const { Kit, document } = load();
  const ledger = Kit.collapse("ledger");
  const settings = Kit.collapse("settings");
  click(document, el(document, { "data-kit-collapse": "settings", "data-key": "k" }));
  assert.equal(settings.isOpen("k"), false);
  assert.equal(ledger.isOpen("k"), true);
});
