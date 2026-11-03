const net = require('net');
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
let blackhole = false;
let accepted = 0;
let closed = 0;
const sockets = new Set();
function record() {
  // Write then rename, so a reader never sees a partial file.
  const tmp = path.join(dir, 'counts.tmp');
  fs.writeFileSync(tmp, `${accepted} ${closed}`);
  fs.renameSync(tmp, path.join(dir, 'counts'));
}
const server = net.createServer(socket => {
  accepted++;
  sockets.add(socket);
  record();
  socket.on('error', () => {});
  socket.on('close', () => { sockets.delete(socket); closed++; record(); });
  if (blackhole) { socket.resume(); return; }
  const upstream = net.createConnection({host: '127.0.0.1', port: 1883});
  upstream.on('error', () => socket.destroy());
  socket.on('close', () => upstream.destroy());
  upstream.on('close', () => socket.destroy());
  socket.pipe(upstream).pipe(socket);
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(dir, 'port'), String(server.address().port)));
setInterval(() => {
  if (!blackhole && fs.existsSync(path.join(dir, 'blackhole'))) {
    blackhole = true;
    for (const socket of sockets) socket.destroy();
    fs.writeFileSync(path.join(dir, 'switched'), 'yes');
  }
}, 20);
