const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var order = ['Documentation Header', 'Driver Central Driver Card', 'Website Card - Light', 'Website Card - Dark', 'Finite Labs Logo'];
  var frames = order.map(function (name) {
    return doc.pages[0].layers.find(function (l) { return l.name === name; });
  });
  if (frames.some(function (f) { return !f; })) {
    console.log(JSON.stringify({ ok: false, error: 'NOT_FOUND', found: frames.map(function (f) { return !!f; }) }));
  } else {
    var x = 3156;
    frames.forEach(function (f) {
      f.frame = { x: x, y: -357, width: f.frame.width, height: f.frame.height };
      x += f.frame.width + 100;
    });
    console.log(JSON.stringify({
      ok: true,
      frames: frames.map(function (f) { return { name: f.name, frame: f.frame }; }),
    }));
  }
}
