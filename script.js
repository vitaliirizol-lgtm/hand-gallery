// Hand Gallery — card rendering (design ported from Claude design export)

const REPLAY_URL = 'https://quintace.ai/replay/aID5LWzaqc';

const FEATURED_HANDS = [
  { id: 'f1', title: 'Value-betting is win rate steak. Bluffing is just the sizzle.' },
  { id: 'f2', title: "Ivey's triple barrel on a four-flush runout." },
  { id: 'f3', title: 'A hero call with fourth pair — solver approved.' },
];

const ALL_HANDS = [
  { id: 'h1', title: 'The check-raise that turned a cooler into a fold.' },
  { id: 'h2', title: 'Slow-playing aces out of position — the full price.' },
  { id: 'h3', title: 'When blockers matter more than equity.' },
  { id: 'h4', title: 'Turning a missed draw into the perfect bluff.' },
  { id: 'h5', title: 'Pot control with top pair on a wet board.' },
  { id: 'h6', title: 'Folding kings preflop: paranoia or precision?' },
  { id: 'h7', title: 'The min-raise that told the whole story.' },
  { id: 'h8', title: 'Calling down with ace-high in a leveling war.' },
  { id: 'h9', title: 'A river overbet only the solver loves.' },
];

function makeCard(hand, featured) {
  const a = document.createElement('a');
  a.className = 'hand-card' + (featured ? ' featured' : '');
  a.href = hand.url || REPLAY_URL;
  a.target = '_blank';
  a.rel = 'noopener noreferrer';

  const art = document.createElement('div');
  art.className = 'hand-art';
  const img = document.createElement('img');
  img.className = 'art-img';
  img.src = hand.preview || (featured ? 'assets/hand-preview.png' : 'assets/hand-preview-board.png');
  img.alt = '';
  img.loading = 'lazy';
  img.decoding = 'async';
  art.appendChild(img);

  if (featured) {
    const logoWrap = document.createElement('div');
    logoWrap.className = 'art-wpt-logo';
    const logo = document.createElement('img');
    logo.src = 'assets/wptglobal.svg';
    logo.alt = 'WPT Global';
    logoWrap.appendChild(logo);
    art.appendChild(logoWrap);
  }

  const title = document.createElement('h3');
  title.className = 'hand-card-title';
  title.textContent = hand.title;

  const caption = document.createElement('p');
  caption.className = 'hand-card-caption';
  caption.textContent = 'Embeds Replayer';

  a.append(art, title, caption);
  return a;
}

const featuredRow = document.getElementById('featuredRow');
const allGrid = document.getElementById('allGrid');
const loadMoreWrap = document.getElementById('loadMoreWrap');

const INITIAL_COUNT = 6;
let visibleCount = 0;

function renderAll(count) {
  for (let i = visibleCount; i < Math.min(count, ALL_HANDS.length); i++) {
    allGrid.appendChild(makeCard(ALL_HANDS[i], false));
  }
  visibleCount = Math.min(count, ALL_HANDS.length);
  loadMoreWrap.style.display = visibleCount >= ALL_HANDS.length ? 'none' : '';
}

FEATURED_HANDS.forEach(hand => featuredRow.appendChild(makeCard(hand, true)));
renderAll(INITIAL_COUNT);

document.getElementById('loadMore').addEventListener('click', () => renderAll(ALL_HANDS.length));

document.querySelectorAll('.hg-arrow').forEach(btn => {
  btn.addEventListener('click', () => {
    featuredRow.scrollBy({ left: 388 * Number(btn.dataset.dir), behavior: 'smooth' });
  });
});
