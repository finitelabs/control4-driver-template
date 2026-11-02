const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var ids = ['1014B3F9-19AF-43C3-9C31-A396B4014272', '35E15553-A3B0-4AAF-844B-51D1EE16A848'];
  var grids = ids.map(function (id) { return sketch.find('#' + id, doc)[0]; });
  if (grids.some(function (g) { return !g; })) {
    console.log(JSON.stringify({ ok: false, error: 'GRID_NOT_FOUND', found: grids.map(function (g) { return !!g; }) }));
  } else {
    grids.forEach(function (g) { g.hidden = true; });
    console.log(JSON.stringify({
      ok: true,
      grids: grids.map(function (g) { return { name: g.name, parent: g.parent.name, hidden: g.hidden }; }),
    }));
  }
}
