<?php
// Renders the Forms addon's Mattermost body without Cockpit and checks that
// its wording comes from the site's `forms` config. Run: php tests/php/forms_mattermost.test.php

namespace Lime {
    class Helper {
        public $app;
        public function __construct($app) { $this->app = $app; }
    }
}

namespace {
    require __DIR__.'/../../src/addons/Forms/Helper/Forms.php';

    class FakeApp {
        public function __construct(private array $config) {}
        public function retrieve(string $key, $default = null) {
            $parts = explode('/', $key);
            if ($parts[0] !== 'forms') return $default;
            return $this->config[$parts[1]] ?? $default;
        }
    }

    class ExposedForms extends \Forms\Helper\Forms {
        public function body(array $settings, array $entry): array {
            return json_decode($this->mattermostBody($settings, $entry), true);
        }
    }

    $failures = 0;
    function check(string $name, bool $ok): void {
        global $failures;
        echo ($ok ? 'ok   ' : 'FAIL ').$name."\n";
        if (!$ok) $failures++;
    }

    $entry = ['form' => 'cotizar', 'data' => ['nombre' => 'Ana', 'tel' => ''], '_created' => 1785863238];
    $date  = date('Y-m-d H:i', 1785863238);

    // Defaults: no site name, no colour, the original English heading.
    $b = (new ExposedForms(new FakeApp([])))->body(['label' => 'Cotizar'], $entry);
    check('default heading uses the label', $b['text'] === 'New **Cotizar** submission');
    check('default footer is the date only', $b['attachments'][0]['footer'] === $date);
    check('default sends no colour', !array_key_exists('color', $b['attachments'][0]));
    check('fields travel one per line', count($b['attachments'][0]['fields']) === 2);
    check('an empty value shows a dash', $b['attachments'][0]['fields'][1]['value'] === '—');

    // Configured by the site.
    $cfg = ['webhookHeading' => 'Nuevo envío: {form}', 'webhookSiteName' => 'Aldu Dotaciones', 'webhookColor' => '#0055AA'];
    $b = (new ExposedForms(new FakeApp($cfg)))->body(['label' => ''], $entry);
    check('heading from config, form name as fallback', $b['text'] === 'Nuevo envío: cotizar');
    check('footer carries the site name', $b['attachments'][0]['footer'] === 'Aldu Dotaciones · '.$date);
    check('colour from config', $b['attachments'][0]['color'] === '#0055AA');

    exit($failures ? 1 : 0);
}
