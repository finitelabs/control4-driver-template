// Joins the parts of a message from lib/ui.lua. Returns the message on its last part, null before that.
// Part 1 starts afresh, as a driver's ids restart when it reloads under an open page; parts of a
// message whose start was missed are dropped, as a page can connect partway through one.
var gUiParts = {};
function uiJoin(command, frame) {
  var m = /^(\d+):(\d+):(\d+):([\s\S]*)$/.exec(frame || '');
  if (!m) return null;
  if (m[2] === '1') gUiParts[command] = { id: m[1], chunks: [] };
  var message = gUiParts[command];
  if (!message || message.id !== m[1]) return null;
  message.chunks.push(m[4]);
  if (message.chunks.length < Number(m[3])) return null;
  delete gUiParts[command];
  return JSON.parse(message.chunks.join(''));
}
