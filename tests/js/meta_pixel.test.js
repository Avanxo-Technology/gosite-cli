/*
 * Does the Meta Pixel plugin send what it should, and only when it may?
 *
 * consent.js and analytics.js run as they ship, in the DOM stub. Every
 * assertion is about what reached fbq or the network - the same standard as
 * consent_gate.test.js.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { makeDom } = require('./dom.js');

const REPO = process.argv[2] || path.resolve(__dirname, '..', '..');
const CONSENT = fs.readFileSync(path.join(REPO, 'core/internal/app/assets/js/analytics/consent.js'), 'utf8');
const ANALYTICS = fs.readFileSync(path.join(REPO, 'core/internal/app/assets/js/analytics/analytics.js'), 'utf8');

const FBEVENTS = 'connect.facebook.net/en_US/fbevents.js';
const PIXEL_ID = '1234567890123456';

// The standard events in Meta's reference. analytics.js must send each one
// with fbq('track'); anything else goes to fbq('trackCustom').
const STANDARD = [
  'AddPaymentInfo', 'AddToCart', 'AddToWishlist', 'CompleteRegistration',
  'Contact', 'CustomizeProduct', 'Donate', 'FindLocation', 'InitiateCheckout',
  'Lead', 'Purchase', 'Schedule', 'Search', 'StartTrial', 'SubmitApplication',
  'Subscribe', 'ViewContent',
];

let failures = 0;
function check(name, ok, detail) {
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok || !detail ? '' : ' -> ' + detail));
  if (!ok) failures++;
}

// Bundles and timers run after the click that allowed them. Mounting is a
// chain of microtasks, so it is waited for by yielding to the microtask queue;
// fbevents.js arrives on a timer, so anything after it waits for flush().
const flush = () => new Promise(r => setTimeout(r, 10));
async function untilMounted(win) {
  for (let i = 0; i < 20 && win.mounts.length === 0; i++) await Promise.resolve();
}

const CONSENT_ON = { Enabled: true, CopyVersion: '1', Title: 'T', Body: 'B', AcceptLabel: 'A', RejectLabel: 'R', PrefsLabel: 'P', SaveLabel: 'S' };
const PIXEL = { Provider: 'meta-pixel', Config: { pixelId: PIXEL_ID } };

const cookieFor = (analytics, marketing) => 'gosite_consent=' + encodeURIComponent(JSON.stringify({
  schema: 1, copyVersion: '1', granted: { analytics, marketing },
}));

const PURCHASE = {
  event: 'Purchase',
  properties: { value: 40, currency: 'EUR', content_ids: ['var-1'], content_type: 'product', num_items: 1, order_id: 'ord-1' },
};

// consent.js first, then analytics.js, as the layout loads them.
function run(win) {
  const ctx = vm.createContext(win);
  vm.runInContext(CONSENT, ctx, { filename: 'consent.js' });
  vm.runInContext(ANALYTICS, ctx, { filename: 'analytics.js' });
  return win;
}

// A page as the browser sees it: the DOM the server rendered, then the scripts.
function page(opts, setup) {
  const win = makeDom(opts);
  if (setup) setup(win);
  return run(win);
}

function fireBanner(win, labelText) {
  const target = win.document.body.querySelectorAll('button').find(b => b.textContent === labelText);
  if (!target) throw new Error('no button labelled ' + labelText);
  target.click();
}

// Records a choice the way a visitor makes it: open the dialog, tick, save.
function choose(win, analytics, marketing) {
  win.consent.open();
  win.document.body.querySelector('[data-category="analytics"]').checked = analytics;
  win.document.body.querySelector('[data-category="marketing"]').checked = marketing;
  fireBanner(win, 'S');
}

// A <script type="application/json" data-analytics-event> block, as the server renders it.
function addEventBlock(win, data, raw) {
  const s = win.document.createElement('script');
  s.setAttribute('type', 'application/json');
  s.setAttribute('data-analytics-event', '');
  s.textContent = raw !== undefined ? raw : JSON.stringify(data);
  win.document.body.appendChild(s);
}

// An htmx HX-Trigger event. htmx adds `elt` to the detail; the stub does the same.
function htmxEvent(win, data) {
  win.document.dispatchEvent(new win.CustomEvent('analytics:event', { detail: Object.assign({ elt: {} }, data) }));
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const callsNamed = (win, name) => win.fbCalls.filter(c => c[1] === name);
const fbevents = win => win.loaded.filter(u => u.includes(FBEVENTS)).length;

(async () => {

// --- 1. nothing is requested before marketing consent ----------------------
{
  const fresh = page({ consent: CONSENT_ON, integrations: [PIXEL] });
  await untilMounted(fresh);
  await flush();
  check('a first visit requests no Meta script', fbevents(fresh) === 0, fresh.loaded.join(', '));
  check('a first visit defines no fbq', fresh.fbq === undefined);

  const analyticsOnly = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(true, false) });
  await untilMounted(analyticsOnly);
  await flush();
  check('analytics accepted, marketing refused: no Meta script', fbevents(analyticsOnly) === 0, analyticsOnly.loaded.join(', '));
  check('analytics accepted, marketing refused: no fbq', analyticsOnly.fbq === undefined);

  const off = page({ consent: { Enabled: false }, integrations: [PIXEL], cookie: cookieFor(true, true) });
  await untilMounted(off);
  await flush();
  check('consent disabled in the CMS: no Meta script', fbevents(off) === 0, off.loaded.join(', '));
}

// --- 2. marketing consent: init and PageView through fbevents.js -----------
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) });
  await untilMounted(win);
  await flush();
  check('marketing consent requests fbevents.js once', fbevents(win) === 1, win.loaded.join(', '));
  check('init, then PageView, reach the Pixel in that order',
    same(win.fbCalls, [['init', PIXEL_ID], ['track', 'PageView']]), JSON.stringify(win.fbCalls));
  check('the plugin raises no page error', win.pageErrors.length === 0, win.pageErrors.map(e => e.message).join('; '));
}

// --- 3. standard names go to track, others to trackCustom ------------------
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) });
  await untilMounted(win);
  await flush();

  STANDARD.forEach(name => win.analytics.track(name, { value: 1 }));
  win.analytics.track('newsletter_signup');
  await flush();

  check('all 17 standard events go to fbq track',
    STANDARD.every(name => same(callsNamed(win, name)[0], ['track', name, { value: 1 }])),
    STANDARD.filter(name => !same(callsNamed(win, name)[0], ['track', name, { value: 1 }])).join(', '));
  check('a custom name goes to fbq trackCustom with empty properties',
    same(callsNamed(win, 'newsletter_signup')[0], ['trackCustom', 'newsletter_signup', {}]),
    JSON.stringify(callsNamed(win, 'newsletter_signup')));
}

// --- 4. order_id is passed to Meta as eventID ------------------------------
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) });
  await untilMounted(win);
  await flush();

  win.analytics.track('Purchase', { value: 40, currency: 'EUR', order_id: 'ord-1' });
  await flush();

  const [call] = callsNamed(win, 'Purchase');
  check('the order id becomes the fourth argument as eventID',
    call && call.length === 4 && same(call[3], { eventID: 'ord-1' }), JSON.stringify(call));
  check('the properties reach Meta unchanged', call && same(call[2], { value: 40, currency: 'EUR', order_id: 'ord-1' }));
}

// --- 5. an event before fbevents.js has run waits in the queue -------------
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) });
  await untilMounted(win);
  // The plugin has initialised; fbevents.js is requested but its timer has not fired.
  win.analytics.track('Lead', { value: 10 });

  check('before fbevents.js runs, calls wait in the stub queue',
    win.fbCalls.length === 0 && win.fbq.queue.length === 3, 'fbCalls=' + win.fbCalls.length + ' queue=' + (win.fbq && win.fbq.queue.length));

  await flush();
  check('the queued call reaches the Pixel once it loads, in order',
    same(win.fbCalls.map(c => c[0] + ':' + c[1]), ['init:' + PIXEL_ID, 'track:PageView', 'track:Lead']),
    JSON.stringify(win.fbCalls.map(c => c[1])));
}

// --- 6. withdrawing marketing reloads, and the next load clears _fbp/_fbc --
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) }, w => {
    w.document.cookie = '_fbp=fb.1.z';
    w.document.cookie = '_fbc=fb.1.z';
  });
  await untilMounted(win);
  await flush();

  choose(win, false, false);
  check('withdrawing marketing reloads the page', win.reloads.count === 1, String(win.reloads.count));

  // The page the reload produces: the refusal is stored and the browser still
  // holds the Meta cookies. consent.js clears them at boot, before anything
  // can write them back.
  const jar = win.document.cookie.split('; ');
  const next = page({ consent: CONSENT_ON, integrations: [PIXEL] }, w => jar.forEach(pair => { w.document.cookie = pair; }));
  await untilMounted(next);
  await flush();

  check('the reloaded page keeps the refusal', next.document.cookie.includes('gosite_consent='), next.document.cookie);
  check('the reloaded page clears _fbp', !next.document.cookie.includes('_fbp='), next.document.cookie);
  check('the reloaded page clears _fbc', !next.document.cookie.includes('_fbc='), next.document.cookie);
  check('the reloaded page requests no Meta script', fbevents(next) === 0, next.loaded.join(', '));
}

// --- 7. page events: data blocks reach the Pixel only when consent came first
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) },
    w => addEventBlock(w, PURCHASE));
  await untilMounted(win);
  await flush();

  const [call] = callsNamed(win, 'Purchase');
  check('a data block is sent when consent was given before the page loaded',
    call && same(call[2], PURCHASE.properties), JSON.stringify(call));
  check('the data block order id is the eventID', call && same(call[3], { eventID: 'ord-1' }));
}
{
  // An undecided visitor sees the confirmation page, then accepts on it.
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL] }, w => addEventBlock(w, PURCHASE));
  await flush();
  choose(win, false, true);
  await untilMounted(win);
  await flush();

  check('the Pixel mounts after the later accept', win.mounts.length === 1 && fbevents(win) === 1, win.loaded.join(', '));
  check('a block rendered before the accept is not replayed', callsNamed(win, 'Purchase').length === 0,
    JSON.stringify(callsNamed(win, 'Purchase')));
}
{
  // A malformed block is skipped; the next one still goes out.
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) }, w => {
    addEventBlock(w, null, '{not json');
    addEventBlock(w, { event: 'AddToCart', properties: { value: 5, currency: 'EUR' } });
  });
  await untilMounted(win);
  await flush();

  check('a malformed block is skipped and the next block is sent', callsNamed(win, 'AddToCart').length === 1,
    JSON.stringify(callsNamed(win, 'AddToCart')));
  check('a malformed block raises no page error', win.pageErrors.length === 0);
}

// --- 8. htmx events ---------------------------------------------------------
{
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) });
  await untilMounted(win);
  await flush();

  htmxEvent(win, { event: 'AddToCart', properties: { value: 20, currency: 'EUR', content_ids: ['var-1'], num_items: 1 } });

  const [call] = callsNamed(win, 'AddToCart');
  check('an htmx event after consent reaches the Pixel', !!call, JSON.stringify(win.fbCalls));
  check('the htmx detail is not sent: no elt in the properties',
    call && same(call[2], { value: 20, currency: 'EUR', content_ids: ['var-1'], num_items: 1 }), JSON.stringify(call));
}
{
  // Raised before the answer: dropped, and not replayed after an accept.
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL] });
  htmxEvent(win, { event: 'AddToCart', properties: { value: 20, currency: 'EUR', content_ids: ['var-1'], num_items: 1 } });
  choose(win, false, true);
  await untilMounted(win);
  await flush();

  check('an htmx event raised before consent is not sent after an accept',
    callsNamed(win, 'AddToCart').length === 0, JSON.stringify(callsNamed(win, 'AddToCart')));
}

// --- 8b. track() from page code follows the same rule as page events --------
{
  // Consent stored before the load: a call made while the bundles download is kept.
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) });
  win.analytics.track('Lead', { value: 5 });
  await untilMounted(win);
  await flush();
  check('a track() made before the mount reaches the Pixel when consent came first',
    callsNamed(win, 'Lead').length === 1, JSON.stringify(win.fbCalls));
}
{
  // Undecided visitor: the call happens, then the visitor accepts.
  const win = page({ consent: CONSENT_ON, integrations: [PIXEL] });
  win.analytics.track('Lead', { value: 5 });
  choose(win, false, true);
  await untilMounted(win);
  await flush();
  check('a track() made before a later accept is not replayed',
    win.mounts.length === 1 && callsNamed(win, 'Lead').length === 0, JSON.stringify(win.fbCalls));
  win.analytics.track('Lead', { value: 6 });
  check('a track() after the accept is sent', callsNamed(win, 'Lead').length === 1, JSON.stringify(win.fbCalls));
}

// --- 9. Purchase once per order -----------------------------------------------
{
  // The confirmation page, then a reload of it in the same browser session.
  const first = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) },
    w => addEventBlock(w, PURCHASE));
  await untilMounted(first);
  await flush();
  htmxEvent(first, PURCHASE);

  const second = page({ consent: CONSENT_ON, integrations: [PIXEL], cookie: cookieFor(false, true) }, w => {
    w.sessionStorage = first.sessionStorage;
    addEventBlock(w, PURCHASE);
  });
  await untilMounted(second);
  await flush();

  const sent = callsNamed(first, 'Purchase').length + callsNamed(second, 'Purchase').length;
  check('the same order is sent once across an htmx repeat and a reload', sent === 1, 'sent ' + sent + ' times');
  check('the order id is recorded in sessionStorage',
    (JSON.parse(first.sessionStorage.getItem('gosite_purchases') || '[]')).indexOf('ord-1') !== -1,
    first.sessionStorage.getItem('gosite_purchases'));
}

console.log(failures ? `\n${failures} FAILED` : '\nall meta pixel checks passed');
process.exit(failures ? 1 : 0);
})();
