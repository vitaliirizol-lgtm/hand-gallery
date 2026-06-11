const { readFileSync, writeFileSync } = require('fs');
const msg = JSON.parse(readFileSync('/tmp/handgallery_fig/scene.json', 'utf8'));

const nodes = msg.nodeChanges;
const byId = {};
const key = g => `${g.sessionID}:${g.localID}`;
for (const n of nodes) byId[key(n.guid)] = { n, children: [] };

const roots = [];
for (const n of nodes) {
  const me = byId[key(n.guid)];
  if (n.parentIndex && byId[key(n.parentIndex.guid)]) {
    byId[key(n.parentIndex.guid)].children.push({ pos: n.parentIndex.position, node: me });
  } else {
    roots.push(me);
  }
}
for (const k2 in byId) {
  byId[k2].children.sort((a, b) => (a.pos < b.pos ? -1 : a.pos > b.pos ? 1 : 0));
  byId[k2].children = byId[k2].children.map(c => c.node);
}

function rgba(c, opacity) {
  if (!c) return null;
  const a = (c.a !== undefined ? c.a : 1) * (opacity !== undefined ? opacity : 1);
  const f = v => Math.round(v * 255);
  return a >= 0.999 ? `rgb(${f(c.r)},${f(c.g)},${f(c.b)})` : `rgba(${f(c.r)},${f(c.g)},${f(c.b)},${a.toFixed(3)})`;
}

function paintStr(p) {
  if (!p) return null;
  if (p.visible === false) return null;
  if (p.type === 'SOLID') return rgba(p.color, p.opacity);
  if (p.type && p.type.startsWith('GRADIENT')) {
    const stops = (p.stops || []).map(s => `${rgba(s.color)} ${(s.position * 100).toFixed(0)}%`).join(', ');
    return `${p.type}(${stops})`;
  }
  if (p.type === 'IMAGE') return `IMAGE(${p.image && p.image.hash ? p.image.hash : '?'} mode=${p.imageScaleMode || ''} op=${p.opacity !== undefined ? p.opacity : 1})`;
  return p.type;
}

function fmt(me, depth, lines) {
  const n = me.n;
  if (n.visible === false) return;
  const ind = ' '.repeat(depth);
  const sz = n.size ? `${Math.round(n.size.x)}x${Math.round(n.size.y)}` : '';
  const t = n.transform ? `@(${Math.round(n.transform.m02)},${Math.round(n.transform.m12)})` : '';
  let extras = [];
  if (n.fillPaints) {
    const fs = n.fillPaints.map(paintStr).filter(Boolean);
    if (fs.length) extras.push(`fill=[${fs.join(' | ')}]`);
  }
  if (n.strokePaints) {
    const ss = n.strokePaints.map(paintStr).filter(Boolean);
    if (ss.length) extras.push(`stroke=[${ss.join(' | ')}] w=${n.strokeWeight !== undefined ? n.strokeWeight : 1}`);
  }
  if (n.cornerRadius) extras.push(`r=${n.cornerRadius}`);
  if (n.rectangleTopLeftCornerRadius !== undefined) extras.push(`r=[${n.rectangleTopLeftCornerRadius},${n.rectangleTopRightCornerRadius},${n.rectangleBottomRightCornerRadius},${n.rectangleBottomLeftCornerRadius}]`);
  if (n.stackMode && n.stackMode !== 'NONE') {
    extras.push(`stack=${n.stackMode} gap=${n.stackSpacing !== undefined ? n.stackSpacing : 0} pad=[${n.stackVerticalPadding||0},${n.stackPaddingRight||0},${n.stackPaddingBottom||0},${n.stackHorizontalPadding||0}] align=${n.stackPrimaryAlignItems||''}/${n.stackCounterAlignItems||''} sizing=${n.stackPrimarySizing||''}/${n.stackCounterSizing||''}`);
  }
  if (n.opacity !== undefined && n.opacity < 1) extras.push(`opacity=${n.opacity.toFixed(2)}`);
  if (n.effects && n.effects.length) {
    extras.push('fx=[' + n.effects.map(e => `${e.type} ${rgba(e.color)||''} off(${e.offset?e.offset.x:0},${e.offset?e.offset.y:0}) blur=${e.radius}`).join(' | ') + ']');
  }
  let textInfo = '';
  if (n.type === 'TEXT') {
    const chars = n.textData && n.textData.characters !== undefined ? JSON.stringify(n.textData.characters) : '';
    const font = n.fontName ? `${n.fontName.family} ${n.fontName.style}` : '';
    const lh = n.lineHeight ? `${n.lineHeight.value}${n.lineHeight.units === 'PERCENT' ? '%' : n.lineHeight.units === 'PIXELS' ? 'px' : ''}` : '';
    const ls = n.letterSpacing && n.letterSpacing.value ? ` ls=${n.letterSpacing.value}${n.letterSpacing.units === 'PERCENT' ? '%' : 'px'}` : '';
    textInfo = ` TEXT ${chars} font="${font}" size=${n.fontSize} lh=${lh}${ls} align=${n.textAlignHorizontal || 'LEFT'} case=${n.textCase || ''}`;
  }
  lines.push(`${ind}${n.type || '?'} "${n.name || ''}" ${sz}${t} ${extras.join(' ')}${textInfo}`);
  for (const c of me.children) fmt(c, depth + 1, lines);
}

const lines = [];
for (const r of roots) fmt(r, 0, lines);
writeFileSync('/tmp/handgallery_fig/outline.txt', lines.join('\n'));
console.log('lines:', lines.length);
console.log(lines.slice(0, 40).join('\n'));
