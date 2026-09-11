/*
 * Does the gate actually gate?
 *
 * These run consent.js and analytics.js as they ship, in the DOM stub, and
 * assert on what reached the network - not on a flag either file set.
 */
const fs = require('fs');
const vm = require('vm');
const { makeDom } = require('./dom.js');

/*
 * The browser half of consent, tested without a browser.
 *
 * These were the only files in the analytics feature with no automated tests,
 * and they are now the files a legal guarantee rests on: "nothing is fetched
 * before a decision" is not something to verify by reading. Every assertion
 * here is about what reached the network or what was stored - never about a
 * flag one of the two files set.
 *
 * The DOM stub in dom.js is built from the contracts these files actually
 * touch, including the two bundles that publish an ESM interop object rather
 * than a factory. That matters: the six fixes the analytics rollout needed all
 * had a passing test that agreed with the bug, because the mock encoded what
 * the code assumed instead of what the CDN ships.
 *
 * A browser is still required for the things a stub cannot judge - layout,
 * focus order, contrast, and whether a real provider accepts an event. See the
 * change's tasks.
 */

// Default to the repo root two levels up, so this runs as
// `node tests/js/consent_gate.test.js` with no argument.
const REPO = process.argv[2] || require('path').resolve(__dirname, '..', '..');
const CONSENT = fs.readFileSync(REPO + '/src/templates/static/js/analytics/consent.js', 'utf8');
const ANALYTICS = fs.readFileSync(REPO + '/src/templates/static/js/analytics/analytics.js', 'utf8');

let failures = 0;
function check(name, ok, detail) {
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok || !detail ? '' : ' -> ' + detail));
  if (!ok) failures++;
}

/*
 * Bundles load asynchronously, so a mount happens a microtask or two after the
 * click that allowed it. Anything asserting on a MOUNT has to wait; anything
 * asserting on a FETCH does not, because appending the script tag is
 * synchronous. Getting that backwards is how the first version of this file
 * reported "nothing mounted" as a pass.
 */
const flush = () => new Promise(r => setTimeout(r, 10));

const CONSENT_ON = { Enabled: true, CopyVersion: '1', Title: 'T', Body: 'B', AcceptLabel: 'A', RejectLabel: 'R', PrefsLabel: 'P', SaveLabel: 'S' };
const GTM = { Provider: 'gtm', Config: { containerId: 'GTM-ABC1234' } };          // marketing by default
const PH = { Provider: 'posthog', Config: { key: 'phc_x', host: 'https://h' } };  // analytics

function boot(opts) {
  const win = makeDom(opts);
  const ctx = vm.createContext(win);
  vm.runInContext(CONSENT, ctx, { filename: 'consent.js' });
  vm.runInContext(ANALYTICS, ctx, { filename: 'analytics.js' });
  return win;
}

function fireBanner(win, labelText) {
  const buttons = win.document.body.querySelectorAll('button');
  const target = buttons.find(b => b.textContent === labelText);
  if (!target) throw new Error('no button labelled ' + labelText + ' (have: ' + buttons.map(b => b.textContent).join(', ') + ')');
  target.click();
}

// --- 1. a first visit fetches nothing --------------------------------------
{
  const win = boot({ consent: CONSENT_ON, integrations: [GTM, PH] });
  check('a first visit fetches no provider bundle', win.loaded.length === 0, win.loaded.join(', '));
  check('a first visit stores no consent cookie', win.document.cookie === '', win.document.cookie);
  check('the banner is shown', win.document.body.children.length === 1);
  check('nothing is granted before a decision',
    win.consent.get().decided === false &&
    win.consent.get().granted.analytics === false &&
    win.consent.get().granted.marketing === false);
}

// --- 2. accepting everything loads everything ------------------------------
{
  const win = boot({ consent: CONSENT_ON, integrations: [GTM, PH] });
  fireBanner(win, 'A');
  check('accept all grants both categories',
    win.consent.get().granted.analytics === true && win.consent.get().granted.marketing === true);
  check('accept all stores a decision', /gosite_consent=/.test(win.document.cookie), win.document.cookie);
  check('accept all fetches the GTM bundle',
    win.loaded.some(u => u.includes('google-tag-manager')), win.loaded.join(', '));
  check('the banner is dismissed', win.document.body.children.length === 0);
}

// --- 3. rejecting everything loads nothing ---------------------------------
{
  const win = boot({ consent: CONSENT_ON, integrations: [GTM, PH] });
  fireBanner(win, 'R');
  check('reject all fetches nothing', win.loaded.length === 0, win.loaded.join(', '));
  check('reject all is still a stored decision', win.consent.get().decided === true);
}

// --- 4. granting one category only -----------------------------------------
{
  // A visitor who allows analytics but not marketing: PostHog may load, GTM
  // may not. This is the scenario the whole category mapping exists for.
  const win = boot({ consent: CONSENT_ON, integrations: [GTM, PH] });
  fireBanner(win, 'P');                       // open preferences
  const box = win.document.body.querySelector('[data-category="analytics"]');
  box.checked = true;
  win.document.body.querySelector('[data-category="marketing"]').checked = false;
  fireBanner(win, 'S');                       // save
  check('analytics granted: no marketing bundle is fetched',
    !win.loaded.some(u => u.includes('google-tag-manager')), win.loaded.join(', '));
  check('analytics granted: the analytics provider is mounted',
    win.consent.get().granted.analytics === true && win.consent.get().granted.marketing === false);
}

// --- 5. a returning visitor ------------------------------------------------
{
  const stored = JSON.stringify({ schema: 1, copyVersion: '1', decidedAt: 'x', granted: { analytics: true, marketing: true } });
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent(stored) });
  check('a returning visitor sees no banner', win.document.body.children.length === 0);
  check('a returning visitor is tracked immediately',
    win.loaded.some(u => u.includes('google-tag-manager')), win.loaded.join(', '));
}

// --- 6. a cookie that cannot be trusted ------------------------------------
{
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent('{"granted":') });
  check('a malformed cookie is treated as no decision', win.consent.get().decided === false);
  check('a malformed cookie fetches nothing', win.loaded.length === 0, win.loaded.join(', '));
}
{
  const stale = JSON.stringify({ schema: 99, granted: { analytics: true, marketing: true } });
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent(stale) });
  check('a decision from another schema is asked again', win.consent.get().decided === false);
  check('a decision from another schema fetches nothing', win.loaded.length === 0, win.loaded.join(', '));
}
{
  // Hand-edited to grant a category without the rest of a valid decision.
  const forged = JSON.stringify({ schema: 1, granted: 'everything' });
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent(forged) });
  check('a forged cookie grants nothing', win.consent.get().granted.marketing === false);
}

// --- 7. consent not configured, and consent.js missing ---------------------
{
  const win = boot({ consent: undefined, integrations: [GTM, PH] });
  check('no consent block: nothing is fetched', win.loaded.length === 0, win.loaded.join(', '));
  check('no consent block: no banner', win.document.body.children.length === 0);
  check('no consent block: the API still answers safely',
    win.consent.get().decided === false && win.consent.get().granted.analytics === false);
}
{
  const win = boot({ consent: { Enabled: false }, integrations: [GTM, PH] });
  check('consent disabled: nothing is fetched', win.loaded.length === 0, win.loaded.join(', '));
}
{
  // consent.js failed to load and analytics.js is alone on the page.
  const win = makeDom({ integrations: [GTM, PH] });
  const ctx = vm.createContext(win);
  vm.runInContext(ANALYTICS, ctx, { filename: 'analytics.js' });
  check('consent.js missing: analytics refuses to load anything', win.loaded.length === 0, win.loaded.join(', '));
}

// --- 8. withdrawal ---------------------------------------------------------
{
  const stored = JSON.stringify({ schema: 1, copyVersion: '1', granted: { analytics: true, marketing: true } });
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent(stored) });
  win.consent.open();
  win.document.body.querySelector('[data-category="marketing"]').checked = false;
  win.document.body.querySelector('[data-category="analytics"]').checked = false;
  fireBanner(win, 'S');
  check('withdrawing reloads the page', win.reloads.count === 1, String(win.reloads.count));
  check('withdrawing stores the refusal', win.consent.get().granted.marketing === false);
}

// --- 8b. the cleanup happens on the NEXT load, not at withdrawal -----------
{
  /*
   * This is the shape a real browser forced.
   *
   * Clearing at the moment of withdrawal does not hold: the provider is still
   * running until the reload lands, and GA4 rewrote its session cookie in that
   * gap - a withdrawal left `_ga_<id>` behind on analytics-draft. So the
   * cleanup moved to boot, where nothing can write it back, and these two
   * checks are what pin it there.
   */
  const refused = JSON.stringify({ schema: 1, copyVersion: '1', granted: { analytics: false, marketing: false } });
  const win = makeDom({
    consent: CONSENT_ON,
    integrations: [GTM],
    cookie: 'gosite_consent=' + encodeURIComponent(refused),
  });
  win.document.cookie = '_ga=GA1.1.x';
  win.document.cookie = '_ga_ABC=GS2.1.y';
  win.document.cookie = '_fbp=fb.1.z';
  win.localStorage.setItem('ph_phc_x_posthog', 'kept');
  win.localStorage.setItem('keep_me', 'mine');

  const ctx = require('vm').createContext(win);
  require('vm').runInContext(CONSENT, ctx, { filename: 'consent.js' });

  check('a load with analytics refused clears the analytics cookies',
    !win.document.cookie.includes('_ga='), win.document.cookie);
  check('a load with analytics refused clears the analytics storage keys',
    win.localStorage.getItem('ph_phc_x_posthog') === null);
  check('a load with marketing refused clears the marketing cookies',
    !win.document.cookie.includes('_fbp='), win.document.cookie);
  check("the site's own storage is left alone",
    win.localStorage.getItem('keep_me') === 'mine');
}

// --- 8c. a granted category keeps its storage ------------------------------
{
  // The reason the cleanup is per category rather than one list: clearing
  // everything would delete the cookies of a provider the visitor just allowed.
  const mixed = JSON.stringify({ schema: 1, copyVersion: '1', granted: { analytics: true, marketing: false } });
  const win = makeDom({
    consent: CONSENT_ON,
    integrations: [GTM],
    cookie: 'gosite_consent=' + encodeURIComponent(mixed),
  });
  win.document.cookie = '_ga=GA1.1.x';
  win.document.cookie = '_fbp=fb.1.z';

  const ctx = require('vm').createContext(win);
  require('vm').runInContext(CONSENT, ctx, { filename: 'consent.js' });

  check('an allowed category keeps its cookies', win.document.cookie.includes('_ga='), win.document.cookie);
  check('a refused category still loses its cookies', !win.document.cookie.includes('_fbp='), win.document.cookie);
}

// --- 8d. reset() puts the visitor back to never having been asked ----------
{
  const stored = JSON.stringify({ schema: 1, copyVersion: '1', granted: { analytics: true, marketing: true } });
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent(stored) });
  win.document.cookie = '_ga=GA1.1.x';
  win.consent.reset();
  check('reset clears the decision', win.document.cookie.includes('gosite_consent') === false, win.document.cookie);
  check('reset clears every vendor cookie', !win.document.cookie.includes('_ga='), win.document.cookie);
  check('reset reloads', win.reloads.count === 1, String(win.reloads.count));
}

// --- 9. events raised before a decision ------------------------------------
{
  const win = boot({ consent: CONSENT_ON, integrations: [GTM] });
  let threw = null;
  try { win.analytics.track('early', { a: 1 }); } catch (e) { threw = e; }
  check('a track() before consent does not throw', threw === null, threw && threw.message);
  check('a track() before consent reaches no provider', win.loaded.length === 0, win.loaded.join(', '));
}

// --- 10. the category override ---------------------------------------------
{
  // GTM defaults to marketing; the CMS lowered this container to analytics.
  const win = boot({ consent: CONSENT_ON, integrations: [Object.assign({}, GTM, { Category: 'analytics' })] });
  win.consent.open();
  win.document.body.querySelector('[data-category="analytics"]').checked = true;
  win.document.body.querySelector('[data-category="marketing"]').checked = false;
  fireBanner(win, 'S');
  check('a CMS override lowers GTM into analytics',
    win.loaded.some(u => u.includes('google-tag-manager')), win.loaded.join(', '));
}
{
  // An unrecognised category must be harder to satisfy, not easier.
  const win = boot({ consent: CONSENT_ON, integrations: [Object.assign({}, PH, { Category: 'typo' })] });
  win.consent.open();
  win.document.body.querySelector('[data-category="analytics"]').checked = true;
  win.document.body.querySelector('[data-category="marketing"]').checked = false;
  fireBanner(win, 'S');
  check('an unrecognised category falls back to the provider default, not to allowed',
    win.consent.get().granted.analytics === true);
}

// --- 11. reopening after a decision ---------------------------------------
{
  const stored = JSON.stringify({ schema: 1, copyVersion: '1', granted: { analytics: false, marketing: false } });
  const win = boot({ consent: CONSENT_ON, integrations: [GTM], cookie: 'gosite_consent=' + encodeURIComponent(stored) });
  win.consent.open();
  check('a visitor who refused can reopen the preferences', win.document.body.children.length === 1);
  const boxes = win.document.body.querySelectorAll('input');
  check('the reopened dialog offers the two optional categories', boxes.length === 2, String(boxes.length));
}

(async () => {
// --- 11b. the banner does not trap the keyboard; the dialog does -----------
{
  /*
   * The banner is announced aria-modal="false", so a keyboard user must still
   * be able to tab out to the page. An earlier version trapped focus there and
   * contradicted its own ARIA, locking such a visitor out of the site until
   * they answered.
   */
  const win = boot({ consent: CONSENT_ON, integrations: [GTM] });
  const bannerModal = win.document.body.children[0].attrs['aria-modal'];
  check('the first banner is announced as non-modal', bannerModal === 'false', bannerModal);

  fireBanner(win, 'P');
  const dialogModal = win.document.body.children[0].attrs['aria-modal'];
  check('the preferences dialog is announced as modal', dialogModal === 'true', dialogModal);
}

// --- 12. granting a second category later ---------------------------------
{
  /*
   * A visitor allows analytics, browses, then comes back and allows marketing
   * too. The second grant must mount the marketing provider WITHOUT a reload,
   * and must not mount the analytics one twice.
   *
   * analytics@0.8.19 fixes its plugin list at construction, so this is the
   * scenario that forced one instance per grant.
   */
  const win = boot({ consent: CONSENT_ON, integrations: [GTM, PH] });
  win.consent.open();
  win.document.body.querySelector('[data-category="analytics"]').checked = true;
  win.document.body.querySelector('[data-category="marketing"]').checked = false;
  fireBanner(win, 'S');

  await flush();

  const afterFirst = win.mounts.length;
  check('the first grant mounts the allowed provider', afterFirst === 1, String(afterFirst));
  const reloadsAfterFirst = win.reloads.count;

  win.consent.open();
  win.document.body.querySelector('[data-category="analytics"]').checked = true;
  win.document.body.querySelector('[data-category="marketing"]').checked = true;
  fireBanner(win, 'S');

  await flush();

  check('a later grant does not reload the page', win.reloads.count === reloadsAfterFirst, String(win.reloads.count));
  check('a later grant mounts the newly allowed provider', win.mounts.length === afterFirst + 1,
    afterFirst + ' -> ' + win.mounts.length);
  check('a later grant fetches the marketing bundle',
    win.loaded.some(u => u.includes('google-tag-manager')), win.loaded.join(', '));

  const plugins = win.mounts.flatMap(m => m.plugins.map(p => p.name));
  check('no provider is mounted twice', new Set(plugins).size === plugins.length, plugins.join(', '));
}

// --- 13. one object for the page, however many grants ---------------------
{
  const win = boot({ consent: CONSENT_ON, integrations: [GTM, PH] });
  fireBanner(win, 'A');
  await flush();
  let threw = null;
  try { win.analytics.track('after', { b: 2 }); win.analytics.page(); } catch (e) { threw = e; }
  check('the page keeps one tracking object after consent', threw === null, threw && threw.message);
}

console.log(failures ? `\n${failures} FAILED` : '\nall gate checks passed');
process.exit(failures ? 1 : 0);
})();
