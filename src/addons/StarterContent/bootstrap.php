<?php
/**
 * StarterContent - guarantees the models a fresh gosite scaffold expects.
 *
 * Today that is one thing: the `home` singleton the generated application
 * reads on its front page. Without it the app has no content to render and
 * answers 502, which is a poor first impression for a project that was set up
 * correctly.
 *
 * This used to be done from the CLI after boot: wait up to 90s for the REST
 * API, register an API key, POST to /api/models/save, retry five times. That
 * depends on the CMS being up, on a token existing, and on timing - and when
 * any of those was not true it failed silently and the site 502'd.
 *
 * Creating the model from inside Cockpit removes all three dependencies. It is
 * the same approach Forms and Blog already use for their own models: no
 * network, no token, idempotent, and it cannot half-succeed.
 *
 * A model that already exists is never touched - including one an editor has
 * since added fields to.
 */

$this->on('bootstrap', function() {

    $content = $this->module('content');

    if (!$content) {
        return;
    }

    // The check is cheap but not free, and it runs on every request. The
    // ready-flag keeps it to once per installation; when the memory backend is
    // down we simply do the (idempotent) check instead of failing.
    try {
        if ($this->memory->get('gosite.starter.ready')) {
            return;
        }
    } catch (\Throwable $e) {
        // Fall through to the check.
    }

    try {
        if (!$content->exists('home')) {

            $field = function(string $name, string $type, string $label): array {
                return [
                    'name'     => $name,
                    'type'     => $type,
                    'label'    => $label,
                    'info'     => '',
                    'group'    => '',
                    'i18n'     => false,
                    'required' => false,
                    'multiple' => false,
                    'meta'     => [],
                    'opts'     => [],
                ];
            };

            $content->createModel('home', [
                'label'   => 'Home',
                'info'    => 'Front page content. The generated application reads this singleton.',
                'type'    => 'singleton',
                'fields'  => [
                    $field('headline', 'text', 'Headline'),
                    $field('intro', 'wysiwyg', 'Intro'),
                ],
            ]);

            /*
             * Writing the definition updates the database, but
             * Content\Helper\Model caches the registry under the
             * 'content.models' memory key and only bypasses it when debug is
             * on. Without this rebuild the model is invisible on any non-debug
             * environment: the API answers "Model home not found" while the
             * definition sits correct in the database - which is exactly the
             * 502 this addon exists to prevent.
             * See src/knowledge/cockpit-model-registry-cache.md.
             */
            $this->helper('content.model')->cache(true);
        }

        $this->memory->set('gosite.starter.ready', 1);

    } catch (\Throwable $e) {
        // Never break a request over starter content. The next request retries.
        error_log('[startercontent] '.$e->getMessage());
    }
});
