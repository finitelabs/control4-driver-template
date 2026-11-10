// lib/ui/expressions.js, the expression editor, on page.js in a stub DOM: what it colors in each mode, the textarea it
// wraps, the previews it asks for and routes back to each editor by id, a hold, the help, the plain-language errors,
// and that the names it colors are the sandbox's.
//
// Run from the template repo, against a render's copy:
//   UI_DIR=<render>/src/lib/ui node --test tests/ui_expressions_js.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as dom from "./ui_dom.mjs";

const { Element, UI_DIR, ON_CONTROLLER: LIVE } = dom;
const EXPRESSIONS_JS = readFileSync(join(UI_DIR, "expressions.js"), "utf8");
const SANDBOX = readFileSync(join(UI_DIR, "..", "expression-sandbox.lua"), "utf8");

function load(search) {
  const page = dom.load(search, { scripts: ["expressions.js"] });
  return { ...page, flush: page.elapse };
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

/** The colored HTML an editor shows for text, each call a fresh editor in that mode. */
function highlighter() {
  const { Kit, body } = load("");
  return (text, mode, escapes) => {
    const box = field(body);
    Kit.expressionEditor(box, { mode, escapes });
    type(box, text);
    return box.parentNode.children[0].innerHTML;
  };
}

test("equation and condition modes color variables, text, names, numbers and operators", () => {
  const highlight = highlighter();
  const html = highlight('abs(PARAM{96,1002} - 3.5) >= 2 and not x1 or "a PARAM{1,2}" ~= device_name(7)', "condition");
  assert.match(html, /<span class="kit-hl-fn">abs<\/span>/);
  assert.match(html, /<span class="kit-hl-tok">PARAM\{96,1002\}<\/span>/);
  assert.match(html, /<span class="kit-hl-num">3\.5<\/span>/);
  assert.match(html, /<span class="kit-hl-op">&gt;=<\/span>/);
  assert.match(html, /<span class="kit-hl-op">~=<\/span>/);
  assert.match(html, /<span class="kit-hl-fn">and<\/span>/);
  assert.match(html, /<span class="kit-hl-fn">not<\/span>/);
  assert.match(html, /<span class="kit-hl-fn">device_name<\/span>/);
  assert.match(html, /x1/);
  assert.doesNotMatch(html, /kit-hl-num">1<\/span>/, "a digit in a name is not a number");
  assert.match(html, /<span class="kit-hl-str">&quot;a <span class="kit-hl-tok">PARAM\{1,2\}<\/span>&quot;<\/span>/, "a variable in quotes is still marked");
  const eq = highlight("math.floor(value) + map(1) + string.lower(room_name(2)) + 0x1F + 1e3", "equation");
  assert.match(eq, /kit-hl-fn">math\.floor</);
  assert.match(eq, /kit-hl-fn">string\.lower</);
  assert.match(eq, /kit-hl-fn">room_name</);
  assert.match(eq, /kit-hl-num">0x1F</);
  assert.match(eq, /kit-hl-num">1e3</);
  assert.doesNotMatch(eq, /kit-hl-fn">value</, "names the sandbox no longer has stay plain");
  assert.doesNotMatch(eq, /kit-hl-fn">map</);
});

test("string and text modes color only variables, and escapes when asked", () => {
  const highlight = highlighter();
  const s = highlight('abs(PARAM{1,2}) "x" <b>', "string");
  assert.equal(s, 'abs(<span class="kit-hl-tok">PARAM{1,2}</span>) &quot;x&quot; &lt;b&gt;');
  assert.equal(highlight("PWR ON\\r\\n", "text"), "PWR ON\\r\\n");
  const escaped = highlight("PWR PARAM{5,6}\\r\\n\\x0D\\\\ \\q", "text", true);
  assert.match(escaped, /<span class="kit-hl-tok">PARAM\{5,6\}<\/span>/);
  assert.match(escaped, /<span class="kit-hl-esc">\\r<\/span><span class="kit-hl-esc">\\n<\/span>/);
  assert.match(escaped, /<span class="kit-hl-esc">\\x0D<\/span>/);
  assert.match(escaped, /<span class="kit-hl-esc">\\\\<\/span>/);
  assert.doesNotMatch(escaped, /kit-hl-esc">\\q/, "\\q is no escape");
  assert.equal(highlight("", "equation"), "​", "an empty field still has a line");
  assert.equal(highlight("1\n", "equation"), '<span class="kit-hl-num">1</span>\n​', "and so does a last empty line");
});

test("the editor wraps its textarea under a colored <pre> and grows to fit", () => {
  const { Kit, body } = load("");
  const box = field(body);
  const holder = box.parentNode;
  const editor = Kit.expressionEditor(box, { mode: "condition" });
  const wrap = box.parentNode;
  assert.equal(wrap.className, "kit-editor");
  assert.equal(wrap.parentNode, holder);
  assert.equal(wrap.children[0].tagName, "PRE");
  assert.equal(wrap.children[0].getAttribute("aria-hidden"), "true");
  assert.equal(wrap.children[1], box);
  assert.equal(box.style.height, "64px");
  editor.setValue("1 == 1\n\n\n");
  assert.match(wrap.children[0].innerHTML, /kit-hl-op">==/);
  assert.equal(box.style.height, "98px");
  assert.equal(editor.value(), "1 == 1\n\n\n");
  const line = Kit.expressionEditor(field(body), { mode: "string", singleLine: true });
  assert.equal(line.textarea.parentNode.className, "kit-editor kit-editor-line");
  assert.equal(line.textarea.style.height, "38px");
  assert.equal(line.textarea.fire("keydown", { key: "Enter" }).prevented, true, "Enter adds no line");
  assert.equal(line.textarea.fire("keydown", { key: "a" }).prevented, false);
  line.setValue("a\n  b");
  assert.equal(line.value(), "a b", "a pasted line break reads as a space");
});

test("an edit is previewed after a pause, and preview(true) at once, with the editor's mode", () => {
  const { Kit, body, flush, sent } = load(LIVE);
  const box = field(body);
  const inputs = [];
  const editor = Kit.expressionEditor(box, { mode: "condition", preview: new Element("div"), onInput: (t) => inputs.push(t) });
  type(box, "  PARAM{1,2} > 5  ");
  assert.equal(sent().length, 0, "not while typing");
  assert.deepEqual(inputs, ["  PARAM{1,2} > 5  "]);
  flush();
  const asked = sent();
  assert.equal(asked.length, 1);
  assert.equal(asked[0].command, "_EVAL_EXPRESSION");
  assert.equal(asked[0].params.mode, "condition");
  assert.equal(asked[0].params.expression, "PARAM{1,2} > 5", "trimmed");
  assert.match(asked[0].params.id, /^x\d+-\d+$/);
  editor.preview(true);
  assert.equal(sent().length, 2, "preview(true) asks at once");
  type(box, "   ");
  flush();
  assert.equal(sent().length, 2, "blank text isn't asked about");
  const text = Kit.expressionEditor(field(body), { mode: "text", preview: new Element("div") });
  type(text.textarea, "PWR ON");
  flush();
  assert.equal(sent().length, 2, "text mode is never evaluated");
  const gated = Kit.expressionEditor(field(body), { mode: "string", onResult: () => {}, previewWhen: (t) => /PARAM/.test(t) });
  type(gated.textarea, "Plain words");
  flush();
  assert.equal(sent().length, 2, "previewWhen keeps text back");
  type(gated.textarea, "Level PARAM{1,2}");
  flush();
  assert.equal(sent().at(-1).params.mode, "string");
  const silent = Kit.expressionEditor(field(body), { mode: "equation" });
  type(silent.textarea, "1 + 1");
  flush();
  assert.equal(sent().length, 3, "an editor with no preview and no onResult asks nothing");
});

test("each answer goes to its own editor, and only for the text as it stands", () => {
  const { Kit, body, flush, sent } = load(LIVE);
  const seen = { a: [], b: [] };
  const prevA = new Element("div");
  const a = Kit.expressionEditor(field(body), { mode: "condition", preview: prevA, onResult: (r, ed) => seen.a.push([r.result, ed === a]) });
  const b = Kit.expressionEditor(field(body), { mode: "string", onResult: (r) => seen.b.push(r.result) });
  type(a.textarea, "PARAM{1,2} > 5");
  type(b.textarea, "Level PARAM{1,2}");
  flush();
  const [askA, askB] = sent().map((s) => s.params.id);
  assert.notEqual(askA.split("-")[0], askB.split("-")[0], "each editor has its own prefix");
  Kit.deliver("EVAL_RESULT", { json: JSON.stringify({ id: askB, rendered: "Level [R > D > V]", substituted: "Level 9", result: "Level 9", error: "" }) });
  Kit.deliver("EVAL_RESULT", { id: askA, rendered: "[R > D > V] > 5", substituted: "9 > 5", result: "true", error: "" });
  assert.deepEqual(seen, { a: [["true", true]], b: ["Level 9"] });
  assert.match(prevA.text(), /True/);
  assert.equal(prevA.children[0].className, "kit-prev-body");
  type(a.textarea, "PARAM{1,2} > 50");
  Kit.deliver("EVAL_RESULT", { id: askA, result: "false", error: "" });
  assert.equal(seen.a.length, 1, "an answer to earlier text is dropped");
  Kit.deliver("EVAL_RESULT", { id: "nobody-1", result: "true" });
  Kit.deliver("EVAL_RESULT", {});
  assert.equal(seen.a.length + seen.b.length, 2, "an answer for no editor is dropped");
});

test("the preview shows references, values with (not found), and the result or a plain error", () => {
  const { Kit, body, flush, sent } = load(LIVE);
  const prev = new Element("div");
  const foot = prev.appendChild(new Element("div"));
  foot.className = "kit-prev-foot";
  foot.textContent = "Publishes Result";
  const editor = Kit.expressionEditor(field(body), { mode: "condition", preview: prev, label: "Show when" });
  assert.equal(prev.className, "kit-prev");
  assert.equal(prev.children[1], foot, "the page's own line stays under the preview");
  assert.equal(prev.text(), "References Preview appears as you type. Publishes Result");
  type(editor.textarea, "PARAM{1,2} == PARAM{1,3}");
  flush();
  const id = sent()[0].params.id;
  Kit.deliver("EVAL_RESULT", { id, rendered: "[A > B > C] == [A > B > 3]", substituted: "On == ERROR_VARIABLE_NOT_FOUND", result: "", error: "variable 3 not found on device 1" });
  const [body2] = prev.children;
  const [sub, res] = [body2.children[2], body2.children[3]];
  assert.equal(sub.text(), "With current values On == (not found)");
  assert.equal(res.children[2].textContent, "A > B has no variable 3.");
  assert.equal(res.children[2].title, "variable 3 not found on device 1", "the engine's words in its title");
  assert.equal(res.children[1].hidden, true);
  assert.ok(editor.textarea.classList.contains("input-error"));
  type(editor.textarea, "PARAM{1,2} == 1");
  flush();
  Kit.deliver("EVAL_RESULT", { id: sent()[1].params.id, rendered: "[A > B > C] == 1", substituted: "2 == 1", result: "false", error: "" });
  assert.equal(res.children[1].textContent, "False");
  assert.equal(res.children[1].className, "kit-prev-result false");
  assert.ok(!editor.textarea.classList.contains("input-error"));
  editor.setMode("string");
  editor.setValue("Now PARAM{1,2}");
  flush();
  Kit.deliver("EVAL_RESULT", { id: sent()[2].params.id, rendered: "Now [A > B > C]", substituted: "Now 2", result: "Now 2", error: "" });
  assert.equal(sub.hidden, true, "a string's values are its result");
  assert.equal(res.children[1].textContent, "Now 2");
  editor.setValue("");
  assert.equal(prev.text(), "References Preview appears as you type. Publishes Result");
});

test("a hold is the driver's refusal in plain words, gone with the next edit", () => {
  const { Kit, body, flush, sent } = load(LIVE);
  const prev = new Element("div");
  const editor = Kit.expressionEditor(field(body), { mode: "condition", preview: prev, label: "Show when" });
  type(editor.textarea, "PARAM{1,2} >");
  flush();
  Kit.deliver("EVAL_RESULT", { id: sent()[0].params.id, rendered: "[A > B > C] >", substituted: "", result: "", error: `compile error: [string "return __p >"]:1: unexpected symbol near '<eof>'`, hold: true });
  assert.equal(editor.hold, "It stops before it's finished: something should follow the last part.");
  assert.equal(prev.children[0].children[2].hidden, true, "a held text has no values to show");
  type(editor.textarea, "PARAM{1,2} > 1");
  assert.equal(editor.hold, "", "an edit clears it until the next answer");
  flush();
  Kit.deliver("EVAL_RESULT", { id: sent()[1].params.id, result: "", error: "A look can't follow this button's own variables.", hold: "yes" });
  assert.equal(editor.hold, "A look can't follow this button's own variables.");
});

test("the watch count and used() name each variable once", () => {
  const { Kit, body } = load("");
  const watch = new Element("span");
  const editor = Kit.expressionEditor(field(body), { mode: "equation", watch });
  assert.equal(watch.hidden, true);
  editor.setValue("PARAM{1, 2} + PARAM{1,2} + PARAM{ 3 , LEVEL }");
  assert.equal(watch.hidden, false);
  assert.equal(watch.textContent, "Watching 2 references");
  assert.deepEqual(Object.keys(editor.used()), ["1:2", "3:LEVEL"]);
  editor.setValue("PARAM{1,2}");
  assert.equal(watch.textContent, "Watching 1 reference");
});

test("insert puts text at the cursor as the integrator's own edit", () => {
  const { Kit, body } = load("");
  const inputs = [];
  const editor = Kit.expressionEditor(field(body), { mode: "equation", onInput: (t) => inputs.push(t) });
  editor.setValue("abs( - 1)");
  assert.deepEqual(inputs, [], "setValue is the page's, not an edit");
  editor.textarea.selectionStart = editor.textarea.selectionEnd = 4;
  editor.insert("PARAM{5,6}");
  assert.equal(editor.value(), "abs(PARAM{5,6} - 1)");
  assert.equal(editor.textarea.selectionStart, 14);
  assert.deepEqual(inputs, ["abs(PARAM{5,6} - 1)"]);
  assert.match(editor.textarea.parentNode.children[0].innerHTML, /kit-hl-tok">PARAM\{5,6\}/);
  editor.textarea.selectionStart = 0;
  editor.textarea.selectionEnd = 3;
  editor.insert("floor");
  assert.equal(editor.value(), "floor(PARAM{5,6} - 1)", "a selection is replaced");
});

test("the help follows the mode, takes a page's own sections, and opens from its toggle", () => {
  const { Kit, body } = load("");
  const toggle = new Element("button");
  const panel = new Element("div");
  const row = new Element("div");
  const editor = Kit.expressionEditor(field(body), { mode: "condition", help: { toggle, panel, wrap: row } });
  const titles = () => [...panel.innerHTML.matchAll(/<h4>(.*?)<\/h4>/g)].map((m) => m[1]);
  assert.deepEqual(titles(), ["True or false", "Variables", "Comparing", "Text", "Functions"]);
  assert.equal(panel.className, "kit-help");
  assert.equal(toggle.className, "kit-help-toggle");
  assert.equal(toggle.getAttribute("type"), "button");
  assert.equal(row.hidden, true);
  assert.equal(toggle.textContent, "Syntax help");
  toggle.fire("click");
  assert.equal(row.hidden, false);
  assert.equal(toggle.textContent, "Hide syntax help");
  assert.equal(toggle.getAttribute("aria-expanded"), "true");
  toggle.fire("click");
  assert.equal(row.hidden, true);
  editor.setMode("equation");
  assert.deepEqual(titles(), ["Variables", "A number", "Comparing", "Text", "Functions"]);
  editor.setMode("string");
  assert.deepEqual(titles(), ["Variables", "Text with variables"]);
  const own = new Element("div");
  Kit.expressionEditor(field(body), { mode: "text", escapes: true, help: { panel: own } });
  assert.deepEqual([...own.innerHTML.matchAll(/<h4>(.*?)<\/h4>/g)].map((m) => m[1]), ["Variables", "Escapes"]);
  assert.equal(own.hidden, true, "with no wrap, the panel itself hides");
  const shared = new Element("div");
  const help = Kit.expressionHelp({ panel: shared, sections: [{ title: "Hex <payloads>", html: "<p>Raw bytes.</p>" }, "escapes", "nothing"] });
  assert.match(shared.innerHTML, /^<section><h4>Hex &lt;payloads&gt;<\/h4><p>Raw bytes\.<\/p><\/section><section><h4>Escapes<\/h4>/);
  help.open(true);
  assert.equal(shared.hidden, false);
  assert.equal(help.isOpen(), true);
});

test("the names it colors and the help lists are the sandbox's", () => {
  const { Kit, body } = load("");
  const env = SANDBOX.match(/return \{\n\s+__p = bindings,([\s\S]*?)\n\s+\}/);
  assert.ok(env, "the sandbox's environment was found");
  const sandbox = [...env[1].matchAll(/\n\s+([\w]+) = /g)].map((m) => m[1]).sort();
  assert.ok(sandbox.length >= 18, "the sandbox's names were read");
  const list = (name) => JSON.parse(EXPRESSIONS_JS.match(new RegExp("var " + name + " = (\\[.*?\\]);"))[1]);
  const libraries = list("LIBRARIES");
  assert.deepEqual([...list("NAMES"), ...libraries].sort(), sandbox);
  const panel = new Element("div");
  Kit.expressionEditor(field(body), { mode: "equation", help: { panel } });
  sandbox.forEach((name) => assert.ok(panel.innerHTML.includes("<code>" + name), name + " is in the help"));
  const highlight = highlighter();
  sandbox
    .filter((name) => !libraries.includes(name))
    .forEach((name) => assert.match(highlight(name + "(1)", "equation"), new RegExp('kit-hl-fn">' + name + "<"), name + " is colored"));
});

test("an engine error reads as a plain sentence", () => {
  const { Kit } = load("");
  const plain = (raw, text, rendered, label) => Kit.expressionError(raw, text, rendered, label);
  const near = (kind, message) => kind + ' error: [string "return __p[1] > 5"]:1: ' + message;
  assert.equal(plain("result is not a boolean (got number)", "", "", "Show when"), '"Show when" has to come out true or false: add a comparison.');
  assert.equal(plain("result is not a boolean (got number)"), "It has to come out true or false: add a comparison.");
  assert.equal(plain("result is not a number (got string)", "", "", "Value"), '"Value" has to come out a number, and this gives text.');
  assert.equal(plain("variable 1003 not found on device 96", "PARAM{96,1003}", "[Bath > Sensor > 1003]"), "Bath > Sensor has no variable 1003.");
  assert.equal(plain("variable HUMID not found on device 96"), "Device 96 has no variable named HUMID.");
  assert.equal(plain("device 140 not found"), "There's no device 140 in this project.");
  assert.equal(plain("device 140 was removed from the project", "PARAM{140,1}", "[Den > Lamp > 1]"), "Den > Lamp was removed from the project.");
  assert.equal(plain(near("compile", "unfinished string near '<eof>'")), "It stops before it's finished: a closing quote is missing.");
  assert.equal(plain(near("compile", "')' expected near '<eof>'")), "It stops before it's finished: ) is missing.");
  assert.equal(plain(near("compile", "'<eof>' expected near '='")), "Use == to compare, not =.");
  assert.equal(plain(near("compile", "'<eof>' expected near '!'")), "Use ~= for not equal, not !=.");
  assert.equal(plain(near("compile", "'<eof>' expected near 'x'")), "It reads as finished before x: that part is extra, or something before it is missing.");
  assert.equal(plain(near("compile", "unexpected symbol near '*'")), "Something is out of place near *.");
  assert.equal(plain(near("compile", "malformed number near '1.2.3'")), "1.2.3 isn't a number.");
  assert.equal(plain(near("runtime", "attempt to compare number with string")), "This can't compare a number with text. Both sides of < or > have to be the same kind.");
  assert.equal(plain(near("runtime", "attempt to compare nil with number")), "This compares a number with something that has no value. A name may be misspelled, or text may need quotes.");
  assert.equal(plain(near("runtime", "attempt to compare two boolean values")), "< and > only work on numbers or text.");
  assert.equal(plain(near("runtime", "bad argument #1 to 'floor' (number expected, got string)")), "floor needs a number there, and this gives it text.");
  assert.equal(plain(near("runtime", "attempt to call global 'avg' (a nil value)")), "There's no function named avg.");
  assert.equal(plain(near("runtime", "attempt to perform arithmetic on field '?' (a string value)")), "This does math on text: a value here isn't a number.");
  assert.equal(plain(near("runtime", "attempt to perform arithmetic on global 'x' (a nil value)")), "There's no value named x, so it can't be used in math.");
  assert.equal(plain(near("runtime", "attempt to index global 'y' (a nil value)")), "There's nothing named y to read from.");
  assert.equal(plain(near("runtime", "attempt to concatenate a boolean value")), "Only text and numbers can be joined, and this has true or false.");
  assert.equal(plain("runtime error: the expression ran too long"), "The expression ran too long.");
  assert.equal(plain(near("runtime", "something new about __p[2]")), "something new about a variable");
  assert.equal(plain("something it has never seen"), "something it has never seen", "what isn't recognized stays as it is");
});

test("in demo mode, a preview goes to the page's own demo answer", () => {
  const { Kit, body, flush } = load("");
  const asked = [];
  Kit.demoMode((command, params) => asked.push([command, params.mode, params.expression]));
  const editor = Kit.expressionEditor(field(body), { mode: "condition", onResult: () => {} });
  type(editor.textarea, "PARAM{9001,1} > 50");
  flush();
  assert.deepEqual(asked, [["_EVAL_EXPRESSION", "condition", "PARAM{9001,1} > 50"]]);
});
