<?php
/**
 * Blog admin screen.
 *
 * Deliberately mirrors the markup of Forms' screen and of Content's own
 * collection items view: kiss-container + breadcrumbs, a table-scroll wrapper,
 * an ID badge linking to the item, the state dot and relative <app-datetime>
 * timestamps. Both `icon` and `app-datetime` are plain custom elements, so this
 * works without Vue.
 *
 * The screen exists for what Cockpit's generic Content editor cannot show: the
 * article's real address on the public site. Everything else - authoring - is
 * a link into the normal editor.
 */
$model = Blog\Helper\Blog::MODEL_POSTS;
?>

<style>
    .blog-hidden { display: none !important; }
</style>

<kiss-container class="kiss-margin-small">

    <ul class="kiss-breadcrumbs">
        <li><a href="<?= $this->route('/blog') ?>">Blog</a></li>
    </ul>

    <div class="kiss-flex kiss-flex-middle kiss-margin-bottom" gap="small">
        <div class="kiss-margin-small-right">
            <kiss-svg src="<?= $this->base('blog:assets/icons/blog.svg') ?>" width="40" height="40"><canvas width="40" height="40"></canvas></kiss-svg>
        </div>
        <div class="kiss-flex-1">
            <h1 class="kiss-size-4 kiss-margin-remove">Blog</h1>
            <div class="kiss-size-small kiss-color-muted">Articles published on your website</div>
        </div>
        <a class="kiss-button kiss-button-primary kiss-flex kiss-flex-middle" gap="xsmall"
           href="<?= $this->route('/content/collection/item/'.$model) ?>">
            <icon>add</icon> New article
        </a>
    </div>

    <?php if (!$siteUrl): ?>
        <kiss-card class="kiss-padding-small kiss-margin-bottom" theme="contrast">
            <div class="kiss-size-small kiss-color-muted">
                <icon class="kiss-margin-xsmall-right">info</icon>
                The site URL is not configured, so preview links are unavailable.
                Set <code>SITE_URL</code> in the project environment, or a
                <code>blog.site_url</code> entry in <code>cockpit/config.php</code>.
            </div>
        </kiss-card>
    <?php endif; ?>

    <div class="kiss-flex kiss-flex-wrap" gap="small" style="align-items:flex-start;">

        <!-- One entry per blog -->
        <div style="flex:0 0 220px; min-width:200px;">
            <kiss-card theme="contrast shadowed" class="kiss-padding-small">
                <kiss-navlist>
                    <ul id="blog-list">
                        <li class="kiss-nav-header">Blogs</li>
                        <li class="active"><a data-blog="">All articles</a></li>
                        <?php foreach ($blogs as $blog): ?>
                            <li>
                                <a data-blog="<?= htmlspecialchars($blog['_id']) ?>">
                                    <?= htmlspecialchars($blog['title'] ?? $blog['slug'] ?? '') ?>
                                </a>
                            </li>
                        <?php endforeach; ?>
                        <?php if (!count($blogs)): ?>
                            <li class="kiss-padding-small kiss-color-muted kiss-size-small">
                                No blogs yet. Create one in
                                <a href="<?= $this->route('/content/collection/item/'.Blog\Helper\Blog::MODEL_BLOGS) ?>">Blogs</a>.
                            </li>
                        <?php endif; ?>
                    </ul>
                </kiss-navlist>
            </kiss-card>
        </div>

        <div class="kiss-flex-1" style="min-width:0;">

            <kiss-card theme="contrast shadowed" class="kiss-padding-small">

                <div class="kiss-flex kiss-flex-middle kiss-margin-small-bottom" gap="small">
                    <div class="kiss-flex-1 kiss-size-small kiss-color-muted" id="blog-count"></div>
                </div>

                <div id="blog-empty" class="kiss-padding kiss-align-center kiss-color-muted">
                    <span id="blog-empty-text">No articles yet</span>
                </div>

                <div id="blog-table-wrap" class="blog-hidden">
                    <table class="kiss-table kiss-table-fixed-header" table-scroll>
                        <thead>
                            <tr>
                                <th fixed="left" width="70">ID</th>
                                <th class="kiss-align-center" width="20">State</th>
                                <th>Title</th>
                                <th width="120">Blog</th>
                                <th width="140">Author</th>
                                <th width="110">Published</th>
                                <th fixed="right" width="40"></th>
                            </tr>
                        </thead>
                        <tbody id="blog-rows"></tbody>
                    </table>
                </div>

            </kiss-card>
        </div>
    </div>
</kiss-container>

<script>
(function() {

    var base  = '<?= $this->route('/blog/api') ?>',
        model = '<?= $model ?>',
        state = { blog: '' };

    function $(id) { return document.getElementById(id); }

    function esc(value) {
        return String(value === null || value === undefined ? '' : value).replace(/[&<>"']/g, function(c) {
            return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
        });
    }

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
        $('blog-empty-text').textContent = message;
        $('blog-empty').classList.remove('blog-hidden');
        $('blog-table-wrap').classList.add('blog-hidden');
        $('blog-count').textContent = '';
    }

    function showTable() {
        $('blog-empty').classList.add('blog-hidden');
        $('blog-table-wrap').classList.remove('blog-hidden');
    }

    function load() {

        api(base + '/posts?blog=' + encodeURIComponent(state.blog)).then(function(result) {

            if (!result.success) {
                showEmpty(result.error || 'Could not load articles');
                return;
            }

            var posts = result.posts || [];

            if (!posts.length) {
                showEmpty('No articles yet');
                return;
            }

            showTable();

            $('blog-count').textContent = posts.length + ' ' + (posts.length === 1 ? 'article' : 'articles');

            $('blog-rows').innerHTML = posts.map(function(post) {

                var href = App.route('/content/collection/item/' + model + '/' + post._id),
                    byline = post.byline && post.byline.name;

                return '<tr>'
                    + '<td fixed="left">'
                        + '<a class="kiss-badge kiss-link-muted" href="' + href + '" title="' + esc(post._id) + '">'
                        + '<icon>edit</icon>...' + esc(String(post._id).substr(-5)) + '</a>'
                    + '</td>'
                    + '<td class="kiss-align-center">'
                        + '<icon class="' + (post._state === 1 ? 'kiss-color-success' : (post._state === -1 ? 'kiss-color-muted' : 'kiss-color-danger')) + '">trip_origin</icon>'
                    + '</td>'
                    + '<td><a href="' + href + '">' + esc(post.title || '(untitled)') + '</a>'
                        + '<div class="kiss-size-xsmall kiss-color-muted kiss-text-monospace">/' + esc(post.slug || '') + '</div></td>'
                    + '<td>' + (post.blogTitle
                        ? '<span class="kiss-badge kiss-badge-outline">' + esc(post.blogTitle) + '</span>'
                        : '<span class="kiss-badge kiss-badge-outline kiss-color-danger">none</span>') + '</td>'
                    + '<td class="kiss-size-small">' + (byline
                        ? esc(byline)
                        : '<span class="kiss-badge kiss-badge-outline kiss-color-muted">n/a</span>') + '</td>'
                    + '<td class="kiss-size-small kiss-color-muted kiss-text-monospace">' + esc(post.publishedAt || '') + '</td>'
                    + '<td class="kiss-align-center" fixed="right">'
                        + (post.url
                            ? '<a class="kiss-link-muted" href="' + esc(post.url) + '" target="_blank" rel="noopener" title="View on the site"><icon>open_in_new</icon></a>'
                            : '')
                        + '<a class="kiss-link-muted kiss-margin-small-left" data-purge="' + esc(post._id) + '" title="Purge this article from the site cache"><icon>cached</icon></a>'
                    + '</td>'
                    + '</tr>';
            }).join('');

        }).catch(function() {
            showEmpty('Could not load articles');
        });
    }

    $('blog-rows').addEventListener('click', function(e) {

        var link = e.target.closest && e.target.closest('[data-purge]');

        if (!link) return;

        api(base + '/purge', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: model, id: link.getAttribute('data-purge') })
        }).then(function(result) {
            if (result.success) App.ui.notify('Cache purged.', 'success');
            else App.ui.notify(result.error || 'Purge failed.', 'error');
        }).catch(function() {
            App.ui.notify('Purge failed.', 'error');
        });
    });

    $('blog-list').addEventListener('click', function(e) {

        var link = e.target.closest && e.target.closest('[data-blog]');

        if (!link) return;

        e.preventDefault();

        Array.prototype.forEach.call(this.querySelectorAll('li'), function(el) {
            el.classList.remove('active');
        });

        link.parentNode.classList.add('active');

        state.blog = link.getAttribute('data-blog');
        load();
    });

    load();
})();
</script>
