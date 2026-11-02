const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var text = [
    'Finite Labs driver icons',
    '1. Set the Brand/Accent and Brand/Accent Dark color variables.',
    '2. Replace the circle in the Icon and Icon White symbols with the brand\'s mark, from its official SVG kit.',
    '3. Replace Brand Logo in Documentation Header with the brand\'s logo, and set the driver name.',
    '4. Leave the grids hidden. Export with make icons, or select a frame and use Export.',
  ].join('\n');
  var notes = new sketch.Text({
    parent: doc.pages[0],
    name: 'Finite Labs Notes',
    text: text,
    frame: { x: 3156, y: -667, width: 2400, height: 200 },
    style: { fontFamily: 'Helvetica Neue', fontSize: 36, textColor: '#8a8a8aff', borders: [] },
  });
  notes.adjustToFit();
  console.log(JSON.stringify({ ok: true, id: notes.id, frame: notes.frame }));
}
