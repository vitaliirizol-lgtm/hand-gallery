// Export vector nodes from .fig to SVG — decodes vectorNetworkBlob + fillGeometry commandsBlob.
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
  if (b[0] === 0x28 && b[1] === 0xb5 && b[2] === 0x2f && b[3] === 0xfd) return Buffer.from(fzstd.decompress(new Uint8Array(b)));
  return inflateRawSync(b);
}
const schema = kiwi.compileSchema(kiwi.decodeBinarySchema(new Uint8Array(decompress(chunks[0]))));
const msg = schema.decodeMessage(new Uint8Array(decompress(chunks[1])));
const nodes = msg.nodeChanges;
const blobs = msg.blobs;
const key = g => `${g.sessionID}:${g.localID}`;
const byId = {};
for (const n of nodes) byId[key(n.guid)] = { n, children: [] };
for (const n of nodes) {
  if (n.parentIndex && byId[key(n.parentIndex.guid)]) byId[key(n.parentIndex.guid)].children.push({ pos: n.parentIndex.position, node: byId[key(n.guid)] });
}
for (const k in byId) {
  byId[k].children.sort((a, b) => (a.pos < b.pos ? -1 : 1));
  byId[k].children = byId[k].children.map(c => c.node);
}

const r2 = v => Math.round(v * 100) / 100;

// ---- vectorNetworkBlob decoder ----
function decodeVectorNetwork(idx) {
  const b = Buffer.from(blobs[idx].bytes);
  let o = 0;
  const u32 = () => { const v = b.readUInt32LE(o); o += 4; return v; };
  const f32 = () => { const v = b.readFloatLE(o); o += 4; return v; };
  const vCount = u32(), sCount = u32(), rCount = u32();
  const vertices = [];
  for (let i = 0; i < vCount; i++) { const styleID = u32(); vertices.push({ styleID, x: f32(), y: f32() }); }
  const segments = [];
  for (let i = 0; i < sCount; i++) {
    const styleID = u32();
    const start = u32(), t0x = f32(), t0y = f32();
    const end = u32(), t1x = f32(), t1y = f32();
    segments.push({ styleID, start, t0x, t0y, end, t1x, t1y });
  }
  const regions = [];
  for (let i = 0; i < rCount; i++) {
    const header = u32();
    const loopCount = u32();
    const loops = [];
    for (let l = 0; l < loopCount; l++) {
      const segCount = u32();
      const segs = [];
      for (let s = 0; s < segCount; s++) segs.push(u32());
      loops.push(segs);
    }
    regions.push({ windingRule: header & 1, styleID: header >>> 1, loops });
  }
  if (o !== b.length) console.error(`  [warn] blob ${idx}: consumed ${o}/${b.length}`);
  return { vertices, segments, regions };
}

function segPath(net, segIdx, reverse, startFresh, cur) {
  const s = net.segments[segIdx];
  const a = net.vertices[reverse ? s.end : s.start];
  const bV = net.vertices[reverse ? s.start : s.end];
  const ta = reverse ? { x: s.t1x, y: s.t1y } : { x: s.t0x, y: s.t0y };
  const tb = reverse ? { x: s.t0x, y: s.t0y } : { x: s.t1x, y: s.t1y };
  let d = '';
  if (startFresh) d += `M${r2(a.x)} ${r2(a.y)}`;
  if (ta.x === 0 && ta.y === 0 && tb.x === 0 && tb.y === 0) d += `L${r2(bV.x)} ${r2(bV.y)}`;
  else d += `C${r2(a.x + ta.x)} ${r2(a.y + ta.y)} ${r2(bV.x + tb.x)} ${r2(bV.y + tb.y)} ${r2(bV.x)} ${r2(bV.y)}`;
  return { d, endVertex: reverse ? s.start : s.end, startVertex: reverse ? s.end : s.start };
}

function networkToPath(net) {
  // returns {regionPaths: [{d, styleID, winding}], openPath} — leftover segments as open chains
  const regionPaths = [];
  const used = new Set();
  for (const reg of net.regions) {
    let d = '';
    for (const loop of reg.loops) {
      let cur = null; let first = true;
      for (const si of loop) {
        used.add(si);
        const s = net.segments[si];
        const reverse = cur !== null && s.start !== cur && s.end === cur;
        const r = segPath(net, si, reverse, first, cur);
        d += r.d; cur = r.endVertex; first = false;
      }
      d += 'Z';
    }
    if (d) regionPaths.push({ d, styleID: reg.styleID, winding: reg.windingRule });
  }
  // open chains from unused segments
  let open = '';
  let cur = null;
  const remaining = net.segments.map((_, i) => i).filter(i => !used.has(i));
  for (const si of remaining) {
    const s = net.segments[si];
    const startFresh = cur === null || (s.start !== cur && s.end !== cur);
    const reverse = !startFresh && s.end === cur && s.start !== cur;
    const r = segPath(net, si, reverse, startFresh, cur);
    open += r.d; cur = r.endVertex;
  }
  return { regionPaths, open };
}

// ---- commandsBlob decoder (derived geometry) ----
function commandsToPath(idx) {
  const b = Buffer.from(blobs[idx].bytes);
  let o = 0; let d = '';
  const f = () => { const v = b.readFloatLE(o); o += 4; return r2(v); };
  while (o < b.length) {
    const cmd = b.readUInt8(o); o += 1;
    if (cmd === 0) d += 'Z';
    else if (cmd === 1) d += `M${f()} ${f()}`;
    else if (cmd === 2) d += `L${f()} ${f()}`;
    else if (cmd === 3) d += `Q${f()} ${f()} ${f()} ${f()}`;
    else if (cmd === 4) d += `C${f()} ${f()} ${f()} ${f()} ${f()} ${f()}`;
    else return null;
  }
  return d;
}

function rgba(c, o) {
  const a = (c.a ?? 1) * (o ?? 1); const fl = v => Math.round(v * 255);
  return a >= 0.999 ? `rgb(${fl(c.r)},${fl(c.g)},${fl(c.b)})` : `rgba(${fl(c.r)},${fl(c.g)},${fl(c.b)},${a.toFixed(3)})`;
}

let gradCounter = 0;
function paintRef(p, defs) {
  if (p.type === 'SOLID') return rgba(p.color, p.opacity);
  if (p.type && p.type.startsWith('GRADIENT')) {
    const id = `g${gradCounter++}`;
    const stops = (p.stops || []).map(s => `<stop offset="${s.position}" stop-color="${rgba(s.color, p.opacity)}"/>`).join('');
    // paint.transform maps object unit space -> gradient space; invert to get axis endpoints
    let x1 = 0, y1 = 0, x2 = 0, y2 = 1;
    const t = p.transform;
    if (t) {
      const det = t.m00 * t.m11 - t.m01 * t.m10;
      if (Math.abs(det) > 1e-9) {
        const inv = (x, y) => [
          (t.m11 * (x - t.m02) - t.m01 * (y - t.m12)) / det,
          (-t.m10 * (x - t.m02) + t.m00 * (y - t.m12)) / det,
        ];
        [x1, y1] = inv(0, 0.5); [x2, y2] = inv(1, 0.5);
      }
    }
    defs.push(`<linearGradient id="${id}" x1="${r2(x1)}" y1="${r2(y1)}" x2="${r2(x2)}" y2="${r2(y2)}">${stops}</linearGradient>`);
    return `url(#${id})`;
  }
  return 'gray';
}

function nodeShape(n, defs) {
  // returns inner SVG for the node's own geometry (no transform)
  let out = '';
  const fills = (n.fillPaints || []).filter(p => p.visible !== false);
  const strokes = (n.strokePaints || []).filter(p => p.visible !== false);
  const sw = n.strokeWeight ?? 1;
  if (n.vectorData && n.vectorData.vectorNetworkBlob !== undefined) {
    const net = decodeVectorNetwork(n.vectorData.vectorNetworkBlob);
    // network coords live in normalizedSize space; scale to node size
    const ns = n.vectorData.normalizedSize;
    if (ns && n.size && ns.x > 0 && ns.y > 0 && (Math.abs(ns.x - n.size.x) > 0.01 || Math.abs(ns.y - n.size.y) > 0.01)) {
      const kx = n.size.x / ns.x, ky = n.size.y / ns.y;
      for (const v of net.vertices) { v.x *= kx; v.y *= ky; }
      for (const s of net.segments) { s.t0x *= kx; s.t0y *= ky; s.t1x *= kx; s.t1y *= ky; }
    }
    const { regionPaths, open } = networkToPath(net);
    const styleTable = {};
    for (const e of (n.vectorData.styleOverrideTable || [])) styleTable[e.styleID] = e;
    if (regionPaths.length) {
      for (const rp of regionPaths) {
        const override = styleTable[rp.styleID];
        const rFills = (override && override.fillPaints ? override.fillPaints : n.fillPaints || []).filter(p => p.visible !== false);
        for (const p of rFills) out += `<path d="${rp.d}" fill="${paintRef(p, defs)}" fill-rule="${rp.winding ? 'evenodd' : 'nonzero'}"/>`;
        for (const p of strokes) out += `<path d="${rp.d}" fill="none" stroke="${paintRef(p, defs)}" stroke-width="${sw}"/>`;
      }
    } else if (fills.length && !open) {
      // no regions, no open: nothing
    }
    if (open) {
      for (const p of strokes) out += `<path d="${open}" fill="none" stroke="${paintRef(p, defs)}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
      if (!strokes.length && fills.length) for (const p of fills) out += `<path d="${open}Z" fill="${paintRef(p, defs)}"/>`;
    }
    return out;
  }
  if (n.fillGeometry && n.fillGeometry.length) {
    for (const geo of n.fillGeometry) {
      const d = commandsToPath(geo.commandsBlob);
      if (!d) continue;
      for (const p of fills) out += `<path d="${d}" fill="${paintRef(p, defs)}" fill-rule="${geo.windingRule === 'ODD' ? 'evenodd' : 'nonzero'}"/>`;
    }
    if (n.strokeGeometry) for (const geo of n.strokeGeometry) {
      const d = commandsToPath(geo.commandsBlob);
      if (!d) continue;
      for (const p of strokes) out += `<path d="${d}" fill="${paintRef(p, defs)}"/>`;
    }
    return out;
  }
  // primitive shapes
  const w = n.size ? n.size.x : 0, h = n.size ? n.size.y : 0;
  if (n.type === 'ELLIPSE') {
    for (const p of fills) out += `<ellipse cx="${w/2}" cy="${h/2}" rx="${w/2}" ry="${h/2}" fill="${paintRef(p, defs)}"/>`;
    for (const p of strokes) out += `<ellipse cx="${w/2}" cy="${h/2}" rx="${w/2}" ry="${h/2}" fill="none" stroke="${paintRef(p, defs)}" stroke-width="${sw}"/>`;
  } else if (n.type === 'ROUNDED_RECTANGLE' || n.type === 'RECTANGLE') {
    const r = n.rectangleTopLeftCornerRadius ?? n.cornerRadius ?? 0;
    for (const p of fills) out += `<rect width="${w}" height="${h}" rx="${r}" fill="${paintRef(p, defs)}"/>`;
    for (const p of strokes) out += `<rect width="${w}" height="${h}" rx="${r}" fill="none" stroke="${paintRef(p, defs)}" stroke-width="${sw}"/>`;
  }
  return out;
}

function exportNode(me, defs) {
  const n = me.n;
  if (n.visible === false) return '';
  const t = n.transform || { m00: 1, m01: 0, m02: 0, m10: 0, m11: 1, m12: 0 };
  let out = `<g transform="matrix(${t.m00} ${t.m10} ${t.m01} ${t.m11} ${t.m02} ${t.m12})"${n.opacity !== undefined && n.opacity < 1 ? ` opacity="${n.opacity}"` : ''}>`;
  out += nodeShape(n, defs);
  if (n.type === 'INSTANCE' && n.symbolData && byId[key(n.symbolData.symbolID)]) {
    const sym = byId[key(n.symbolData.symbolID)];
    const sx = (n.size && sym.n.size && sym.n.size.x) ? n.size.x / sym.n.size.x : 1;
    const sy = (n.size && sym.n.size && sym.n.size.y) ? n.size.y / sym.n.size.y : 1;
    out += `<g transform="scale(${sx} ${sy})">`;
    for (const c of sym.children) out += exportNode(c, defs);
    out += '</g>';
  }
  for (const c of me.children) out += exportNode(c, defs);
  out += '</g>';
  return out;
}

function exportSvg(id, outfile) {
  const me = byId[id];
  if (!me) { console.log('not found', id); return; }
  const n = me.n;
  const w = r2(n.size.x), h = r2(n.size.y);
  const defs = [];
  let body = nodeShape(n, defs);
  if (n.type === 'INSTANCE' && n.symbolData && byId[key(n.symbolData.symbolID)]) {
    const sym = byId[key(n.symbolData.symbolID)];
    const sx = n.size.x / sym.n.size.x, sy = n.size.y / sym.n.size.y;
    body += `<g transform="scale(${sx} ${sy})">`;
    for (const c of sym.children) body += exportNode(c, defs);
    body += '</g>';
  }
  for (const c of me.children) body += exportNode(c, defs);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}"><defs>${defs.join('')}</defs>${body}</svg>`;
  writeFileSync(outfile, svg);
  console.log('wrote', outfile, `${w}x${h}`);
}

const [id, outfile] = process.argv.slice(2);
if (id && outfile) exportSvg(id, outfile);
module.exports = { exportSvg, byId, nodes, key };
