const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  doc.selectedPage = doc.pages[0];
  doc.save(function (err) {
    console.log(JSON.stringify({ ok: !err, error: err ? String(err) : null }));
  });
}
