const { readFileSync, writeFileSync } = require('fs');
const { inflateRawSync } = require('zlib');
const fzstd = require('fzstd');
const kiwi = require('kiwi-schema');

const buf = readFileSync('/tmp/handgallery_fig/canvas.fig');
let off = 12;
const chunks = [];
while (off < buf.length) {
  const len = buf.readUInt32LE(off); off += 4;
  chunks.push(buf.slice(off, off + len)); off += len;
}

function decompress(b) {
  if (b[0] === 0x28 && b[1] === 0xb5 && b[2] === 0x2f && b[3] === 0xfd) {
    return Buffer.from(fzstd.decompress(new Uint8Array(b)));
  }
  return inflateRawSync(b);
}

const schemaBuf = decompress(chunks[0]);
const dataBuf = decompress(chunks[1]);
console.log('schema:', schemaBuf.length, 'data:', dataBuf.length);

const schema = kiwi.compileSchema(kiwi.decodeBinarySchema(new Uint8Array(schemaBuf)));
const msg = schema.decodeMessage(new Uint8Array(dataBuf));
console.log('nodeChanges:', msg.nodeChanges ? msg.nodeChanges.length : 'none');

// blobs hold vector data etc. — drop heavy bytes but keep image hashes
writeFileSync('/tmp/handgallery_fig/scene.json', JSON.stringify(msg, (k, v) => {
  if (k === 'blobs') return undefined;
  if (v && v.constructor === Uint8Array) {
    return Buffer.from(v).toString('hex');
  }
  return v;
}, 1));
console.log('wrote scene.json');
