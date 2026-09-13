/*
 * Cookie consent: the gate everything else waits behind.
 *
 * It owns four things and nothing else:
 *
 *   1. the cookie holding what this visitor decided,
 *   2. the banner and the preferences dialog,
 *   3. the public API on window.consent,
 *   4. withdrawal.
 *
 * It knows nothing about analytics. analytics.js asks it what was granted;
 * anything else that needs permission - an embedded map, a video player - can
 * ask the same way. That separation is the point: the gate outlives the one
 * consumer it was written for.
 *
 * Loaded BEFORE the analytics core and before analytics.js, and it reads the
 * cookie synchronously, so a returning visitor's decision is known before
 * anything else runs and before the banner could paint.
 *
 * Like analytics.js, its configuration arrives as JSON in the page and never
 * as generated JavaScript. Nothing an editor typed is executed, and no inline
 * script is needed - which is what keeps a CSP possible.
 */
(function () {
  'use strict';

  /*
   * The three categories, and the two a visitor can actually decide.
   *
   * `necessary` is listed because the dialog shows it as always on. Nothing is
   * ever gated on it: a tool that needs consent is by definition not necessary
   * for the page to work, and a category nobody can refuse would be a way to
   * load tracking without permission.
   */
  var CATEGORIES = ['necessary', 'analytics', 'marketing'];
  var OPTIONAL = ['analytics', 'marketing'];

  var COOKIE = 'gosite_consent';

  /*
   * How long a decision stands before the visitor is asked again.
   *
   * Six months, which is the shorter end of what supervisory authorities have
   * called reasonable. A year is common and defensible; longer starts to look
   * like avoiding the question.
   */
  var COOKIE_DAYS = 182;

  /*
   * The schema version of the CATEGORIES list above.
   *
   * Bumping it invalidates every stored decision and asks again, so it must
   * only move when what is being consented TO changes - a category added,
   * removed or redefined. Copy changes must never bump it: re-prompting every
   * visitor over a typo trains people to click whatever dismisses the banner.
   */
  var SCHEMA = 1;

  // ------------------------------------------------------------------ storage

  /*
   * Cookie rather than localStorage.
   *
   * It survives subdomains and is readable by the server if a future need ever
   * arises - a server-side record of consent is the obvious one. localStorage
   * is neither, and would have to be migrated the day that is wanted.
   *
   * Not HttpOnly, necessarily: this script has to read it.
   */
  function writeCookie(value) {
    var expires = new Date(Date.now() + COOKIE_DAYS * 864e5).toUTCString();
    var secure = location.protocol === 'https:' ? '; Secure' : '';

    document.cookie = COOKIE + '=' + encodeURIComponent(value) +
      '; Path=/; Expires=' + expires + '; SameSite=Lax' + secure;
  }

  function readCookie() {
    var match = ('; ' + document.cookie).split('; ' + COOKIE + '=');

    if (match.length < 2) return '';

    return decodeURIComponent(match.pop().split(';').shift() || '');
  }

  function clearCookie() {
    document.cookie = COOKIE + '=; Path=/; Max-Age=0; SameSite=Lax';
  }

  /*
   * The stored decision, or null when there is none.
   *
   * A malformed, hand-edited or outdated value is null, never a partial
   * decision. Reading half a decision would mean granting something the
   * visitor may never have agreed to, so anything not exactly right is treated
   * as "has not decided yet" and the banner comes back.
   */
  function load() {
    var raw = readCookie();

    if (!raw) return null;

    var stored;

    try {
      stored = JSON.parse(raw);
    } catch (e) {
      return null;
    }

    if (!stored || typeof stored !== 'object') return null;
    if (stored.schema !== SCHEMA) return null;
    if (!stored.granted || typeof stored.granted !== 'object') return null;

    var granted = { necessary: true };

    for (var i = 0; i < OPTIONAL.length; i++) {
      granted[OPTIONAL[i]] = stored.granted[OPTIONAL[i]] === true;
    }

    return {
      granted: granted,
      decidedAt: stored.decidedAt || '',
      copyVersion: stored.copyVersion || '',
    };
  }

  /*
   * Stores a decision.
   *
   * copyVersion is recorded but never compared. It is the one piece of a
   * server-side record of consent that is cheap to ship now and impossible to
   * reconstruct later: without it, a decision made against wording an editor
   * has since changed cannot be tied to what the visitor actually read.
   */
  function save(granted) {
    var decision = {
      schema: SCHEMA,
      copyVersion: String(settings.CopyVersion || ''),
      decidedAt: new Date().toISOString(),
      granted: {},
    };

    for (var i = 0; i < OPTIONAL.length; i++) {
      decision.granted[OPTIONAL[i]] = granted[OPTIONAL[i]] === true;
    }

    try {
      writeCookie(JSON.stringify(decision));
    } catch (e) {
      /*
       * Cookies blocked. Nothing is stored, so nothing is granted, and the
       * banner will be back on the next page. That is the correct outcome and
       * not worth interrupting the visitor over: a page must never break
       * because it could not remember a preference.
       */
      console.warn('[consent] the decision could not be stored; nothing will be tracked', e);
    }

    return load();
  }

  // --------------------------------------------------------------- the config

  function readSettings() {
    var el = document.getElementById('consent-config');

    if (!el) return null;

    try {
      var parsed = JSON.parse(el.textContent);
      return parsed && typeof parsed === 'object' ? parsed : null;
    } catch (e) {
      console.warn('[consent] the configuration is not valid JSON; asking for no consent', e);
      return null;
    }
  }

  var settings = readSettings();

  // ------------------------------------------------------------- the listeners

  var listeners = [];
  var decision = load();

  function notify() {
    var snapshot = current();

    for (var i = 0; i < listeners.length; i++) {
      try {
        listeners[i](snapshot);
      } catch (e) {
        // One bad subscriber must not stop the others, and must never leave
        // the page in a state where consent was given and nothing acted on it.
        console.warn('[consent] a subscriber threw', e);
      }
    }
  }

  /*
   * What is granted right now.
   *
   * With no decision, everything optional is false - not unknown. A consumer
   * asking "may I load?" gets "no" until somebody says yes, which is the only
   * answer that is safe to act on.
   */
  function current() {
    var granted = { necessary: true };

    for (var i = 0; i < OPTIONAL.length; i++) {
      granted[OPTIONAL[i]] = !!(decision && decision.granted[OPTIONAL[i]]);
    }

    return {
      decided: !!decision,
      granted: granted,
      categories: CATEGORIES.slice(),
      copyVersion: decision ? decision.copyVersion : '',
      decidedAt: decision ? decision.decidedAt : '',
    };
  }

  function apply(granted) {
    var before = current().granted;

    decision = save(granted);

    var after = current().granted;

    /*
     * A withdrawal cannot be honoured in place.
     *
     * By the time a category is withdrawn its providers have already run their
     * own initialisation - PostHog has a live instance with its own
     * persistence, and analytics@0.8.19 has no clean unmount. Calling a
     * disable() and reporting success would be claiming something stopped when
     * it can still send.
     *
     * So the page reloads. What comes back is a page that never loaded the
     * tracker, which is the only honest version of "it stopped". The cost is a
     * visible reload on a rare action.
     */
    var withdrew = false;

    for (var i = 0; i < OPTIONAL.length; i++) {
      if (before[OPTIONAL[i]] && !after[OPTIONAL[i]]) withdrew = true;
    }

    hide();

    if (withdrew) {
      /*
       * No cleanup here on purpose. The provider is still live and would
       * rewrite what we deleted - which is exactly what GA4 did. forgetRefused()
       * runs on the next load instead, when nothing can write it back.
       */
      location.reload();
      return;
    }

    notify();
  }

  /*
   * Which vendor's storage belongs to which category.
   *
   * Per category, not one list, because a visitor can grant analytics and
   * refuse marketing - and clearing "all tracking storage" would then delete
   * the cookies of a provider they just allowed.
   *
   * Best effort, and said so plainly: anything set for a different host or
   * marked HttpOnly is beyond a script's reach. That is one more reason the
   * gate blocks providers up front rather than cleaning up after them.
   */
  var VENDOR_PREFIXES = {
    analytics: ['_ga', '_gid', '_hj', 'ph_', 'mp_', 'ajs_', 'amplitude', 'FS_'],
    marketing: ['_gcl', '_fbp', '_fbc', '__hs', 'intercom', '_uetsid', '_uetvid'],
  };

  /*
   * Clears the storage of the categories this visitor refused.
   *
   * Called on every load, not only on withdrawal, and that is the fix for a
   * real bug rather than belt and braces. Clearing at the moment of withdrawal
   * does not hold: the provider is still running until the page reloads, and
   * GA4 rewrote its session cookie in that gap - so a withdrawal left a cookie
   * behind, which was found by looking at the browser rather than at this code.
   *
   * Running it at boot means the provider that could rewrite the value has not
   * loaded yet, and never will. It is idempotent, so it also cleans up a
   * visitor who refused on some other page.
   */
  function forgetRefused() {
    var granted = current().granted;
    var prefixes = [];

    for (var i = 0; i < OPTIONAL.length; i++) {
      if (!granted[OPTIONAL[i]]) {
        prefixes = prefixes.concat(VENDOR_PREFIXES[OPTIONAL[i]] || []);
      }
    }

    if (!prefixes.length) return;

    forgetPrefixes(prefixes);
  }

  function forgetPrefixes(prefixes) {

    function matches(name) {
      for (var i = 0; i < prefixes.length; i++) {
        if (name.indexOf(prefixes[i]) === 0) return true;
      }
      return false;
    }

    var cookies = document.cookie ? document.cookie.split('; ') : [];

    for (var i = 0; i < cookies.length; i++) {
      var name = cookies[i].split('=')[0];

      if (!matches(name)) continue;

      /*
       * Three attempts, because a script cannot read back the Domain a cookie
       * was set with and deleting requires an exact match. The host form is
       * the one that actually worked for GA4's pair; the others cost nothing.
       */
      document.cookie = name + '=; Path=/; Max-Age=0';
      document.cookie = name + '=; Path=/; Max-Age=0; Domain=' + location.hostname;
      document.cookie = name + '=; Path=/; Max-Age=0; Domain=.' + location.hostname.split('.').slice(-2).join('.');
    }

    [localStorage, sessionStorage].forEach(function (store) {
      try {
        var doomed = [];

        for (var i = 0; i < store.length; i++) {
          var key = store.key(i);
          if (key && matches(key)) doomed.push(key);
        }

        doomed.forEach(function (key) { store.removeItem(key); });
      } catch (e) {
        // Storage can throw outright in a private window or with site data
        // blocked. There is nothing to clean up in that case anyway.
      }
    });
  }

  // Everything, for reset() - which puts the visitor back to never having been
  // asked, so no category is granted and none of it should survive.
  function forgetEverything() {
    forgetPrefixes(VENDOR_PREFIXES.analytics.concat(VENDOR_PREFIXES.marketing));
  }

  // ---------------------------------------------------------------------- UI

  var root = null;
  var lastFocused = null;

  function el(tag, attrs, text) {
    var node = document.createElement(tag);

    for (var key in attrs) {
      if (Object.prototype.hasOwnProperty.call(attrs, key)) {
        node.setAttribute(key, attrs[key]);
      }
    }

    /*
     * textContent, never innerHTML.
     *
     * Every string here comes from the CMS. html/template already escaped it
     * into the JSON block, and this is the independent second defence: even if
     * that block were wrong, nothing an editor typed can become markup.
     */
    if (text) node.textContent = text;

    return node;
  }

  function label(key, fallback) {
    var value = settings && settings[key];
    return (typeof value === 'string' && value.trim()) ? value : fallback;
  }

  function build(showPrefs) {
    var granted = current().granted;

    /*
     * A dialog, announced as one.
     *
     * role=dialog with aria-modal and a label, so a screen reader says what
     * this is instead of reading a stray region at the end of the document.
     */
    root = el('div', {
      'class': 'consent',
      'role': 'dialog',
      'aria-modal': showPrefs ? 'true' : 'false',
      'aria-labelledby': 'consent-title',
      'aria-describedby': 'consent-body',
    });

    var panel = el('div', { 'class': 'consent__panel' });

    panel.appendChild(el('h2', { 'class': 'consent__title', 'id': 'consent-title' }, label('Title', 'We use cookies')));
    panel.appendChild(el('p', { 'class': 'consent__body', 'id': 'consent-body' }, label('Body', '')));

    if (settings.PolicyURL) {
      var link = el('a', {
        'class': 'consent__policy',
        'href': settings.PolicyURL,
        'rel': 'noopener',
      }, label('PolicyLabel', 'Privacy policy'));

      panel.appendChild(link);
    }

    var choices = null;

    if (showPrefs) {
      choices = el('div', { 'class': 'consent__categories' });

      choices.appendChild(row('necessary', true, true));
      choices.appendChild(row('analytics', granted.analytics, false));
      choices.appendChild(row('marketing', granted.marketing, false));

      panel.appendChild(choices);
    }

    var actions = el('div', { 'class': 'consent__actions' });

    if (showPrefs) {
      actions.appendChild(button(label('SaveLabel', 'Save choices'), 'consent__button--primary', function () {
        apply({
          analytics: choices.querySelector('[data-category="analytics"]').checked,
          marketing: choices.querySelector('[data-category="marketing"]').checked,
        });
      }));
    } else {
      actions.appendChild(button(label('PrefsLabel', 'Preferences'), 'consent__button--quiet', function () {
        rebuild(true);
      }));
    }

    /*
     * Reject and accept are the same size, the same weight and next to each
     * other. A refusal that is harder to find than an acceptance is not a free
     * choice, and several authorities have said so explicitly.
     */
    actions.appendChild(button(label('RejectLabel', 'Reject all'), 'consent__button--secondary', function () {
      apply({ analytics: false, marketing: false });
    }));

    actions.appendChild(button(label('AcceptLabel', 'Accept all'), 'consent__button--primary', function () {
      apply({ analytics: true, marketing: true });
    }));

    panel.appendChild(actions);
    root.appendChild(panel);

    document.body.appendChild(root);
  }

  function button(text, variant, onClick) {
    var node = el('button', { 'type': 'button', 'class': 'consent__button ' + variant }, text);
    node.addEventListener('click', onClick);
    return node;
  }

  function row(category, checked, locked) {
    var id = 'consent-' + category;
    var wrap = el('div', { 'class': 'consent__category' });

    var input = el('input', { 'type': 'checkbox', 'id': id, 'data-category': category });

    input.checked = checked;

    if (locked) {
      // Necessary is shown, and shown as not a choice. Hiding it would be
      // simpler and less honest: the visitor should see the full list of what
      // runs, including the part they cannot turn off.
      input.checked = true;
      input.disabled = true;
    }

    var text = el('div', { 'class': 'consent__category-text' });
    var name = el('label', { 'class': 'consent__category-name', 'for': id },
      label(capitalise(category) + 'Label', capitalise(category)));

    text.appendChild(name);
    text.appendChild(el('p', { 'class': 'consent__category-info' },
      label(capitalise(category) + 'Description', '')));

    wrap.appendChild(input);
    wrap.appendChild(text);

    return wrap;
  }

  function capitalise(s) {
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  var modal = false;

  function rebuild(showPrefs) {
    if (root) root.remove();
    modal = !!showPrefs;
    build(showPrefs);
    takeFocus();
  }

  function hide() {
    if (!root) return;

    root.remove();
    root = null;
    document.removeEventListener('keydown', onKeydown, true);

    // Focus goes back where the visitor left it, so reopening the preferences
    // from a footer link does not dump them at the top of the document.
    if (lastFocused && document.contains(lastFocused)) {
      try { lastFocused.focus(); } catch (e) { /* the element may be gone */ }
    }
  }

  function focusable() {
    return root ? root.querySelectorAll('button, a[href], input:not([disabled])') : [];
  }

  /*
   * Moves focus into the banner, and traps it only in the preferences dialog.
   *
   * The distinction is not pedantry. The first banner is announced with
   * aria-modal="false" - it is a notice with buttons, and a keyboard user must
   * still be able to reach the page. An earlier version trapped focus there
   * too, which contradicted its own ARIA and locked such a visitor out of the
   * site until they answered. Found by driving it from the keyboard, not by
   * reading it.
   *
   * The preferences dialog is aria-modal="true" and does trap, which is what a
   * modal dialog is required to do.
   */
  function takeFocus() {
    var targets = focusable();

    if (targets.length) {
      try { targets[0].focus(); } catch (e) { /* not focusable yet */ }
    }

    document.addEventListener('keydown', onKeydown, true);
  }

  function onKeydown(e) {
    if (!root) return;

    /*
     * Escape closes without storing anything.
     *
     * Deliberately not a refusal. Dismissing a banner is not a decision, and
     * recording it as one would be recording consent the visitor never gave -
     * so the banner comes back on the next page, which is the honest cost of
     * not answering.
     */
    if (e.key === 'Escape') {
      e.preventDefault();
      hide();
      return;
    }

    // Only the modal dialog traps. See takeFocus().
    if (e.key !== 'Tab' || !modal) return;

    var targets = focusable();

    if (!targets.length) return;

    var first = targets[0];
    var last = targets[targets.length - 1];

    // Focus stays inside the dialog. Without this, tabbing walks off into a
    // page the visitor has not yet agreed to interact with, behind an overlay.
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  // ------------------------------------------------------------- the public API

  window.consent = {
    get: current,

    /*
     * Called on every decision, and immediately with the current one if the
     * visitor has already decided.
     *
     * The immediate call is what makes a subscriber simple to write: it asks
     * once and reacts, rather than having to check the state and subscribe and
     * get the ordering right between the two.
     */
    onChange: function (fn) {
      if (typeof fn !== 'function') return;

      listeners.push(fn);

      if (decision) {
        try {
          fn(current());
        } catch (e) {
          console.warn('[consent] a subscriber threw', e);
        }
      }
    },

    open: function () {
      lastFocused = document.activeElement;
      whenReady(function () { rebuild(true); });
    },

    /*
     * Forgets the decision entirely and asks again.
     *
     * This is not "reject": it removes the record, so the visitor is in the
     * same position as somebody who has never been here. Used by the reopen
     * control and useful for testing the banner without clearing site data by
     * hand.
     */
    reset: function () {
      clearCookie();
      decision = null;
      forgetEverything();
      location.reload();
    },
  };

  // --------------------------------------------------------------- bootstrap

  function whenReady(fn) {
    if (document.body) {
      fn();
      return;
    }
    document.addEventListener('DOMContentLoaded', fn, { once: true });
  }

  /*
   * The documented way to reopen the choice, from anywhere on the page.
   *
   * Registered before any of the early returns below, because the visitor who
   * most needs it is exactly the one who already decided and would otherwise
   * take an early return - the first version of this file bound the listener
   * after them, so withdrawal was impossible for anyone with a stored choice.
   *
   * Delegated from the document rather than bound to the element, so a footer
   * link works whether it was in the HTML or added later, and a project only
   * has to add the attribute - no script, no id to keep in step.
   *
   * Withdrawing has to be as easy as consenting, and this is what makes that
   * true.
   */
  document.addEventListener('click', function (e) {
    var trigger = e.target.closest && e.target.closest('[data-consent-open]');

    if (!trigger) return;

    e.preventDefault();
    window.consent.open();
  });

  /*
   * No configuration means no consent, and therefore no tracking.
   *
   * This is the case that matters most and it is the easy one to get backwards.
   * A project with the Analytics addon installed and the consent singleton left
   * empty must load nothing - not everything. window.consent still exists and
   * still answers "nothing granted", so analytics.js has something to ask and
   * gets the safe answer.
   */
  if (!settings || settings.Enabled !== true) {
    settings = settings || {};
    decision = null;
    return;
  }

  /*
   * A returning visitor is never shown the banner.
   *
   * The cookie was read synchronously at the top of this file, before the body
   * exists and long before anything could paint, so there is no window in
   * which the banner is visible to somebody who already answered.
   */
  if (decision) {
    // Before notifying, so a provider whose category was refused finds its
    // storage already gone rather than racing the cleanup.
    forgetRefused();
    notify();
    return;
  }

  whenReady(function () {
    lastFocused = document.activeElement;
    rebuild(false);
  });
})();
