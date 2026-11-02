const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var group = sketch.find('#2F7F34BA-5593-47CF-8C51-BD9E74D7F74B', doc)[0];
  var sample = sketch.find('#71C545B9-B509-4C53-9340-314A3CD522B8', doc)[0];
  var master = doc.getSymbols().find(function (m) { return m.name === 'Icon'; });
  if (!group || !sample || !master) {
    console.log(JSON.stringify({ ok: false, error: 'NOT_FOUND', group: !!group, sample: !!sample, master: !!master }));
  } else {
    group.name = 'Icon';
    var mark = master.createNewInstance();
    mark.parent = group;
    mark.name = 'Icon';
    mark.frame = { x: 17, y: 22, width: 840, height: 840 };
    sample.remove();
    console.log(JSON.stringify({
      ok: true,
      group: { name: group.name, frame: group.frame },
      layers: group.layers.map(function (l) { return { name: l.name, type: l.type, frame: l.frame }; }),
    }));
  }
}
