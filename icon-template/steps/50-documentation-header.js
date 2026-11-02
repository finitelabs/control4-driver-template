const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var page = doc.pages[0];
  var master = doc.getSymbols().find(function (m) { return m.name === 'Icon'; });
  var logo = master.createNewInstance();
  logo.name = 'Brand Logo (replace)';
  logo.frame = { x: 0, y: 0, width: 600, height: 600 };
  var name = new sketch.Text({
    name: 'Driver Name',
    text: 'Driver Name',
    style: { fontFamily: 'Helvetica Neue', fontSize: 350, textColor: '#000000ff', borders: [] },
  });
  var header = new sketch.Group.Frame({
    parent: page,
    name: 'Documentation Header',
    frame: { x: 3156, y: -357, width: 2000, height: 649 },
    background: { enabled: true, color: '#ffffffff', includedInExport: false },
    stackLayout: {
      direction: sketch.StackLayout.Direction.Row,
      alignItems: sketch.StackLayout.AlignItems.Center,
      gap: 100,
      padding: 0,
    },
    layers: [name, logo],
  });
  logo.horizontalSizing = sketch.FlexSizing.Fixed;
  logo.verticalSizing = sketch.FlexSizing.Fixed;
  logo.frame = { x: 0, y: 0, width: 600, height: 600 };
  name.horizontalSizing = sketch.FlexSizing.Fit;
  name.verticalSizing = sketch.FlexSizing.Fit;
  header.verticalSizing = sketch.FlexSizing.Fixed;
  header.horizontalSizing = sketch.FlexSizing.Fit;
  header.exportFormats = [{ fileFormat: 'png', size: '1x', suffix: '@1x' }];
  header.stackLayout.apply();
  console.log(JSON.stringify({
    ok: true,
    id: header.id,
    frame: header.frame,
    layers: header.layers.map(function (l) { return { name: l.name, frame: l.frame }; }),
    exports: header.exportFormats.map(function (f) { return { size: f.size, suffix: f.suffix, prefix: f.prefix, fileFormat: f.fileFormat }; }),
  }));
}
