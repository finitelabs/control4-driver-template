const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  doc.swatches.push({ name: 'Brand/Accent', color: '#109eff' });
  doc.swatches.push({ name: 'Brand/Accent Dark', color: '#0e86d9' });
  doc.processPendingChanges();
  console.log(JSON.stringify({
    ok: true,
    swatches: doc.swatches.map(function (s) { return { name: s.name, color: String(s.color) }; }),
  }));
}
