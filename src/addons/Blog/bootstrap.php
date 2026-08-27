<?php
/**
 * Blog - shared blog structure for gosite sites, on Cockpit v2 (core-2.14.0).
 *
 * Articles live in ordinary Content collections, created automatically on first
 * admin load:
 *
 *   blogs           title, slug, description
 *   blogPosts       title, slug, blog, excerpt, body, cover, category,
 *                   author, publishedAt
 *   blogCategories  title, slug
 *   blogAuthors     name, bio, photo, user
 *
 * Multi-blog is data, not schema: a blog is an item in `blogs` and an article
 * references it, so every gosite project runs the same four models.
 *
 * The public pages are served by the Go application at /{blog} and
 * /{blog}/{slug}; this addon serves nothing to visitors. Unpublished articles
 * are invisible to it either way - Cockpit's core read API hard-codes
 * filter._state = 1.
 *
 * Admin screen:
 *   GET  /blog
 *
 * Admin API (acl blog/manage, CSRF on mutations):
 *   GET  /blog/api/posts?blog=<id>
 *
 * NOTE: the addon directory MUST be named "Blog" with a capital B. Lime's
 * autoloader maps the namespace straight onto the directory name, so a
 * lowercase folder only works on case-insensitive filesystems (macOS) and
 * fatals on Linux.
 */

$this->helpers['blog'] = 'Blog\\Helper\\Blog';

/**
 * Registration order matters: '/blog/api' must be bound before '/blog'
 * (admin.php), otherwise bindClass('/blog') swallows these routes.
 */
$this->bindClass('Blog\\Controller\\Api', '/blog/api');

// Slug derivation, scoped uniqueness and reserved-path checks. Bound here
// rather than in admin.php so they also apply to writes that arrive through
// the REST API, not just to edits made in the admin UI.
$this->on('content.item.save.before.blogPosts', function(&$item, $isUpdate) {
    $this->helper('blog')->beforeSavePost($item, $isUpdate);
});

$this->on('content.item.save.before.blogs', function(&$item, $isUpdate) {
    $this->helper('blog')->beforeSaveBlog($item, $isUpdate);
});

// Admin UI (menu entry + screen)
$this->on('app.admin.init', function() {
    include(__DIR__.'/admin.php');
});
