#!/usr/bin/env node
// Convert a Markdown file to a self-contained GitHub-styled HTML file.
// Replaces `generate-md --layout github` (markdown-styles).
//
// Usage: node tools/render-md.mjs <input.md> <output-dir>
//        writes <output-dir>/index.html
//
// The emitted HTML is consumed two ways:
//   1. shipped inside the driver (Control4's documentation viewer), and
//   2. rendered to PDF by tools/render-pdf.py (WeasyPrint).
// WeasyPrint is a real CSS Paged Media engine, so page-break markers in the
// source (`<div style="page-break-after: always"></div>`) are honored as-is —
// no rewriting required. The @page rule below sets Letter size + margins to
// match the previous electron-pdf output (--marginsType 0 ≈ 0.4in default).

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const markdownIt = (await import("markdown-it")).default;
const hljs = (await import("highlight.js")).default;

const [, , input, outDir] = process.argv;
if (!input || !outDir) {
  console.error("Usage: render-md.mjs <input.md> <output-dir>");
  process.exit(1);
}

const inputPath = resolve(input);
const outputPath = join(resolve(outDir), "index.html");

const md = markdownIt({
  html: true,
  linkify: true,
  typographer: true,
  highlight: (str, lang) => {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return `<pre><code class="hljs language-${lang}">${hljs.highlight(str, { language: lang, ignoreIllegals: true }).value}</code></pre>`;
      } catch {}
    }
    return `<pre><code class="hljs">${md.utils.escapeHtml(str)}</code></pre>`;
  },
});

const source = await readFile(inputPath, "utf8");
const bodyHtml = md.render(source);

const githubMarkdownCss = readFileSync(
  require.resolve("github-markdown-css/github-markdown-light.css"),
  "utf8"
);
const hljsCss = readFileSync(
  require.resolve("highlight.js/styles/github.css"),
  "utf8"
);

const title = basename(inputPath, ".md");
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
${githubMarkdownCss}
${hljsCss}
/* Screen layout (Control4 documentation viewer). */
.markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
@media (max-width: 767px) { .markdown-body { padding: 15px; } }
/* Print layout (WeasyPrint to PDF). Letter + 0.4in margins matches the prior
   electron-pdf --marginsType 0 output. Page margins come from @page; the body
   keeps the same 45px horizontal padding as screen so text is inset like the
   old output, while explicit-width images (e.g. the 500px header logo) render
   at their intended size. */
@page { size: Letter; margin: 0.4in; }
@media print {
  .markdown-body { max-width: none; padding: 0 45px; margin: 0; }
  /* Automatic, content-aware pagination. Rather than hand-placed page breaks
     (which land oddly as content changes), let the paged-media engine decide:
     neutralize any legacy page-break markers left in source markdown, keep
     headings attached to the content that follows, never split a table / code
     block / figure across a page boundary, and avoid orphan/widow lines. */
  [style*="page-break"] { page-break-after: auto !important; page-break-before: auto !important; }
  h1, h2, h3, h4, h5, h6 { break-after: avoid; }
  table, pre, figure, tr { break-inside: avoid; }
  p, li { orphans: 3; widows: 3; }
}
</style>
</head>
<body class="markdown-body">
${bodyHtml}
</body>
</html>
`;

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, html, "utf8");
