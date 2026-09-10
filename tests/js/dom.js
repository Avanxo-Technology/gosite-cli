// A DOM stub small enough to read and big enough to run consent.js and
// analytics.js. It is built from what those two files actually touch, not from
// a guess at the DOM - the analytics rollout was bitten repeatedly by mocks
// that encoded the code's assumptions instead of the real contract.
function makeNode(tag) {
  const node = {
    tagName: (tag || '').toUpperCase(),
    children: [],
    attrs: {},
    textContent: '',
    checked: false,
    disabled: false,
    style: {},
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return this.attrs[k]; },
    appendChild(c) { this.children.push(c); c.parent = this; return c; },
    remove() {
      if (!this.parent) return;
      const i = this.parent.children.indexOf(this);
      if (i >= 0) this.parent.children.splice(i, 1);
      this.parent = null;
    },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    handlers: {},
    focus() { node.doc.activeElement = node; },
    click() { (this.handlers.click || []).forEach(fn => fn({ preventDefault() {}, target: node })); },
    closest() { return null; },
    // Depth-first over the subtree, matching only the selectors these two
    // files pass. A real matcher here would be more code than the thing it
    // tests.
    descendants() {
      return this.children.flatMap(c => [c, ...c.descendants()]);
    },
    querySelectorAll(sel) {
      const wants = sel.split(',').map(s => s.trim());
      return this.descendants().filter(n => wants.some(w => {
        if (w.startsWith('button')) return n.tagName === 'BUTTON';
        if (w.startsWith('a[href]')) return n.tagName === 'A' && n.attrs.href;
        if (w.startsWith('input')) return n.tagName === 'INPUT' && !n.disabled;
        return false;
      }));
    },
    querySelector(sel) {
      const m = sel.match(/\[data-category="([^"]+)"\]/);
      if (m) return this.descendants().find(n => n.attrs['data-category'] === m[1]) || null;
      return this.querySelectorAll(sel)[0] || null;
    },
  };
  node.handlers = {};
  return node;
}

function makeDom(opts) {
  opts = opts || {};
  const loaded = [];
  let cookies = opts.cookie ? [opts.cookie] : [];

  const head = makeNode('head');
  const body = makeNode('body');
  const doc = {
    body, head,
    activeElement: null,
    handlers: {},
    get cookie() { return cookies.join('; '); },
    set cookie(str) {
      const [pair, ...rest] = str.split(';').map(s => s.trim());
      const name = pair.split('=')[0];
      const expired = rest.some(a => /^max-age=0$/i.test(a) || /^expires=.*197/i.test(a));
      cookies = cookies.filter(c => c.split('=')[0] !== name);
      if (!expired && pair.split('=')[1] !== '') cookies.push(pair);
    },
    getElementById(id) {
      if (id === 'consent-config' && opts.consent !== undefined) {
        const n = makeNode('script');
        n.textContent = typeof opts.consent === 'string' ? opts.consent : JSON.stringify(opts.consent);
        return n;
      }
      if (id === 'analytics-config' && opts.integrations !== undefined) {
        const n = makeNode('script');
        n.textContent = JSON.stringify(opts.integrations);
        return n;
      }
      return null;
    },
    createElement(tag) { const n = makeNode(tag); n.doc = doc; return n; },
    addEventListener(type, fn) { (doc.handlers[type] = doc.handlers[type] || []).push(fn); },
    removeEventListener(type, fn) {
      doc.handlers[type] = (doc.handlers[type] || []).filter(f => f !== fn);
    },
    contains() { return true; },
  };

  /*
   * What each official bundle publishes when it loads.
   *
   * Two of them (google-analytics and its v3) really do publish an ESM interop
   * object rather than the factory, and analytics.js unwraps that - so the
   * stub reproduces both shapes. A stub that published a bare function
   * everywhere would agree with a bug rather than with the CDN.
   */
  const GLOBALS = {
    'google-tag-manager': ['analyticsGtagManager', 'bare'],
    'google-analytics-v3': ['analyticsGa3', 'esm'],
    'google-analytics': ['analyticsGa', 'esm'],
    mixpanel: ['analyticsMixpanel', 'bare'],
    segment: ['analyticsSegment', 'bare'],
    amplitude: ['analyticsAmplitude', 'bare'],
    hubspot: ['analyticsHubspot', 'bare'],
    fullstory: ['analyticsFullStory', 'bare'],
    customerio: ['analyticsCustomerio', 'bare'],
  };

  function publish(src) {
    for (const key of Object.keys(GLOBALS)) {
      if (!src.includes('@analytics/' + key + '@')) continue;

      const [name, shape] = GLOBALS[key];
      const factory = (config) => ({ name: key, config, initialize() {}, loaded: () => true });

      win[name] = shape === 'esm' ? { default: factory } : factory;
      return;
    }
  }

  // A script appended to head is a network request in a real browser, so this
  // is where "did anything reach a third party?" is actually observed.
  head.appendChild = function (c) {
    const src = c.src || c.attrs.src;

    if (c.tagName === 'SCRIPT' && src) {
      loaded.push(src);
      // The global appears when the bundle arrives, not before - so a mount
      // that runs too early fails here the way it would in a browser.
      setTimeout(() => publish(src), 0);
    }

    makeNode('x').appendChild.call(this, c);
    if (c.onload) setTimeout(c.onload, 0);
    return c;
  };

  const store = () => {
    const m = new Map();
    return {
      get length() { return m.size; },
      key(i) { return [...m.keys()][i]; },
      getItem(k) { return m.has(k) ? m.get(k) : null; },
      setItem(k, v) { m.set(k, String(v)); },
      removeItem(k) { m.delete(k); },
    };
  };

  const reloads = { count: 0 };

  /*
   * A stand-in for the analytics core bundle, which the layout loads before
   * analytics.js.
   *
   * It has to be here or analytics.js takes its "the library did not load"
   * exit before ever reaching the consent gate - and every "nothing was
   * fetched" assertion would then pass for the wrong reason. That is exactly
   * the class of mistake the six analytics fixes were: a stub that agreed with
   * the bug.
   *
   * The shape is the real one: the bundle publishes _analytics holding the
   * factory, not a bare function.
   */
  const mounts = [];
  const _analytics = {
    init(cfg) {
      mounts.push(cfg);
      const sent = [];
      return {
        plugins: {},
        sent,
        page(...a) { sent.push(['page', a]); },
        track(...a) { sent.push(['track', a]); },
        identify(...a) { sent.push(['identify', a]); },
      };
    },
  };
  const win = {
    document: doc,
    location: { protocol: 'https:', hostname: 'analytics-draft.test', reload() { reloads.count++; } },
    localStorage: store(),
    sessionStorage: store(),
    console,
    setTimeout,
    Promise,
    _analytics,
    loaded, reloads, mounts,
  };
  win.window = win;
  return win;
}

module.exports = { makeDom };
