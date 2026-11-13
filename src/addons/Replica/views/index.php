<?php
/**
 * Replica admin screen.
 *
 * Mirrors the panel's own markup (kiss-container, kiss-card, kiss-table,
 * app-datetime) rather than introducing a second look. `icon` and
 * `app-datetime` are plain custom elements, so no Vue is needed here.
 */
?>

<kiss-container class="kiss-margin-small">

    <ul class="kiss-breadcrumbs">
        <li><a href="<?= $this->route('/replica') ?>">Replica</a></li>
    </ul>

    <div class="kiss-flex kiss-flex-middle kiss-margin-bottom" gap="small">
        <div class="kiss-margin-small-right">
            <kiss-svg src="<?= $this->base('replica:assets/icons/replica.svg') ?>" width="40" height="40"><canvas width="40" height="40"></canvas></kiss-svg>
        </div>
        <div class="kiss-flex-1">
            <h1 class="kiss-size-4 kiss-margin-remove">Replica</h1>
            <div class="kiss-size-small kiss-color-muted">Replicate content between Cockpit instances</div>
        </div>
        <button id="rp-new" class="kiss-button kiss-button-primary kiss-flex kiss-flex-middle" gap="xsmall">
            <icon>add</icon> Add target
        </button>
    </div>


    <!-- What the two knobs actually do. Shown once, collapsed by default. -->
    <details id="rp-guide" class="kiss-margin-small">
        <summary class="kiss-size-small kiss-color-muted" style="cursor:pointer;">
            <icon>help_outline</icon> How mode and dry run work
        </summary>
        <kiss-card class="kiss-padding kiss-margin-small-top" theme="contrast">
            <div class="kiss-flex kiss-flex-wrap" gap="large">

                <div style="flex:1 1 280px;min-width:260px;">
                    <div class="kiss-text-caption kiss-text-bold kiss-margin-xsmall-bottom">Mode &mdash; who wins a conflict</div>
                    <table class="kiss-table kiss-size-small">
                        <tr>
                            <td width="70"><span class="kiss-badge kiss-badge-outline">merge</span></td>
                            <td>The <strong>newest entry wins</strong>, compared by <code>_modified</code>.
                                If the destination has a newer version it is left untouched and logged as
                                <em>skipped</em>. Safe default: it never overwrites work done on the other side.</td>
                        </tr>
                        <tr>
                            <td><span class="kiss-badge kiss-badge-outline kiss-color-danger">mirror</span></td>
                            <td>The <strong>source always wins</strong>. Every entry in scope is overwritten on the
                                destination, even if it was edited there more recently. Those edits are lost.
                                Use it to force one instance to match another.</td>
                        </tr>
                    </table>
                    <div class="kiss-size-xsmall kiss-color-muted kiss-margin-xsmall-top">
                        Both modes replace entries whole, so a field deleted at the source also disappears at the destination.
                    </div>
                </div>

                <div style="flex:1 1 280px;min-width:260px;">
                    <div class="kiss-text-caption kiss-text-bold kiss-margin-xsmall-bottom">Dry run &mdash; rehearsal</div>
                    <p class="kiss-size-small kiss-margin-remove">
                        Performs the whole comparison and reports exactly what <em>would</em> be created, updated or
                        skipped, but <strong>writes nothing</strong> on either instance. It still appears in the
                        activity log, flagged <span class="kiss-badge kiss-badge-outline">dry</span>.
                    </p>
                    <p class="kiss-size-small kiss-color-muted">
                        Run it before any <span class="kiss-badge kiss-badge-outline kiss-color-danger">mirror</span>,
                        and the first time you point at a new target.
                    </p>

                    <div class="kiss-text-caption kiss-text-bold kiss-margin-small-top kiss-margin-xsmall-bottom">Direction</div>
                    <p class="kiss-size-small kiss-margin-remove">
                        <strong>Push</strong> sends this instance&rsquo;s content to the target.
                        <strong>Pull</strong> brings the target&rsquo;s content here. The source is always the
                        instance you are replicating <em>from</em>.
                    </p>
                </div>
            </div>
        </kiss-card>
    </details>

    <!-- Targets -->
    <div id="rp-targets"></div>

    <!-- Protected content -->
    <kiss-card id="rp-protected" class="kiss-padding kiss-margin" theme="contrast shadowed">
        <h2 class="kiss-size-5 kiss-margin-remove">Protected content</h2>
        <p class="kiss-size-small kiss-color-muted kiss-margin-xsmall-top kiss-margin-remove">
            Protected content cannot be overwritten by replication from another instance. Editing it here still works.
        </p>

        <div id="rp-protected-list" class="rp-groups kiss-margin-small-top"></div>

        <div class="kiss-margin-small kiss-flex kiss-flex-middle kiss-flex-wrap" gap="small">
            <button id="rp-protected-save" class="kiss-button kiss-button-primary" type="button">Save protected content</button>
            <span id="rp-protected-status" class="kiss-size-small kiss-color-muted" aria-live="polite"></span>
        </div>
    </kiss-card>

    <!-- Target editor -->
    <kiss-card id="rp-form" class="rp-hidden kiss-padding kiss-margin" theme="contrast shadowed">
        <h2 class="kiss-size-5 kiss-margin-small-bottom" id="rp-form-title">Add target</h2>

        <input type="hidden" id="rp-id">

        <div class="kiss-margin-small">
            <label class="kiss-size-small kiss-text-caption">Name</label>
            <input id="rp-name" class="kiss-input" type="text" placeholder="staging">
        </div>

        <div class="kiss-margin-small">
            <label class="kiss-size-small kiss-text-caption">Base URL</label>
            <input id="rp-url" class="kiss-input" type="text" placeholder="http://cms.example.com">
        </div>

        <div class="kiss-margin-small">
            <label class="kiss-size-small kiss-text-caption">API key</label>
            <input id="rp-key" class="kiss-input" type="password" autocomplete="new-password" placeholder="issued by the remote instance">
            <div class="kiss-size-xsmall kiss-color-muted kiss-margin-xsmall-top">
                Stored server side and never sent back to this screen. Leave empty when editing to keep the current key.
            </div>
        </div>

        <div class="kiss-margin-small">
            <label class="kiss-size-small kiss-text-caption">Content models</label>

            <div class="rp-panel kiss-margin-xsmall-top">
                <div class="kiss-flex kiss-flex-middle kiss-flex-wrap" gap="small">
                    <span id="rp-scope-label" class="rp-scope-label kiss-size-small" aria-live="polite"></span>
                    <div class="kiss-flex-1"></div>
                    <input id="rp-filter" class="kiss-input kiss-input-small rp-filter" type="search" placeholder="Filter models…" aria-label="Filter models">
                    <button id="rp-select-all" class="kiss-button kiss-button-small" type="button">Select all</button>
                    <button id="rp-clear-all" class="kiss-button kiss-button-small" type="button">Clear</button>
                </div>

                <div id="rp-collections" class="rp-groups kiss-margin-small-top"></div>

                <div class="rp-helper kiss-size-xsmall kiss-color-muted kiss-margin-xsmall-top kiss-flex kiss-flex-middle" gap="xsmall">
                    <icon>info_outline</icon>
                    <span>Tick the models to replicate. None selected = every collection and singleton.</span>
                </div>
            </div>
        </div>

        <div class="kiss-margin-small">
            <label class="kiss-size-small kiss-text-caption">Also replicate</label>
            <div class="rp-panel kiss-margin-xsmall-top">
                <div class="kiss-flex kiss-flex-middle kiss-flex-wrap" gap="large">
                    <label class="kiss-flex kiss-flex-middle kiss-size-small rp-switch" gap="xsmall"
                        title="Transfer each model's structure - field types and whether it is a collection or singleton.">
                        <input id="rp-models" class="kiss-checkbox" type="checkbox"> Model definitions
                    </label>
                    <label class="kiss-flex kiss-flex-middle kiss-size-small rp-switch" gap="xsmall"
                        title="Transfer uploaded files and their metadata (images, videos, documents) registered in Cockpit.">
                        <input id="rp-assets" class="kiss-checkbox" type="checkbox"> Assets
                        <span class="kiss-badge kiss-badge-outline kiss-color-muted">files + metadata</span>
                    </label>
                </div>
                <div class="rp-helper kiss-size-xsmall kiss-color-muted kiss-margin-xsmall-top">
                    Both need the remote to run Replica; otherwise only content is transferred.
                </div>
            </div>
        </div>

        <div class="kiss-margin-small kiss-flex kiss-flex-middle kiss-flex-wrap" gap="small">
            <label class="kiss-flex kiss-flex-middle kiss-size-small rp-switch" gap="xsmall"
                title="A disabled target keeps its settings but refuses to run.">
                <input id="rp-enabled" class="kiss-checkbox" type="checkbox" checked> Active
            </label>
            <span class="kiss-size-xsmall kiss-color-muted">Disabled targets keep their settings but refuse to run.</span>
        </div>

        <div class="kiss-margin kiss-flex" gap="small">
            <button id="rp-save" class="kiss-button kiss-button-primary">Save target</button>
            <button id="rp-cancel" class="kiss-button">Cancel</button>
        </div>
    </kiss-card>

    <!-- Run result -->
    <kiss-card id="rp-result" class="rp-hidden kiss-padding kiss-margin" theme="contrast shadowed">
        <div class="kiss-flex kiss-flex-middle kiss-margin-small-bottom">
            <h2 class="kiss-size-5 kiss-margin-remove kiss-flex-1">Result</h2>
            <a id="rp-result-close" class="kiss-link-muted"><icon>close</icon></a>
        </div>
        <pre id="rp-result-body" class="kiss-size-small" style="white-space:pre-wrap;word-break:break-word;margin:0;"></pre>
    </kiss-card>

    <!-- Compare -->
    <kiss-card id="rp-compare" class="rp-hidden kiss-padding kiss-margin" theme="contrast shadowed">
        <div class="kiss-flex kiss-flex-middle kiss-flex-wrap kiss-margin-small-bottom" gap="small">
            <h2 class="kiss-size-5 kiss-margin-remove kiss-flex-1" id="rp-compare-title">Compare</h2>
            <select id="rp-compare-model" class="kiss-input kiss-size-small" style="width:auto;" aria-label="Content model"></select>
            <a id="rp-compare-close" class="kiss-link-muted"><icon>close</icon></a>
        </div>

        <div id="rp-compare-tabs" class="kiss-flex kiss-flex-wrap kiss-margin-small-bottom" gap="xsmall" role="tablist"></div>
        <div id="rp-compare-note" class="kiss-size-small kiss-color-muted kiss-margin-small-bottom"></div>

        <div class="table-scroll">
            <table class="kiss-table">
                <thead>
                    <tr>
                        <th width="40"></th>
                        <th>Title</th>
                        <th width="160">Content model</th>
                        <th width="200">Id</th>
                    </tr>
                </thead>
                <tbody id="rp-compare-rows"></tbody>
            </table>
        </div>

        <div class="kiss-margin-small kiss-flex kiss-flex-middle kiss-flex-wrap" gap="small">
            <button id="rp-compare-push" class="kiss-button kiss-button-primary" type="button" disabled>Push selected</button>
            <span id="rp-compare-selection" class="kiss-size-small kiss-color-muted" aria-live="polite"></span>
        </div>
    </kiss-card>

    <!-- Activity log -->
    <h2 class="kiss-size-5 kiss-margin-top">Activity</h2>

    <div class="table-scroll kiss-margin-small">
        <table class="kiss-table">
            <thead>
                <tr>
                    <th width="150">When</th>
                    <th width="80">Direction</th>
                    <th width="140">Target</th>
                    <th width="90">Mode</th>
                    <th width="80">Transport</th>
                    <th width="70">Created</th>
                    <th width="70">Updated</th>
                    <th width="70">Skipped</th>
                    <th width="70">Errors</th>
                </tr>
            </thead>
            <tbody id="rp-log">
                <tr><td colspan="9" class="kiss-padding kiss-color-muted">Loading…</td></tr>
            </tbody>
        </table>
    </div>
</kiss-container>

<style>
    /* Doubled class: kiss declares utility displays with !important, so this
       needs both !important and higher specificity to reliably win. */
    .rp-hidden.rp-hidden { display: none !important; }

    #rp-targets .rp-target + .rp-target { margin-top: .5rem; }
    #rp-guide summary::-webkit-details-marker { display: none; }
    #rp-guide summary:hover { color: var(--kiss-color-primary); }
    #rp-guide code { font-size: .9em; }
    .rp-switch { cursor: pointer; user-select: none; }

    /* Content models picker ---------------------------------------------- */

    .rp-panel {
        border: 1px solid var(--kiss-card-bordered-color, var(--kiss-hr-color, rgba(127,127,127,.3)));
        border-radius: var(--kiss-radius, 8px);
        padding: 12px 14px;
        background: var(--kiss-input-background, rgba(127,127,127,.06));
    }

    .rp-scope-label {
        display: inline-flex; align-items: center;
        font-weight: 600; letter-spacing: .02em;
    }
    .rp-scope-label::before {
        content: ''; display: inline-block; width: 7px; height: 7px;
        border-radius: 50%; margin-right: 7px;
        background: var(--kiss-color-muted);
    }
    .rp-scope-label-all::before    { background: var(--kiss-color-success); }
    .rp-scope-label-partial::before { background: var(--kiss-color-primary); }

    .rp-filter { width: 220px; max-width: 100%; }

    .rp-groups .rp-group + .rp-group { margin-top: 14px; }

    .rp-group-head {
        display: flex; align-items: baseline; gap: 8px;
        text-transform: uppercase; letter-spacing: .08em;
        margin-bottom: 8px;
    }
    .rp-group-count {
        font-size: 11px; padding: 1px 7px;
        border: 1px solid var(--kiss-card-bordered-color, var(--kiss-hr-color));
        border-radius: 999px;
    }

    .rp-group-body { display: flex; flex-wrap: wrap; gap: 6px; }

    .rp-chip {
        display: inline-flex; align-items: center; gap: 7px;
        padding: 6px 11px;
        font-size: 13px; line-height: 1.2;
        border: 1px solid var(--kiss-card-bordered-color, var(--kiss-hr-color));
        border-radius: var(--kiss-radius, 8px);
        cursor: pointer; user-select: none;
        transition: border-color .15s ease, background-color .15s ease;
    }
    .rp-chip:hover { border-color: var(--kiss-color-primary); }
    .rp-chip input { margin: 0; }
    .rp-chip:has(input:checked) {
        border-color: var(--kiss-color-primary);
        background: color-mix(in srgb, var(--kiss-color-primary) 12%, transparent);
    }

    .rp-empty {
        padding: 18px 12px; text-align: center;
        border: 1px dashed var(--kiss-card-bordered-color, var(--kiss-hr-color));
        border-radius: var(--kiss-radius, 8px);
    }

    .rp-helper { gap: 6px; }

    /* Protected content switches ----------------------------------------- */

    .rp-protect-row {
        padding: 9px 0; cursor: pointer; user-select: none;
        border-top: 1px solid var(--kiss-card-bordered-color, var(--kiss-hr-color, rgba(127,127,127,.3)));
    }
    .rp-protect-row:first-child { border-top: 0; }
    .rp-protect-row input { margin: 0; flex: none; }
</style>

<script>
(function() {

    var base        = App.route('/replica/api'),
        collections = <?= json_encode($collections) ?>,
        targets     = <?= json_encode($targets) ?>;

    function $(id) { return document.getElementById(id); }

    function esc(v) {
        return String(v === null || v === undefined ? '' : v)
            .replace(/[&<>"]/g, function(c) {
                return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
            });
    }

    /* X-Requested-With matters: core's "after" hook only returns JSON error
       bodies (401/404) for ajax requests, HTML otherwise. */
    function api(path, options) {
        options = options || {};
        options.credentials = 'same-origin';
        options.headers = Object.assign({
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'X-CSRF-TOKEN': App.csrf || ''
        }, options.headers || {});
        return fetch(base + path, options).then(function(r) { return r.json(); });
    }

    function notify(message, type) {
        if (App.ui && App.ui.notify) App.ui.notify(message, type || 'success');
    }

    // ------------------------------------------------------------- targets

    function renderTargets() {

        if (!targets.length) {
            $('rp-targets').innerHTML = '<kiss-card class="kiss-padding kiss-color-muted" theme="contrast">'
                + 'No targets yet. Add the remote instance you want to replicate with.</kiss-card>';
            return;
        }

        $('rp-targets').innerHTML = targets.map(function(t) {

            var scope = t.models && t.models.length ? t.models.join(', ') : 'all content models',
                last  = t.lastRun;

            return '<kiss-card class="rp-target kiss-padding" theme="contrast shadowed">'
                + '<div class="kiss-flex kiss-flex-middle kiss-flex-wrap" gap="small">'
                    + '<div class="kiss-flex-1" style="min-width:220px;">'
                        + '<div class="kiss-flex kiss-flex-middle" gap="xsmall">'
                            + '<icon class="' + (t.enabled ? 'kiss-color-success' : 'kiss-color-muted') + '">trip_origin</icon>'
                            + '<strong>' + esc(t.name) + '</strong>'
                            + (t.enabled ? '' : ' <span class="kiss-badge kiss-badge-outline kiss-color-muted">inactive</span>')
                        + '</div>'
                        + '<div class="kiss-size-small kiss-color-muted kiss-text-monospace">' + esc(t.base_url) + '</div>'
                        + '<div class="kiss-size-xsmall kiss-color-muted">key ' + esc(t.api_key || 'not set')
                            + ' &middot; ' + esc(scope)
                            + ' &middot; models ' + (t.syncModels ? 'included' : 'excluded')
                            + ' &middot; assets ' + (t.syncAssets ? 'included' : 'excluded') + '</div>'
                        + (last
                            ? '<div class="kiss-size-xsmall kiss-color-muted">last ' + esc(last.direction)
                              + ' <app-datetime type="relative" datetime="' + last.at + '"></app-datetime>'
                              + ' &middot; +' + last.created + ' ~' + last.updated + ' skip ' + last.skipped
                              + (last.errors ? ' <span class="kiss-color-danger">err ' + last.errors + '</span>' : '')
                              + '</div>'
                            : '<div class="kiss-size-xsmall kiss-color-muted">never run</div>')
                    + '</div>'
                    + '<div class="kiss-flex kiss-flex-middle kiss-flex-wrap" gap="xsmall">'
                        + '<label class="kiss-flex kiss-flex-middle kiss-size-small rp-switch" gap="xsmall"'
                            + ' title="A disabled target keeps its settings but refuses to run.">'
                            + '<input type="checkbox" class="kiss-checkbox" data-toggle="' + esc(t._id) + '"'
                            + (t.enabled ? ' checked' : '') + '> ' + (t.enabled ? 'Active' : 'Inactive')
                        + '</label>'
                        + '<select class="kiss-input kiss-size-small" data-mode="' + esc(t._id) + '" style="width:auto;"'
                            + ' title="merge: newest _modified wins, never overwrites newer work. mirror: the source always wins.">'
                            + '<option value="merge">merge &mdash; newest wins</option>'
                            + '<option value="mirror">mirror &mdash; source wins</option>'
                        + '</select>'
                        + '<label class="kiss-flex kiss-flex-middle kiss-size-small" gap="xsmall"'
                            + ' title="Reports what would change without writing anything.">'
                            + '<input type="checkbox" class="kiss-checkbox" data-dry="' + esc(t._id) + '"> dry run'
                        + '</label>'
                        + '<button class="kiss-button kiss-button-small" data-run="push" data-id="' + esc(t._id) + '"'
                            + (t.enabled ? '' : ' disabled') + ' title="Send this instance\'s content to the target.">Push now</button>'
                        + '<button class="kiss-button kiss-button-small" data-run="pull" data-id="' + esc(t._id) + '"'
                            + (t.enabled ? '' : ' disabled') + ' title="Bring the target\'s content here.">Pull now</button>'
                        + '<button class="kiss-button kiss-button-small" data-ping="' + esc(t._id) + '" title="Check the target is reachable and which transport applies.">Test</button>'
                        + '<button class="kiss-button kiss-button-small" data-compare="' + esc(t._id) + '" title="See which entries differ, then push a selection.">Compare</button>'
                        + '<button class="kiss-button kiss-button-small" data-edit="' + esc(t._id) + '">Edit</button>'
                        + '<button class="kiss-button kiss-button-small kiss-color-danger" data-del="' + esc(t._id) + '">Delete</button>'
                    + '</div>'
                + '</div></kiss-card>';
        }).join('');
    }

    function renderCollections(selected) {

        selected = selected || [];

        var el = $('rp-collections');

        if (!collections.length) {
            el.innerHTML = '<div class="rp-empty kiss-size-small kiss-color-muted">'
                + 'No local content models on this instance.</div>';
            refreshScopeUI();
            return;
        }

        /* Group by type so collections and singletons are easy to tell apart. */
        var groups = {};
        collections.forEach(function(c) {
            (groups[c.type] = groups[c.type] || []).push(c.name);
        });

        var html = '';

        ['collection', 'singleton'].forEach(function(type) {
            var names = groups[type];
            if (!names || !names.length) return;
            html += '<div class="rp-group">'
                + '<div class="rp-group-head">'
                    + '<span class="kiss-text-caption kiss-text-bold">'
                        + (type === 'singleton' ? 'Singletons' : 'Collections') + '</span>'
                    + '<span class="rp-group-count">' + names.length + '</span>'
                + '</div>'
                + '<div class="rp-group-body">'
                    + names.map(function(n) {
                        return '<label class="rp-chip" title="' + esc(n) + '">'
                            + '<input type="checkbox" class="kiss-checkbox" value="' + esc(n) + '"'
                            + ' data-name="' + esc(n).toLowerCase() + '"'
                            + (selected.indexOf(n) > -1 ? ' checked' : '') + '> ' + esc(n)
                            + '</label>';
                    }).join('')
                + '</div>'
            + '</div>';
        });

        el.innerHTML = html;
        refreshScopeUI();
    }

    function refreshScopeUI() {

        var label  = $('rp-scope-label'),
            select = $('rp-select-all'),
            clear  = $('rp-clear-all');

        if (!label) return;

        var boxes   = Array.prototype.slice.call($('rp-collections').querySelectorAll('input[type=checkbox]')),
            checked = boxes.filter(function(b) { return b.checked; }).length,
            total   = boxes.length;

        if (!total) {
            label.textContent = 'No models';
            label.className   = 'rp-scope-label kiss-size-small';
            select.disabled   = true;
            clear.disabled    = true;
            return;
        }

        if (checked === total) {
            label.textContent = 'All ' + total + ' models selected';
            label.className   = 'rp-scope-label rp-scope-label-all kiss-size-small';
        } else if (checked === 0) {
            label.textContent = 'None selected \u2014 every collection and singleton';
            label.className   = 'rp-scope-label kiss-size-small';
        } else {
            label.textContent = checked + ' of ' + total + ' models selected';
            label.className   = 'rp-scope-label rp-scope-label-partial kiss-size-small';
        }

        select.disabled = checked === total;
        clear.disabled  = checked === 0;
    }

    function openForm(target) {

        target = target || { models: [], enabled: true, syncModels: false, syncAssets: true };

        $('rp-form-title').textContent = target._id ? 'Edit target' : 'Add target';
        $('rp-id').value      = target._id || '';
        $('rp-name').value    = target.name || '';
        $('rp-url').value     = target.base_url || '';
        $('rp-key').value     = '';
        $('rp-filter').value  = '';
        $('rp-models').checked  = !!target.syncModels;
        $('rp-assets').checked  = !!target.syncAssets;
        $('rp-enabled').checked = target.enabled !== false;

        renderCollections(target.models);

        $('rp-form').classList.remove('rp-hidden');
    }

    function closeForm() { $('rp-form').classList.add('rp-hidden'); }

    // ------------------------------------------------- protected content

    var protection = [];

    function showProtectionStatus(message, type) {
        var el = $('rp-protected-status');
        el.textContent = message;
        el.className = 'kiss-size-small ' + (type === 'error' ? 'kiss-color-danger' : 'kiss-color-muted');
    }

    function renderProtection() {

        var el = $('rp-protected-list');

        if (!protection.length) {
            el.innerHTML = '<div class="rp-empty kiss-size-small kiss-color-muted">'
                + 'No local content models on this instance.</div>';
            return;
        }

        var groups = {};
        protection.forEach(function(m) {
            (groups[m.type] = groups[m.type] || []).push(m);
        });

        var html = '';

        ['collection', 'singleton'].forEach(function(type) {
            var rows = groups[type];
            if (!rows || !rows.length) return;
            html += '<div class="rp-group">'
                + '<div class="rp-group-head">'
                    + '<span class="kiss-text-caption kiss-text-bold">'
                        + (type === 'singleton' ? 'Singletons' : 'Collections') + '</span>'
                    + '<span class="rp-group-count">' + rows.length + '</span>'
                + '</div>'
                + rows.map(function(m) {
                    return '<label class="rp-protect-row kiss-flex kiss-flex-middle kiss-size-small rp-switch" gap="small">'
                        + '<input type="checkbox" class="kiss-checkbox" value="' + esc(m.name) + '"'
                        + (m.protected ? ' checked' : '') + '>'
                        + '<span class="kiss-flex-1">'
                            + '<strong>' + esc(m.name) + '</strong>'
                            + (m.protected
                                ? '<span class="kiss-size-xsmall kiss-color-muted" style="display:block;">'
                                    + 'Protected by ' + esc(m.by || 'an unknown user') + ' '
                                    + '<app-datetime type="relative" datetime="' + m._created + '"></app-datetime></span>'
                                : '')
                        + '</span>'
                    + '</label>';
                }).join('')
            + '</div>';
        });

        el.innerHTML = html;
    }

    function loadProtection() {
        return api('/protected').then(function(res) {
            if (!res.models) return showProtectionStatus(res.error || 'Could not load protected content.', 'error');
            protection = res.models;
            renderProtection();
        });
    }

    function reload() {
        return api('/targets').then(function(data) {
            targets = data.targets || [];
            collections = data.collections || collections;
            renderTargets();
        });
    }

    // ----------------------------------------------------------- compare

    var COMPARE_STATES = ['only-here', 'newer-here', 'newer-there', 'only-there', 'same'],
        COMPARE_LABELS = {
            'only-here':   'Only here',
            'newer-here':  'Changed here',
            'newer-there': 'Changed there',
            'only-there':  'Only there',
            'same':        'Same'
        },
        COMPARE_HINTS = {
            'only-here':   'Entries that exist here only. A push creates them on the other instance.',
            'newer-here':  'Entries changed here. A push updates them on the other instance.',
            'newer-there': 'Entries changed on the other instance. A push does not change them.',
            'only-there':  'Entries that exist on the other instance only. A push does not remove them.',
            'same':        'Identical on both instances.'
        },
        PICKABLE = { 'only-here': true, 'newer-here': true };

    var compareTargetId = null,
        compareModel    = '',
        compareState    = 'only-here',
        compareData     = null,
        compareSelection = {},
        compareRequest  = 0,
        pushing         = false;

    function targetById(id) {
        return targets.filter(function(t) { return t._id === id; })[0] || null;
    }

    function selectionKey(model, id) {
        return JSON.stringify([model, id]);
    }

    function openCompare(id) {

        var target = targetById(id);

        compareTargetId  = id;
        compareModel     = '';
        compareState     = 'only-here';
        compareSelection = {};
        compareData      = null;

        $('rp-compare-title').textContent = 'Compare with ' + (target ? target.name : 'target');
        $('rp-compare-model').innerHTML = '<option value="">All models</option>'
            + collections.map(function(c) {
                return '<option value="' + esc(c.name) + '">' + esc(c.name) + '</option>';
            }).join('');
        $('rp-compare-model').value = '';

        $('rp-compare').classList.remove('rp-hidden');
        $('rp-compare-rows').innerHTML = '<tr><td colspan="4" class="kiss-padding kiss-color-muted">Comparing…</td></tr>';
        $('rp-compare-tabs').innerHTML = '';
        $('rp-compare-note').textContent = '';

        updatePushButton();
        loadCompare(id, '', true);
        $('rp-compare').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function closeCompare() {
        compareTargetId  = null;
        compareSelection = {};
        $('rp-compare').classList.add('rp-hidden');
    }

    function loadCompare(id, model, fresh) {

        var request = ++compareRequest,
            url     = '/diff/' + id + (model ? '?model=' + encodeURIComponent(model) : '');

        api(url).then(function(res) {

            if (request !== compareRequest || id !== compareTargetId) return;

            if (!res.models) return showCompareFailure();

            compareData = res;

            if (fresh) compareState = firstStateWithEntries(res);

            renderCompare();
            updatePushButton();
        }).catch(function() {
            if (request === compareRequest) showCompareFailure();
        });
    }

    function countsAcross(data) {
        var counts = {};
        COMPARE_STATES.forEach(function(s) { counts[s] = 0; });
        Object.keys(data.models || {}).forEach(function(name) {
            var m = data.models[name];
            COMPARE_STATES.forEach(function(s) { counts[s] += (m.counts && m.counts[s]) || 0; });
        });
        return counts;
    }

    function firstStateWithEntries(data) {
        var counts = countsAcross(data);
        for (var i = 0; i < COMPARE_STATES.length; i++) {
            if (counts[COMPARE_STATES[i]] > 0) return COMPARE_STATES[i];
        }
        return 'only-here';
    }

    function showCompareFailure() {

        var target = targetById(compareTargetId);

        compareData = null;
        $('rp-compare-tabs').innerHTML = '';
        $('rp-compare-note').textContent = 'Could not compare with ' + (target ? target.name : 'the target')
            + '. Check that it is running and reachable, then try again.';
        $('rp-compare-rows').innerHTML = '';
        updatePushButton();
    }

    function renderCompare() {

        var counts = countsAcross(compareData),
            models = compareData.models || {},
            names  = Object.keys(models),
            rows   = [],
            protectedNames = [],
            failedNames    = [],
            notes  = [];

        names.forEach(function(name) {

            var m = models[name];

            if (m.protected) protectedNames.push(name);
            if (m.error) failedNames.push(name);

            (m.entries || []).forEach(function(entry) {
                if (entry.state === compareState) rows.push({ model: name, protected: !!m.protected, entry: entry });
            });
        });

        $('rp-compare-tabs').innerHTML = COMPARE_STATES.map(function(state) {
            var active = state === compareState;
            return '<button type="button" class="kiss-button kiss-button-small' + (active ? ' kiss-button-primary' : '')
                + '" role="tab" aria-selected="' + active + '" data-tab="' + state + '">'
                + COMPARE_LABELS[state] + ' <span class="rp-group-count">' + counts[state] + '</span></button>';
        }).join('');

        notes.push('<div>' + COMPARE_HINTS[compareState] + '</div>');

        if (compareData.transport === 'core') {
            notes.push('<div>This instance is a plain Cockpit. Entries that are not published there cannot be seen, so they are not listed as Only there.</div>');
        }

        if (protectedNames.length) {
            notes.push('<div><span class="kiss-badge kiss-badge-outline">Protected on the destination</span> '
                + protectedNames.map(esc).join(', ') + ': a push cannot change these entries.</div>');
        }

        if (failedNames.length) {
            notes.push('<div class="kiss-color-danger">Could not read ' + failedNames.map(esc).join(', ')
                + ' on the other instance.</div>');
        }

        $('rp-compare-note').innerHTML = notes.join('');

        $('rp-compare-rows').innerHTML = rows.length ? rows.map(function(row) {

            var entry    = row.entry,
                pickable = !row.protected && PICKABLE[entry.state] === true && entry.id !== null,
                checked  = pickable && compareSelection[selectionKey(row.model, entry.id)];

            return '<tr>'
                + '<td>' + (pickable
                    ? '<input type="checkbox" class="kiss-checkbox" data-model="' + esc(row.model) + '"'
                        + ' data-id="' + esc(entry.id) + '"' + (checked ? ' checked' : '')
                        + ' aria-label="Select ' + esc(entry.title || entry.id) + '">'
                    : '') + '</td>'
                + '<td>' + esc(entry.title || '—') + '</td>'
                + '<td class="kiss-size-small">' + esc(row.model) + '</td>'
                + '<td class="kiss-size-small kiss-text-monospace kiss-color-muted">' + esc(entry.id || entry.remoteId || '') + '</td>'
                + '</tr>';
        }).join('') : '<tr><td colspan="4" class="kiss-padding kiss-color-muted">Nothing in this group.</td></tr>';
    }

    function updatePushButton() {

        var selected = Object.keys(compareSelection).map(function(k) { return compareSelection[k]; }),
            models   = {},
            target   = targetById(compareTargetId),
            note;

        selected.forEach(function(s) { models[s.model] = true; });

        var modelCount = Object.keys(models).length;

        if (!selected.length) {
            note = 'Select entries to push.';
        } else if (modelCount > 1) {
            note = 'Select entries of one content model at a time.';
        } else {
            note = selected.length + (selected.length === 1 ? ' entry' : ' entries') + ' selected.';
        }

        if (target && !target.enabled) note = 'This target is inactive. Activate it to push.';

        $('rp-compare-selection').textContent = note;
        $('rp-compare-push').disabled = !selected.length || modelCount > 1 || pushing || !(target && target.enabled);
    }

    /* Shared by the target cards and the Compare panel. */
    function showRunResult(direction, res) {

        if (!res.result) {
            return notify(res.error || direction + ' could not start', 'error');
        }

        var r = res.result;

        $('rp-result-body').textContent =
            direction.toUpperCase() + (r.dryRun ? ' (dry run)' : '') +
            '  mode=' + r.mode + '  transport=' + (r.transport || 'n/a') + '\n' +
            'created ' + r.created + '  updated ' + r.updated +
            '  skipped ' + r.skipped + '  errors ' + r.errors +
            '  protected ' + (r.protected || 0) + '\n' +
            ((r.protectedModels || []).length
                ? 'protected models: ' + r.protectedModels.join(', ') + '\n'
                : '') +
            '\n' +
            (r.messages || []).join('\n');

        $('rp-result').classList.remove('rp-hidden');

        notify(res.success ? direction + ' finished' : direction + ' finished with errors',
               res.success ? 'success' : 'error');

        reload();
        loadLog();
    }

    // -------------------------------------------------------------- events

    $('rp-new').addEventListener('click', function() { openForm(null); });

    $('rp-compare-close').addEventListener('click', closeCompare);

    $('rp-compare-model').addEventListener('change', function() {
        compareModel = this.value;
        loadCompare(compareTargetId, compareModel, false);
    });

    $('rp-compare-tabs').addEventListener('click', function(e) {
        var tab = e.target.closest && e.target.closest('[data-tab]');
        if (!tab || !compareData) return;
        compareState = tab.getAttribute('data-tab');
        renderCompare();
    });

    $('rp-compare-rows').addEventListener('change', function(e) {

        var box = e.target;

        if (!box || box.type !== 'checkbox' || !box.hasAttribute('data-id')) return;

        var key = selectionKey(box.getAttribute('data-model'), box.getAttribute('data-id'));

        if (box.checked) {
            compareSelection[key] = { model: box.getAttribute('data-model'), id: box.getAttribute('data-id') };
        } else {
            delete compareSelection[key];
        }

        updatePushButton();
    });

    $('rp-compare-push').addEventListener('click', function() {

        var selected = Object.keys(compareSelection).map(function(k) { return compareSelection[k]; });

        if (!selected.length || !compareTargetId) return;

        var card  = document.querySelector('[data-mode="' + compareTargetId + '"]'),
            dry   = document.querySelector('[data-dry="' + compareTargetId + '"]'),
            runId = compareTargetId;

        pushing = true;
        updatePushButton();
        $('rp-compare-selection').textContent = 'Pushing…';

        api('/run/' + runId, {
            method: 'POST',
            body: JSON.stringify({
                direction: 'push',
                mode:      (card && card.value) || 'merge',
                dryRun:    !!(dry && dry.checked),
                verbose:   true,
                model:     selected[0].model,
                ids:       selected.map(function(s) { return s.id; })
            })
        }).then(function(res) {

            pushing = false;
            showRunResult('push', res);

            if (res.result) compareSelection = {};

            if (compareTargetId === runId) loadCompare(runId, compareModel, false);
            updatePushButton();

        }, function() {

            pushing = false;
            notify('The push could not finish. Try again.', 'error');
            updatePushButton();
        });
    });

    $('rp-cancel').addEventListener('click', closeForm);
    $('rp-result-close').addEventListener('click', function() { $('rp-result').classList.add('rp-hidden'); });

    function setAllChecked(value) {
        var boxes = Array.prototype.slice
            .call($('rp-collections').querySelectorAll('.rp-chip:not(.rp-hidden) input[type=checkbox]'));
        boxes.forEach(function(b) { b.checked = value; });
        refreshScopeUI();
    }

    $('rp-select-all').addEventListener('click', function() { setAllChecked(true); });
    $('rp-clear-all').addEventListener('click', function() { setAllChecked(false); });

    /* Select all / Clear act on the currently visible chips when filtering. */
    $('rp-filter').addEventListener('input', function() {
        var q = this.value.trim().toLowerCase();
        Array.prototype.forEach.call($('rp-collections').querySelectorAll('.rp-group'), function(group) {
            var visible = 0;
            Array.prototype.forEach.call(group.querySelectorAll('.rp-chip'), function(chip) {
                var show = !q || chip.getAttribute('data-name').indexOf(q) > -1;
                chip.classList.toggle('rp-hidden', !show);
                if (show) visible++;
            });
            group.classList.toggle('rp-hidden', visible === 0);
        });
    });

    /* Checkboxes are re-rendered on every open, so listen on the container. */
    $('rp-collections').addEventListener('change', function(e) {
        if (e.target && e.target.type === 'checkbox') refreshScopeUI();
    });

    $('rp-save').addEventListener('click', function() {

        var selected = Array.prototype.slice
            .call($('rp-collections').querySelectorAll('input:checked'))
            .map(function(el) { return el.value; });

        var payload = {
            _id:        $('rp-id').value || undefined,
            name:       $('rp-name').value,
            base_url:   $('rp-url').value,
            api_key:    $('rp-key').value,
            models:     selected,
            syncModels: $('rp-models').checked,
            syncAssets: $('rp-assets').checked,
            enabled:    $('rp-enabled').checked
        };

        api('/target', { method: 'POST', body: JSON.stringify({ target: payload }) }).then(function(res) {
            if (!res.success) return notify(res.error || 'Save failed', 'error');
            notify('Target saved');
            closeForm();
            reload();
        });
    });

    $('rp-targets').addEventListener('click', function(e) {

        var el = e.target.closest && e.target.closest('[data-run],[data-ping],[data-compare],[data-edit],[data-del],[data-toggle]');

        if (!el) return;

        var id = el.getAttribute('data-id') || el.getAttribute('data-ping')
              || el.getAttribute('data-compare') || el.getAttribute('data-edit')
              || el.getAttribute('data-del') || el.getAttribute('data-toggle');

        if (el.hasAttribute('data-toggle')) {

            var wanted = el.checked;

            return api('/toggle/' + id, {
                method: 'POST',
                body: JSON.stringify({ enabled: wanted })
            }).then(function(res) {
                if (!res.success) {
                    el.checked = !wanted;   // put the switch back
                    return notify(res.error || 'Could not change state', 'error');
                }
                notify('Target ' + (res.enabled ? 'activated' : 'deactivated'));
                reload();
            });
        }

        if (el.hasAttribute('data-edit')) {
            return openForm(targets.filter(function(t) { return t._id === id; })[0]);
        }

        if (el.hasAttribute('data-compare')) {
            return openCompare(id);
        }

        if (el.hasAttribute('data-del')) {
            if (!window.confirm('Delete this target?')) return;
            return api('/remove/' + id, { method: 'POST' }).then(function(res) {
                if (!res.success) return notify(res.error || 'Delete failed', 'error');
                notify('Target deleted');
                reload();
            });
        }

        if (el.hasAttribute('data-ping')) {
            el.disabled = true;
            return api('/ping/' + id).then(function(res) {
                el.disabled = false;
                if (res.ok) notify('Reachable, transport: ' + res.transport);
                else notify('Unreachable: ' + (res.error || 'unknown'), 'error');
            });
        }

        // push / pull
        var direction = el.getAttribute('data-run'),
            mode      = document.querySelector('[data-mode="' + id + '"]').value,
            dryRun    = document.querySelector('[data-dry="' + id + '"]').checked;

        el.disabled = true;

        api('/run/' + id, {
            method: 'POST',
            body: JSON.stringify({ direction: direction, mode: mode, dryRun: dryRun, verbose: true })
        }).then(function(res) {
            el.disabled = false;
            showRunResult(direction, res);
        });
    });

    $('rp-protected-save').addEventListener('click', function() {

        var button   = this,
            selected = Array.prototype.slice
                .call($('rp-protected-list').querySelectorAll('input[type=checkbox]:checked'))
                .map(function(el) { return el.value; });

        button.disabled = true;
        showProtectionStatus('Saving…');

        api('/protected', { method: 'POST', body: JSON.stringify({ models: selected }) }).then(function(res) {

            button.disabled = false;

            if (!res.success) {
                return showProtectionStatus(res.error || 'Could not save protected content.', 'error');
            }

            protection = res.models || [];
            renderProtection();

            var message = res.changed.length
                ? 'Saved. ' + res.changed.length + (res.changed.length === 1 ? ' model changed.' : ' models changed.')
                : 'Saved. Nothing changed.';

            showProtectionStatus(message);
            notify('Protected content saved');
            loadLog();
        }).catch(function() {
            button.disabled = false;
            showProtectionStatus('Could not save protected content. Try again.', 'error');
        });
    });

    // ----------------------------------------------------------------- log

    function loadLog() {
        api('/log?limit=25').then(function(data) {

            if (!data.items || !data.items.length) {
                $('rp-log').innerHTML = '<tr><td colspan="9" class="kiss-padding kiss-color-muted">No activity yet.</td></tr>';
                return;
            }

            $('rp-log').innerHTML = data.items.map(function(e) {

                /* Protection changes have no target, counts or mode: one sentence instead. */
                if (e.direction === 'protect') {
                    return '<tr>'
                        + '<td class="kiss-size-small kiss-text-monospace kiss-color-muted"><app-datetime type="relative" datetime="' + e._created + '"></app-datetime></td>'
                        + '<td><span class="kiss-badge kiss-badge-outline">protection</span></td>'
                        + '<td colspan="7" class="kiss-size-small">'
                            + esc(e.model) + ' ' + (e.state === 'protected' ? 'protected' : 'unprotected')
                            + ' by ' + esc(e.by || 'an unknown user')
                        + '</td>'
                        + '</tr>';
                }

                /* A comparison writes nothing, so it has no run counts: show what it found. */
                if (e.direction === 'diff') {
                    var c = e.counts || {};
                    return '<tr>'
                        + '<td class="kiss-size-small kiss-text-monospace kiss-color-muted"><app-datetime type="relative" datetime="' + e._created + '"></app-datetime></td>'
                        + '<td><span class="kiss-badge kiss-badge-outline">compare</span></td>'
                        + '<td class="kiss-size-small">' + esc(e.target_name || '—') + '</td>'
                        + '<td></td>'
                        + '<td class="kiss-size-small kiss-color-muted">' + esc(e.transport || '—') + '</td>'
                        + '<td colspan="4" class="kiss-size-small">'
                            + (c['only-here'] || 0) + ' only here, '
                            + (c['newer-here'] || 0) + ' changed here, '
                            + (c['newer-there'] || 0) + ' changed there, '
                            + (c['only-there'] || 0) + ' only there, '
                            + (c['same'] || 0) + ' same'
                        + '</td>'
                        + '</tr>';
                }

                return '<tr>'
                    + '<td class="kiss-size-small kiss-text-monospace kiss-color-muted"><app-datetime type="relative" datetime="' + e._created + '"></app-datetime></td>'
                    + '<td><span class="kiss-badge kiss-badge-outline">' + esc(e.direction) + '</span></td>'
                    + '<td class="kiss-size-small">' + esc(e.target_name || '—') + '</td>'
                    + '<td class="kiss-size-small">' + esc(e.mode) + (e.dryRun ? ' <span class="kiss-badge kiss-badge-outline">dry</span>' : '') + '</td>'
                    + '<td class="kiss-size-small kiss-color-muted">' + esc(e.transport || '—') + '</td>'
                    + '<td>' + e.created + '</td>'
                    + '<td>' + e.updated + '</td>'
                    + '<td>' + e.skipped + '</td>'
                    + '<td class="' + (e.errors ? 'kiss-color-danger' : '') + '">' + e.errors + '</td>'
                    + '</tr>';
            }).join('');
        });
    }

    renderTargets();
    loadLog();
    loadProtection();
})();
</script>
