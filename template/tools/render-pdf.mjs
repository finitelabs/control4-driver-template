#!/usr/bin/env node
// Render an HTML file to PDF via headless Chromium (puppeteer).
// Drop-in replacement for `electron-pdf --marginsType 0 --input X --output Y`.
//
// Usage: node tools/render-pdf.mjs <input.html> <output.pdf>

import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const [, , input, output] = process.argv;
if (!input || !output) {
  console.error("Usage: render-pdf.mjs <input.html> <output.pdf>");
  process.exit(1);
}

const puppeteer = (await import("puppeteer")).default;

const browser = await puppeteer.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-setuid-sandbox"],
});
try {
  const page = await browser.newPage();
  await page.emulateMediaType("print");
  await page.goto(pathToFileURL(resolve(input)).href, {
    waitUntil: "networkidle0",
  });
  // electron-pdf --marginsType 0 is "default" margins (~0.4in / 10mm), NOT zero.
  // Match those to keep our output visually consistent with the previous pipeline.
  await page.pdf({
    path: resolve(output),
    format: "Letter",
    printBackground: true,
    margin: {
      top: "0.4in",
      right: "0.4in",
      bottom: "0.4in",
      left: "0.4in",
    },
  });
} finally {
  await browser.close();
}
