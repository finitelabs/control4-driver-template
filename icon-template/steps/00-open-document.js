const sketch = require('sketch');
sketch.Document.open(__DOCUMENT__, function (err, doc) {
  if (err || !doc) {
    console.log(JSON.stringify({ ok: false, error: String(err) }));
  } else {
    console.log(JSON.stringify({
      ok: true,
      docId: String(doc.id),
      sketch: String(sketch.version.sketch),
      pages: doc.pages.map(function (p) { return p.name; }),
    }));
  }
});
