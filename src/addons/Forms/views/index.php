<?php
/**
 * Forms admin screen.
 *
 * Deliberately mirrors the markup of Content's own collection items view
 * (modules/Content/views/collection/items.php): kiss-container + breadcrumbs,
 * a table-scroll wrapper, an ID badge linking to the item, the state dot, n/a
 * badges for empty values and relative <app-datetime> timestamps. Both `icon`
 * and `app-datetime` are plain custom elements, so this works without Vue.
 */
$model = Forms\Helper\Forms::MODEL_SUBMISSIONS;
?>

<kiss-container class="kiss-margin-small">

    <ul class="kiss-breadcrumbs">
        <li><a href="<?= $this->route('/forms') ?>">Forms</a></li>
    </ul>

    <div class="kiss-flex kiss-flex-middle kiss-margin-bottom" gap="small">
        <div class="kiss-margin-small-right">
            <kiss-svg src="<?= $this->base('forms:assets/icons/forms.svg') ?>" width="40" height="40"><canvas width="40" height="40"></canvas></kiss-svg>
        </div>
        <div class="kiss-flex-1">
            <h1 class="kiss-size-4 kiss-margin-remove">Forms</h1>
            <div class="kiss-size-small kiss-color-muted">Submissions received from your website</div>
        </div>
        <button id="forms-export" class="kiss-button kiss-button-primary kiss-flex kiss-flex-middle" gap="xsmall">
            <icon>download</icon> Export CSV
        </button>
    </div>

    <div class="kiss-flex kiss-flex-wrap" gap="small" style="align-items:flex-start;">

        <!-- One entry per form -->
        <div style="flex:0 0 220px; min-width:200px;">
            <kiss-card theme="contrast shadowed" class="kiss-padding-small">
                <kiss-navlist>
                    <ul id="forms-list">
                        <li class="kiss-nav-header">Forms</li>
                        <?php if (!count($forms)): ?>
                            <li class="kiss-padding-small kiss-color-muted kiss-size-small">
                                No forms yet.
                            </li>
                        <?php endif; ?>
                        <?php foreach ($forms as $i => $form): ?>
                            <li class="<?= $i === 0 ? 'active' : '' ?>">
                                <a class="kiss-flex kiss-flex-middle" gap="xsmall" href="#" data-form="<?= htmlspecialchars($form['form']) ?>">
                                    <icon>description</icon>
                                    <span class="kiss-flex-1 kiss-text-truncate"><?= htmlspecialchars($form['label']) ?></span>
                                    <span class="kiss-badge kiss-badge-outline"><?= (int)$form['count'] ?></span>
                                </a>
                            </li>
                        <?php endforeach; ?>
                    </ul>
                </kiss-navlist>
            </kiss-card>
        </div>

        <!-- Submissions for the selected form -->
        <div style="flex:1 1 480px; min-width:0;">

            <div id="forms-empty" class="forms-hidden animated fadeIn kiss-height-50vh kiss-flex kiss-flex-middle kiss-flex-center kiss-align-center kiss-color-muted">
                <div>
                    <kiss-svg class="kiss-margin-auto" src="<?= $this->base('forms:assets/icons/forms.svg') ?>" width="40" height="40"><canvas width="40" height="40"></canvas></kiss-svg>
                    <p id="forms-empty-text" class="kiss-size-large kiss-text-bold kiss-margin-small-top">No items</p>
                </div>
            </div>

            <div id="forms-table-wrap" class="table-scroll">
                <table class="kiss-table animated fadeIn">
                    <thead id="forms-head"></thead>
                    <tbody id="forms-rows"></tbody>
                </table>
            </div>

            <div class="kiss-flex kiss-flex-middle kiss-margin" gap="small">
                <div id="forms-count" class="kiss-color-muted kiss-size-small"></div>
                <div class="kiss-flex-1"></div>
                <a id="forms-prev" class="kiss-margin-small-start">Previous</a>
                <strong id="forms-page" class="kiss-margin-small-start kiss-size-small"></strong>
                <a id="forms-next" class="kiss-margin-small-start">Next</a>
            </div>
        </div>
    </div>
</kiss-container>

<style>
    /*
     * kiss only styles li.active inside offcanvas/aside navlists, so the active
     * state is restated here with the same treatment the core uses.
     */
    /*
     * Doubled class on purpose: kiss declares ".kiss-flex { display: flex
     * !important }", so this needs both !important AND higher specificity to
     * win regardless of stylesheet order.
     */
    .forms-hidden.forms-hidden { display: none !important; }

    #forms-list > li.active > a { color: var(--kiss-color-primary); font-weight: bold; }
    #forms-list > li > a { cursor: pointer; }
    #forms-rows [data-remove] { cursor: pointer; }
</style>

<script>
(function() {

    var base   = App.route('/forms/api'),
        model  = <?= json_encode($model) ?>,
        forms  = <?= json_encode($forms) ?>,
        state  = { form: forms.length ? forms[0].form : '', page: 1, pages: 1 };

    function $(id) { return document.getElementById(id); }

    function esc(value) {
        return String(value === null || value === undefined ? '' : value)
            .replace(/[&<>"]/g, function(c) {
                return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
            });
    }

    /**
     * Same convention as Content's table: null/empty renders as an outlined
     * "n/a" badge, objects as an "Object" badge, everything else truncated.
     */
    function cell(value) {

        if (value === null || value === undefined || value === '') {
            return '<span class="kiss-badge kiss-badge-outline kiss-color-muted">n/a</span>';
        }

        if (Array.isArray(value)) {
            return '<span class="kiss-badge kiss-badge-outline">' + value.length + '</span>';
        }

        if (typeof value === 'object') {
            return '<span class="kiss-badge kiss-badge-outline">Object</span>';
        }

        if (typeof value === 'boolean') {
            return '<span class="kiss-badge kiss-badge-outline">' + (value ? 'true' : 'false') + '</span>';
        }

        return '<div class="kiss-text-truncate" title="' + esc(value) + '">' + esc(value) + '</div>';
    }

    /**
     * X-Requested-With matters: core's "after" hook only returns JSON error
     * bodies (401/404) for ajax requests, HTML otherwise.
     */
    function api(url, options) {
        options = options || {};
        options.credentials = 'same-origin';
        options.headers = Object.assign({
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'X-CSRF-TOKEN': App.csrf || ''
        }, options.headers || {});
        return fetch(url, options).then(function(r) { return r.json(); });
    }

    /*
     * Visibility is toggled with a class, not with style.display: kiss declares
     * .kiss-flex as "display: flex !important", which beats any inline display
     * and would leave the empty state permanently on screen.
     */
    function showEmpty(message) {
        $('forms-empty-text').textContent = message;
        $('forms-empty').classList.remove('forms-hidden');
        $('forms-table-wrap').classList.add('forms-hidden');
        $('forms-count').textContent = '';
        $('forms-page').textContent = '';
        $('forms-prev').style.visibility = 'hidden';
        $('forms-next').style.visibility = 'hidden';
    }

    function showTable() {
        $('forms-empty').classList.add('forms-hidden');
        $('forms-table-wrap').classList.remove('forms-hidden');
    }

    function load() {

        if (!state.form) {
            showEmpty('No submissions yet');
            return;
        }

        api(base + '/list?form=' + encodeURIComponent(state.form) + '&page=' + state.page).then(function(result) {

            state.pages = result.pages || 1;

            if (!result.items.length) {
                showEmpty('No items');
                return;
            }

            showTable();

            $('forms-count').textContent = result.total + ' ' + (result.total === 1 ? 'Item' : 'Items')
                + (sampleSize && result.total > sampleSize
                    ? ' · columns from newest ' + sampleSize
                    : '');
            $('forms-page').textContent  = result.page + ' — ' + state.pages;
            $('forms-prev').style.visibility = result.page > 1 ? '' : 'hidden';
            $('forms-next').style.visibility = result.page < state.pages ? '' : 'hidden';

            // One column per data field seen in this form, so each form reads
            // like its own table instead of a JSON blob. The set is derived
            // from a bounded sample of the newest submissions; the interface
            // states the bound instead of implying completeness.
            var columns = result.columns || [];
            var sampleSize = result.columnSampleSize || null;

            $('forms-head').innerHTML = '<tr>'
                + '<th fixed="left" width="70">ID</th>'
                + '<th class="kiss-align-center" width="20">State</th>'
                + '<th width="110">Form</th>'
                + columns.map(function(c) { return '<th>' + esc(c) + '</th>'; }).join('')
                + '<th width="140">Origin</th>'
                + '<th width="120">Created</th>'
                + '<th fixed="right" width="20"></th>'
                + '</tr>';

            $('forms-rows').innerHTML = result.items.map(function(item) {

                var data = item.data || {},
                    href = App.route('/content/collection/item/' + model + '/' + item._id);

                return '<tr>'
                    + '<td fixed="left">'
                        + '<a class="kiss-badge kiss-link-muted" href="' + href + '" title="' + esc(item._id) + '">'
                        + '<icon>edit</icon>...' + esc(String(item._id).substr(-5)) + '</a>'
                    + '</td>'
                    + '<td class="kiss-align-center">'
                        + '<icon class="' + (item._state === 1 ? 'kiss-color-success' : (item._state === -1 ? 'kiss-color-muted' : 'kiss-color-danger')) + '">trip_origin</icon>'
                    + '</td>'
                    + '<td><span class="kiss-badge kiss-badge-outline">' + esc(item.form || '') + '</span></td>'
                    + columns.map(function(c) { return '<td>' + cell(data[c]) + '</td>'; }).join('')
                    + '<td class="kiss-size-small kiss-color-muted"><div class="kiss-text-truncate" title="' + esc(item.origin || '') + '">'
                        + (item.origin ? esc(item.origin) : '<span class="kiss-badge kiss-badge-outline kiss-color-muted">n/a</span>')
                        + '</div><div class="kiss-text-monospace kiss-size-xsmall">' + esc(item.ip || '') + '</div></td>'
                    + '<td><span class="kiss-flex kiss-text-monospace kiss-color-muted kiss-size-small">'
                        + '<app-datetime type="relative" datetime="' + (item._created || 0) + '"></app-datetime></span></td>'
                    + '<td class="kiss-align-center" fixed="right">'
                        + '<a class="kiss-link-muted kiss-color-danger" data-remove="' + esc(item._id) + '" title="Delete"><icon>delete</icon></a>'
                    + '</td>'
                    + '</tr>';
            }).join('');

        }).catch(function() {
            showEmpty('Could not load submissions');
        });
    }

    $('forms-list').addEventListener('click', function(e) {

        var link = e.target.closest && e.target.closest('[data-form]');

        if (!link) return;

        e.preventDefault();

        Array.prototype.forEach.call(this.querySelectorAll('li'), function(el) {
            el.classList.remove('active');
        });

        link.parentNode.classList.add('active');

        state.form = link.getAttribute('data-form');
        state.page = 1;
        load();
    });

    $('forms-prev').addEventListener('click', function() {
        if (state.page > 1) { state.page--; load(); }
    });

    $('forms-next').addEventListener('click', function() {
        if (state.page < state.pages) { state.page++; load(); }
    });

    $('forms-export').addEventListener('click', function() {
        if (!state.form) return;
        window.location = base + '/export?form=' + encodeURIComponent(state.form);
    });

    $('forms-rows').addEventListener('click', function(e) {

        var link = e.target.closest && e.target.closest('[data-remove]');

        if (!link) return;

        var id = link.getAttribute('data-remove');

        if (!window.confirm('Delete this submission?')) return;

        api(base + '/remove/' + id, { method: 'POST' }).then(function(result) {
            if (result.success) load();
            else App.ui.notify(result.error || 'Delete failed.', 'error');
        });
    });

    load();
})();
</script>
