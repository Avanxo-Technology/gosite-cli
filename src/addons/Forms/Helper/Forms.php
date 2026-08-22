<?php

namespace Forms\Helper;

/**
 * All Forms business logic. Submissions live in regular Cockpit Content
 * collections (formSubmissions / formSettings), so they are visible and
 * editable in Content like any other content, while this addon adds the public
 * receiver, the anti-spam layer, the per-form screen and the notifications.
 */
class Forms extends \Lime\Helper {

    const MODEL_SUBMISSIONS = 'formSubmissions';
    const MODEL_SETTINGS    = 'formSettings';

    // Anti-spam defaults, overridable per form in formSettings.
    const DEFAULT_THROTTLE_SECONDS = 3;
    const DEFAULT_DAILY_LIMIT      = 50;
    const HONEYPOT_FIELD           = '_hp';

    // Seconds advertised in Retry-After when the rate limit cannot be evaluated
    // because the memory backend is down.
    const RATE_LIMIT_RETRY_AFTER = 30;

    protected bool $modelsChecked = false;

    // ------------------------------------------------------------- install

    /**
     * Creates the two content models if they are missing.
     *
     * Called on admin init and before every submission, so a fresh install
     * needs no manual setup. Cheap: the result is cached in $app->memory and
     * once per request in $modelsChecked.
     */
    public function ensureModels(bool $force = false): void {

        if ($this->modelsChecked && !$force) {
            return;
        }

        $this->modelsChecked = true;

        // The ready-flag is a cache, not a requirement: when the memory backend
        // is down we simply do the (idempotent) model checks.
        try {
            if (!$force && $this->memoryGet('forms.models.ready')) {
                return;
            }
        } catch (\Throwable $e) {
            $this->log('models.ready check skipped: '.$e->getMessage());
        }

        $content = $this->app->module('content');

        if (!$content) return;

        if (!$content->exists(self::MODEL_SUBMISSIONS)) {
            $content->createModel(self::MODEL_SUBMISSIONS, [
                'label'   => 'Form submissions',
                'info'    => 'Submissions received from website forms.',
                'type'    => 'collection',
                'group'   => 'Forms',
                'preview' => ['form', 'data'],
                'fields'  => [
                    $this->field('form', 'text', 'Form', true),
                    $this->field('data', 'object', 'Data'),
                    $this->field('origin', 'text', 'Origin'),
                    $this->field('ip', 'text', 'IP'),
                    $this->field('userAgent', 'text', 'User agent'),
                    $this->field('read', 'boolean', 'Read'),
                ],
            ]);
        }

        if (!$content->exists(self::MODEL_SETTINGS)) {
            $content->createModel(self::MODEL_SETTINGS, [
                'label'   => 'Form settings',
                'info'    => 'Per-form notification and anti-spam configuration.',
                'type'    => 'collection',
                'group'   => 'Forms',
                'preview' => ['form', 'label'],
                'fields'  => [
                    $this->field('form', 'text', 'Form name', true),
                    $this->field('label', 'text', 'Display label'),
                    $this->field('notify', 'tags', 'Notify e-mails'),
                    $this->field('subject', 'text', 'E-mail subject'),
                    $this->field('webhook', 'text', 'Webhook URL'),
                    $this->field('webhookSecret', 'text', 'Webhook secret'),
                    $this->field('throttle', 'number', 'Seconds between submissions per IP'),
                    $this->field('dailyLimit', 'number', 'Max submissions per IP per day'),
                ],
            ]);
        }

        try {
            $this->memorySet('forms.models.ready', 1);
        } catch (\Throwable $e) {
            $this->log('models.ready flag not stored: '.$e->getMessage());
        }
    }

    /**
     * Field definition in the exact shape the Content module stores.
     */
    protected function field(string $name, string $type, string $label, bool $required = false): array {
        return [
            'name'     => $name,
            'type'     => $type,
            'label'    => $label,
            'info'     => '',
            'group'    => '',
            'i18n'     => false,
            'required' => $required,
            'multiple' => false,
            'meta'     => [],
            'opts'     => [],
        ];
    }

    // ------------------------------------------------------------ settings

    /**
     * Configuration document for a form, with defaults applied.
     */
    public function settings(string $form): array {

        $this->ensureModels();

        $doc = $this->app->module('content')->item(self::MODEL_SETTINGS, ['form' => $form]) ?: [];

        // Empty values in the CMS must not override the defaults.
        $doc = array_filter($doc, fn($v) => $v !== null && $v !== '' && $v !== []);

        return array_merge([
            'form'          => $form,
            'label'         => $form,
            'notify'        => [],
            'subject'       => null,
            'webhook'       => null,
            'webhookSecret' => null,
            'throttle'      => self::DEFAULT_THROTTLE_SECONDS,
            'dailyLimit'    => self::DEFAULT_DAILY_LIMIT,
        ], $doc);
    }

    /**
     * Every known form: those configured in formSettings plus any that has
     * received a submission, each with its submission count.
     */
    public function forms(): array {

        $this->ensureModels();

        $content = $this->app->module('content');
        $forms   = [];

        foreach ($content->items(self::MODEL_SETTINGS, ['limit' => 500]) as $doc) {

            if (empty($doc['form'])) continue;

            $forms[$doc['form']] = [
                'form'  => $doc['form'],
                'label' => $doc['label'] ?: $doc['form'],
                'count' => 0,
            ];
        }

        foreach ($content->items(self::MODEL_SUBMISSIONS, ['fields' => ['form' => 1], 'limit' => 10000]) as $doc) {

            if (empty($doc['form'])) continue;

            if (!isset($forms[$doc['form']])) {
                $forms[$doc['form']] = ['form' => $doc['form'], 'label' => $doc['form'], 'count' => 0];
            }

            $forms[$doc['form']]['count']++;
        }

        $forms = array_values($forms);

        usort($forms, fn($a, $b) => strcasecmp($a['label'], $b['label']));

        return $forms;
    }

    /**
     * Column names for a form: the union of the data keys of its submissions.
     * This is what lets the screen show one real column per field even though
     * the payload itself is schemaless.
     */
    public function columnsFor(?string $form = null): array {

        $this->ensureModels();

        $options = ['fields' => ['data' => 1], 'limit' => 500, 'sort' => ['_created' => -1]];

        if ($form) $options['filter'] = ['form' => $form];

        $columns = [];

        foreach ($this->app->module('content')->items(self::MODEL_SUBMISSIONS, $options) as $doc) {
            foreach (array_keys($doc['data'] ?? []) as $key) {
                $columns[$key] = true;
            }
        }

        return array_keys($columns);
    }

    // ---------------------------------------------------------- submission

    /**
     * Handles a public submission end to end.
     *
     * Returns ['status' => int, 'success' => bool, ...]; the caller emits JSON.
     */
    public function handleSubmission(): array {

        $payload = $this->readPayload();

        $form = trim((string)($payload['form'] ?? ''));
        $data = $payload['data'] ?? [];

        if ($form === '' || !preg_match('/^[a-zA-Z0-9_-]{1,64}$/', $form)) {
            return ['status' => 400, 'success' => false, 'error' => 'Missing or invalid form name.'];
        }

        if (!is_array($data) || !count($data)) {
            return ['status' => 400, 'success' => false, 'error' => 'Missing form data.'];
        }

        // Honeypot: a hidden input real users never fill in. Dropped silently so
        // the bot believes it succeeded.
        $honeypot = $payload[self::HONEYPOT_FIELD] ?? ($data[self::HONEYPOT_FIELD] ?? '');

        if (is_string($honeypot) && trim($honeypot) !== '') {
            return ['status' => 200, 'success' => true];
        }

        unset($data[self::HONEYPOT_FIELD]);

        $this->ensureModels();

        $settings = $this->settings($form);
        $ip       = $this->clientIp();

        $throttle   = (int)$settings['throttle'];
        $dailyLimit = (int)$settings['dailyLimit'];

        // Both limits disabled is an explicit operator decision: the memory
        // backend is not consulted at all, so availability beats abuse control.
        if ($throttle > 0 || $dailyLimit > 0) {

            $check = $this->checkRateLimit($ip, $form, $throttle, $dailyLimit);

            if (!$check['ok']) {

                // The backend could not be reached: this is "cannot decide",
                // not "too many requests". Fail closed with 503 + Retry-After
                // so clients retry honestly instead of learning the limit was off.
                if (!empty($check['unavailable'])) {
                    return [
                        'status'     => 503,
                        'success'    => false,
                        'error'      => $check['error'],
                        'retryAfter' => self::RATE_LIMIT_RETRY_AFTER,
                    ];
                }

                return ['status' => 429, 'success' => false, 'error' => $check['error']];
            }
        }

        $entry = [
            'form'      => $form,
            'data'      => $this->sanitize($data),
            'origin'    => $_SERVER['HTTP_ORIGIN'] ?? ($_SERVER['HTTP_REFERER'] ?? null),
            'ip'        => $ip,
            'userAgent' => $_SERVER['HTTP_USER_AGENT'] ?? null,
            'read'      => false,
            // 1 = published. Without it saveItem defaults to 0, which the
            // Content UI paints red as "unpublished" - wrong for a received lead.
            '_state'    => 1,
        ];

        // saveItem fills _id/_created/_modified/_by and fires the content events.
        $saved = $this->app->module('content')->saveItem(self::MODEL_SUBMISSIONS, $entry, ['user' => null]);

        $this->dispatch($settings, $saved ?: $entry);

        return ['status' => 200, 'success' => true];
    }

    /**
     * Accepts a JSON body, falling back to form-encoded POSTs so an unmodified
     * <form method="post"> also works.
     */
    protected function readPayload(): array {

        $raw = file_get_contents('php://input');

        if (is_string($raw) && trim($raw) !== '') {

            $json = json_decode($raw, true);

            if (json_last_error() === JSON_ERROR_NONE && is_array($json)) {

                // Tolerate a flat body ({form, nombre, tel, ...}) as well as the
                // documented {form, data: {...}}.
                if (!isset($json['data'])) {
                    $form = $json['form'] ?? '';
                    unset($json['form']);
                    return ['form' => $form, 'data' => $json];
                }

                return $json;
            }
        }

        $post = $_POST;
        $form = $post['form'] ?? '';
        unset($post['form']);

        return [
            'form' => $form,
            'data' => $post,
            self::HONEYPOT_FIELD => $_POST[self::HONEYPOT_FIELD] ?? '',
        ];
    }

    /**
     * Trims and strips values. Nested arrays are kept one level deep so the
     * CSV export and the screen columns stay predictable.
     */
    protected function sanitize(array $data, int $depth = 0): array {

        $clean = [];

        foreach ($data as $key => $value) {

            $key = substr(preg_replace('/[^a-zA-Z0-9_\-\.]/', '', (string)$key), 0, 64);

            if ($key === '') continue;

            if (is_array($value)) {
                $clean[$key] = $depth < 2 ? $this->sanitize($value, $depth + 1) : null;
                continue;
            }

            if (is_bool($value) || is_null($value) || is_numeric($value)) {
                $clean[$key] = $value;
                continue;
            }

            $clean[$key] = mb_substr(trim(strip_tags((string)$value)), 0, 5000);
        }

        return $clean;
    }

    // ----------------------------------------------------------- anti-spam

    /**
     * Throttle + daily cap per IP and form, kept in $app->memory (Redis).
     *
     * Expiry is encoded in the stored value instead of relying on TTL support,
     * so behaviour is identical on every memory backend.
     *
     * Returns ['ok' => true], ['ok' => false, 'error' => ...] when a limit was
     * hit, or ['ok' => false, 'unavailable' => true] when the backend itself
     * failed - callers treat that as "cannot decide", not as "limit reached".
     */
    protected function checkRateLimit(string $ip, string $form, int $throttle, int $dailyLimit): array {

        if ($throttle <= 0 && $dailyLimit <= 0) {
            return ['ok' => true];
        }

        try {

            $now    = time();
            $bucket = md5($ip.'|'.$form);

            if ($throttle > 0) {

                $last = (int)$this->memoryGet("forms.last.{$bucket}", 0);

                if ($last && ($now - $last) < $throttle) {
                    return ['ok' => false, 'error' => 'Too many requests. Please wait a few seconds and try again.'];
                }

                $this->memorySet("forms.last.{$bucket}", $now);
            }

            if ($dailyLimit > 0) {

                $dayKey = 'forms.day.'.$bucket.'.'.date('Ymd', $now);
                $count  = (int)$this->memoryGet($dayKey, 0);

                if ($count >= $dailyLimit) {
                    return ['ok' => false, 'error' => 'Daily submission limit reached for this address.'];
                }

                $this->memorySet($dayKey, $count + 1);
            }

            return ['ok' => true];

        } catch (\Throwable $e) {

            // Fail closed: without the counters an outage would mean unlimited
            // submissions exactly while the system is degraded.
            $this->log('rate limit unavailable: '.$e->getMessage());

            return [
                'ok'          => false,
                'unavailable' => true,
                'error'       => 'The form service is temporarily unavailable. Please try again shortly.',
            ];
        }
    }

    /**
     * Memory access that propagates backend failures instead of swallowing
     * them: the rate limiter must be able to tell "limit reached" apart from
     * "backend down". Callers that only need best-effort caching wrap this in
     * their own try/catch.
     *
     * @throws \Throwable
     */
    protected function memoryGet(string $key, mixed $default = null): mixed {

        if (!$this->app->memory) {
            throw new \RuntimeException('No memory backend configured.');
        }

        return $this->app->memory->get($key, $default);
    }

    /**
     * @throws \Throwable
     */
    protected function memorySet(string $key, mixed $value): void {

        if (!$this->app->memory) {
            throw new \RuntimeException('No memory backend configured.');
        }

        $this->app->memory->set($key, $value);
    }

    // -------------------------------------------------------- notification

    /**
     * Fires the configured notifications for a new submission: e-mail through
     * $app->mailer and/or an HTTP webhook.
     */
    public function dispatch(array $settings, array $entry): void {
        $this->sendMail($settings, $entry);
        $this->sendWebhook($settings, $entry);
    }

    protected function sendMail(array $settings, array $entry): void {

        $to = $settings['notify'] ?? [];

        if (is_string($to)) {
            $to = array_filter(array_map('trim', explode(',', $to)));
        }

        if (!is_array($to) || !count($to)) return;

        $subject = $settings['subject'] ?: 'New submission: '.$entry['form'];
        $rows    = '';

        foreach ($entry['data'] as $key => $value) {
            $rows .= '<tr><td style="padding:4px 12px 4px 0;vertical-align:top;"><strong>'
                  .htmlspecialchars((string)$key).'</strong></td><td style="padding:4px 0;">'
                  .nl2br(htmlspecialchars(is_array($value) ? json_encode($value) : (string)$value))
                  .'</td></tr>';
        }

        $body = '<p>New submission for form <strong>'.htmlspecialchars($entry['form']).'</strong></p>'
              .'<table>'.$rows.'</table>'
              .'<p style="color:#888;font-size:12px;">'
              .date('Y-m-d H:i', $entry['_created'] ?? time()).' &middot; '
              .htmlspecialchars((string)($entry['origin'] ?? '')).' &middot; '
              .htmlspecialchars((string)($entry['ip'] ?? '')).'</p>';

        try {
            $this->app->mailer->mail($to, $subject, $body);
        } catch (\Throwable $e) {
            // A broken SMTP config must never lose a submission: it is already
            // stored by the time we get here.
            $this->log('mail failed: '.$e->getMessage());
        }
    }

    /**
     * POSTs the submission as JSON to the configured webhook URL.
     *
     * Synchronous with a short timeout: predictable, and a slow endpoint delays
     * the response by at most 5s rather than dropping the lead. When a secret is
     * set the body is signed as X-Forms-Signature: sha256=<hmac>.
     */
    protected function sendWebhook(array $settings, array $entry): void {

        $url = trim((string)($settings['webhook'] ?? ''));

        if ($url === '' || !filter_var($url, FILTER_VALIDATE_URL)) return;

        $body = json_encode([
            'event'     => 'submission.created',
            'form'      => $entry['form'],
            'data'      => $entry['data'],
            'origin'    => $entry['origin'] ?? null,
            'ip'        => $entry['ip'] ?? null,
            'userAgent' => $entry['userAgent'] ?? null,
            '_id'       => $entry['_id'] ?? null,
            '_created'  => $entry['_created'] ?? time(),
        ]);

        $headers = ['Content-Type: application/json'];

        if (!empty($settings['webhookSecret'])) {
            $headers[] = 'X-Forms-Signature: sha256='.hash_hmac('sha256', $body, $settings['webhookSecret']);
        }

        try {

            $ch = curl_init($url);

            curl_setopt_array($ch, [
                CURLOPT_POST           => true,
                CURLOPT_POSTFIELDS     => $body,
                CURLOPT_HTTPHEADER     => $headers,
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT        => 5,
                CURLOPT_CONNECTTIMEOUT => 3,
                CURLOPT_FOLLOWLOCATION => false,
            ]);

            curl_exec($ch);

            $status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $error  = curl_error($ch);

            curl_close($ch);

            if ($error || $status >= 400) {
                $this->log("webhook {$url} failed: ".($error ?: "HTTP {$status}"));
            }

        } catch (\Throwable $e) {
            $this->log('webhook failed: '.$e->getMessage());
        }
    }

    protected function log(string $message): void {
        error_log('[forms] '.$message);
    }

    // ------------------------------------------------------------- listing

    /**
     * Paginated listing for one form, newest first.
     */
    public function listSubmissions(?string $form = null, int $page = 1, int $limit = 25): array {

        $this->ensureModels();

        $page   = max(1, $page);
        $limit  = max(1, min(100, $limit));
        $filter = [];

        if ($form) $filter['form'] = $form;

        $content = $this->app->module('content');
        $total   = $content->count(self::MODEL_SUBMISSIONS, $filter);

        $items = $content->items(self::MODEL_SUBMISSIONS, [
            'filter' => $filter,
            'sort'   => ['_created' => -1],
            'limit'  => $limit,
            'skip'   => ($page - 1) * $limit,
        ]);

        return [
            'items'   => $items,
            'columns' => $this->columnsFor($form),
            'total'   => $total,
            'page'    => $page,
            'pages'   => (int)ceil($total / $limit),
            'limit'   => $limit,
        ];
    }

    /**
     * CSV for one form: one column per data field, plus date, origin and IP.
     */
    public function exportCsv(?string $form = null): string {

        $this->ensureModels();

        $options = ['sort' => ['_created' => -1], 'limit' => 10000];

        if ($form) $options['filter'] = ['form' => $form];

        $items  = $this->app->module('content')->items(self::MODEL_SUBMISSIONS, $options);
        $fields = [];

        foreach ($items as $item) {
            foreach (array_keys($item['data'] ?? []) as $key) {
                $fields[$key] = true;
            }
        }

        $fields = array_keys($fields);
        $header = array_merge(['date', 'form'], $fields, ['origin', 'ip']);

        $out = fopen('php://temp', 'r+');

        // BOM so Excel opens UTF-8 accents correctly.
        fwrite($out, "\xEF\xBB\xBF");

        // $escape must be passed explicitly: its default changes in PHP 8.4+.
        fputcsv($out, $header, ',', '"', '');

        foreach ($items as $item) {

            $row = [
                date('Y-m-d H:i:s', (int)($item['_created'] ?? 0)),
                $item['form'] ?? '',
            ];

            foreach ($fields as $field) {
                $value = $item['data'][$field] ?? '';
                $row[] = is_array($value) ? json_encode($value) : (string)$value;
            }

            $row[] = $item['origin'] ?? '';
            $row[] = $item['ip'] ?? '';

            fputcsv($out, $row, ',', '"', '');
        }

        rewind($out);
        $csv = stream_get_contents($out);
        fclose($out);

        return $csv;
    }

    public function remove(string $id): bool {

        $this->ensureModels();

        $content = $this->app->module('content');

        if (!$content->item(self::MODEL_SUBMISSIONS, ['_id' => $id])) {
            return false;
        }

        $content->remove(self::MODEL_SUBMISSIONS, ['_id' => $id]);

        return true;
    }

    /**
     * Marks a submission read or unread.
     */
    public function markRead(string $id, bool $read = true): bool {

        $this->ensureModels();

        $content = $this->app->module('content');

        if (!$content->item(self::MODEL_SUBMISSIONS, ['_id' => $id])) {
            return false;
        }

        $content->saveItem(self::MODEL_SUBMISSIONS, ['_id' => $id, 'read' => $read], ['user' => null]);

        return true;
    }

    /**
     * Client IP for the rate limiter, correct behind a reverse proxy and not
     * spoofable by the client.
     *
     * config/forms/trustedProxies (integer, default 0) is the number of
     * reverse-proxy hops in front of the CMS. With N trusted hops the client
     * address is the entry N positions from the RIGHT of X-Forwarded-For:
     * everything further left was appended by the proxies themselves, but the
     * rightmost entries are what those trusted proxies observed. The leftmost
     * entry - which a client fully controls by sending its own header - is
     * never trusted.
     *
     * Fewer X-Forwarded-For entries than configured hops means the topology
     * does not match the configuration; fall back to REMOTE_ADDR.
     */
    public function clientIp(): string {

        $hops = $this->trustedProxies();

        if ($hops > 0 && !empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {

            $entries = array_map('trim', explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']));

            if (count($entries) >= $hops) {
                $candidate = $entries[count($entries) - $hops];
                if ($candidate !== '') {
                    return $candidate;
                }
            }
        }

        return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
    }

    /**
     * Resolves the number of trusted proxy hops from the configuration.
     *
     * The old boolean `trustProxy` is still honoured as an alias for
     * `trustedProxies: 1` - it took the LEFTMOST X-Forwarded-For entry, which
     * clients could forge, so it logs a deprecation notice.
     */
    protected function trustedProxies(): int {

        $configured = $this->app->retrieve('config/forms/trustedProxies', null);

        if ($configured !== null) {
            return max(0, (int)$configured);
        }

        if ($this->app->retrieve('config/forms/trustProxy', false)) {
            static $deprecated = false;
            if (!$deprecated) {
                $deprecated = true;
                $this->log("config/forms/trustProxy is deprecated and will be removed; replace it with 'trustedProxies' => 1.");
            }
            return 1;
        }

        return 0;
    }
}
