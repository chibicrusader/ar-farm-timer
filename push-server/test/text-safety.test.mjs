// Notification text safety: every title starts with "AR Farm Timer: " and
// links are removed from caller-supplied text, so a stolen subscription id
// can't show arbitrary scary titles or links.  npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { safeTitle, safeBody, stripLinks, buildPayload, parseAlerts } from '../src/index.js';

// Not exported from the Worker module: workerd rejects non-handler exports.
const TITLE_PREFIX = 'AR Farm Timer: ';
const MAX_TITLE_LEN = 120;

const env = { APP_URL: 'https://artimer.win/' };

test('titles get the prefix exactly once', () => {
  assert.equal(safeTitle('Rice is ready!'), 'AR Farm Timer: Rice is ready!');
  assert.equal(safeTitle('AR Farm Timer: Test alert'), 'AR Farm Timer: Test alert'); // the /test message
  assert.equal(safeTitle('AR Farm Timer: AR Farm Timer: x'), 'AR Farm Timer: x');
  assert.equal(safeTitle('AR Farm Timer:x'), 'AR Farm Timer: x');
  assert.equal(safeTitle('AR Farm Timer is great'), 'AR Farm Timer: AR Farm Timer is great');
  assert.equal(safeTitle(''), 'AR Farm Timer: Alert');
  assert.equal(safeTitle('https://evil.example'), 'AR Farm Timer: Alert');
  for (const t of ['a', 'AR Farm Timer: Test alert', 'x'.repeat(500), 'Hello world. '.repeat(20)]) {
    assert.ok(safeTitle(t).startsWith(TITLE_PREFIX), t);
    assert.equal(safeTitle(safeTitle(t)), safeTitle(t), 'idempotent');
  }
});

test('titles stay within 120 chars, prefix included, cut with an ellipsis', () => {
  const exact = 'y'.repeat(120 - TITLE_PREFIX.length);
  assert.equal(safeTitle(exact), TITLE_PREFIX + exact);
  const long = safeTitle('z'.repeat(200));
  assert.equal(long.length, MAX_TITLE_LEN);
  assert.ok(long.endsWith('\u2026'));
  // never half a surrogate pair at the cut
  const emoji = safeTitle('\u{1F33E}'.repeat(100));
  assert.ok(emoji.length <= 120);
  assert.doesNotMatch(emoji, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/);
});

test('links are stripped from titles and bodies; artimer.win is kept', () => {
  const cases = [
    ['Visit http://evil.example/fix now', 'Visit now'],
    ['HTTPS://EVIL.EXAMPLE/x?y=1 go', 'go'],
    ['ftp://files.example/a', ''],
    ['Call www.scam.co today', 'Call today'],
    ['see paypal-secure.com/login ok', 'see ok'],
    ['bit.ly/abc', ''],
    ['sub.domain.example.org:8080/path', ''],
    ['\u0430rtimer.win.evil.ru x', 'x'], // Cyrillic look-alike + suffix trick
    ['evil-artimer.win', ''],
    ['https://artimer.win@evil.com', ''],
    ['Open artimer.win or www.artimer.win/help', 'Open artimer.win or www.artimer.win/help'],
    ['Harvest 2\u00d7 Rice at Field 3.', 'Harvest 2\u00d7 Rice at Field 3.'],
    ['within 1.5 hrs or it is lost.', 'within 1.5 hrs or it is lost.'],
    ['e.g. Mr. Smith', 'e.g. Mr. Smith'],
    ['mail support@evil.example now', 'mail now'],
    ['line1\nline2\u202e\u200bend', 'line1 line2 end'],
  ];
  for (const [input, want] of cases) assert.equal(stripLinks(input), want, input);
  assert.equal(safeTitle('Visit http://evil.example now'), 'AR Farm Timer: Visit now');
  assert.equal(safeBody('Unlock at www.evil.example'), 'Unlock at');
  assert.ok(safeBody('w'.repeat(400)).length <= 300);
});

test('the app\'s own alert texts are unchanged apart from the prefix', () => {
  assert.equal(safeTitle('Golden Rice is ready!'), 'AR Farm Timer: Golden Rice is ready!');
  assert.equal(safeTitle('Golden Rice will wither soon!'), 'AR Farm Timer: Golden Rice will wither soon!');
  assert.equal(safeBody('Harvest 3\u00d7 Golden Rice at North plot.'), 'Harvest 3\u00d7 Golden Rice at North plot.');
  assert.equal(safeBody('Harvest Golden Rice within 30 min or it is lost.'), 'Harvest Golden Rice within 30 min or it is lost.');
});

test('parseAlerts (/schedule, /sync) and buildPayload (send time) both enforce it', () => {
  const now = Date.now();
  const [a] = parseAlerts([{ id: '1', fireAt: now + 60_000, title: 'Account locked! www.evil.example', body: 'Go to http://evil.example' }], now, env);
  assert.equal(a.title, 'AR Farm Timer: Account locked!');
  assert.equal(a.body, 'Go to');
  // a row stored before this change
  const n = JSON.parse(buildPayload({ id: 'old', title: 'Scary', body: 'see evil.example', url: null }, env)).notification;
  assert.equal(n.title, 'AR Farm Timer: Scary');
  assert.equal(n.body, 'see');
  // stored (already prefixed) rows are not prefixed again at send time
  assert.equal(JSON.parse(buildPayload(a, env)).notification.title, 'AR Farm Timer: Account locked!');
});
