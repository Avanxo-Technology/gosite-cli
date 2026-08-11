<?php

namespace Replica\Model;

/**
 * A remote instance to replicate with.
 *
 * Exists so the secret is handled in exactly one place: the api key is only
 * reachable through apiKey(), while toArray() masks it by default. Anything
 * that leaves the server - admin API responses, the log, CLI output - goes
 * through the masked form, so a target cannot leak its key by accident.
 */
final class Target implements \JsonSerializable {

    const DEFAULT_TIMEOUT = 30;

    public readonly ?string $id;
    public readonly string $name;
    public readonly string $baseUrl;
    public readonly bool $enabled;
    public readonly bool $syncModels;
    public readonly bool $syncAssets;
    /** @var string[] content model names (collections and singletons); empty means every content model */
    public readonly array $models;
    public readonly int $timeout;
    public readonly ?array $lastRun;
    public readonly int $created;
    public readonly int $modified;

    private string $apiKey;

    private function __construct(array $data) {

        $this->id         = isset($data['_id']) ? (string)$data['_id'] : null;
        $this->name       = trim((string)($data['name'] ?? ''));
        $this->baseUrl    = rtrim(trim((string)($data['base_url'] ?? '')), '/');
        $this->apiKey     = (string)($data['api_key'] ?? '');
        $this->enabled    = (bool)($data['enabled'] ?? true);
        $this->syncModels = (bool)($data['syncModels'] ?? false);
        $this->syncAssets = (bool)($data['syncAssets'] ?? true);
        $this->timeout    = ((int)($data['timeout'] ?? 0)) ?: self::DEFAULT_TIMEOUT;
        $this->lastRun    = isset($data['lastRun']) && is_array($data['lastRun']) ? $data['lastRun'] : null;
        $this->created    = (int)($data['_created'] ?? time());
        $this->modified   = (int)($data['_modified'] ?? time());

        $models = (array)($data['models'] ?? []);
        $models = array_values(array_unique(array_filter(array_map(
            fn($m) => trim((string)$m),
            $models
        ))));

        sort($models);

        $this->models = $models;
    }

    public static function fromArray(array $data): self {
        return new self($data);
    }

    /**
     * Builds a target from user input, merging over the stored document so an
     * edit cannot blank fields it did not send.
     *
     * An empty api_key means "keep the current one": the UI is never given the
     * real key, so it has nothing to echo back.
     */
    public static function fromInput(array $input, ?self $current = null): self {

        $data = $current ? $current->toStorage() : [];

        foreach (['name', 'base_url', 'enabled', 'syncModels', 'syncAssets', 'models', 'timeout'] as $key) {
            if (array_key_exists($key, $input)) {
                $data[$key] = $input[$key];
            }
        }

        if (isset($input['api_key']) && $input['api_key'] !== '') {
            $data['api_key'] = $input['api_key'];
        }

        if ($current) {
            $data['_id'] = $current->id;
        } elseif (isset($input['_id']) && $input['_id']) {
            $data['_id'] = $input['_id'];
        }

        return new self($data);
    }

    /**
     * @throws \Exception with a message meant for the operator
     */
    public function validate(): void {

        if ($this->name === '') {
            throw new \Exception('Target name is required.');
        }

        if (!filter_var($this->baseUrl, FILTER_VALIDATE_URL)) {
            throw new \Exception('A valid base URL is required, for example https://cms.staging.example.com');
        }

        if (!preg_match('#^https?://#i', $this->baseUrl)) {
            throw new \Exception('The base URL must start with http:// or https://');
        }

        if ($this->apiKey === '') {
            throw new \Exception('An API key issued by the remote instance is required.');
        }
    }

    // ------------------------------------------------------------- secrets

    public function apiKey(): string {
        return $this->apiKey;
    }

    public function hasKey(): bool {
        return $this->apiKey !== '';
    }

    /**
     * What the UI and the CLI are allowed to show.
     */
    public function maskedKey(): string {
        return $this->apiKey === '' ? '' : str_repeat('*', 8).substr($this->apiKey, -4);
    }

    // ---------------------------------------------------------------- state

    public function withEnabled(bool $enabled): self {

        $data = $this->toStorage();
        $data['enabled'] = $enabled;

        return new self($data);
    }

    public function toggled(): self {
        return $this->withEnabled(!$this->enabled);
    }

    public function withLastRun(array $lastRun): self {

        $data = $this->toStorage();
        $data['lastRun'] = $lastRun;

        return new self($data);
    }

    /**
     * Content models an operation covers: an explicit override, else the
     * target's own selection, else everything the source offers.
     *
     * @param string[] $available
     * @return string[]
     */
    public function scope(?string $only = null, array $available = []): array {

        if ($only) {
            return [$only];
        }

        return count($this->models) ? $this->models : $available;
    }

    public function syncsEverything(): bool {
        return !count($this->models);
    }

    public function scopeLabel(): string {
        return $this->syncsEverything() ? 'all content models' : implode(', ', $this->models);
    }

    // --------------------------------------------------------- serialisation

    /**
     * The document to persist - the only representation carrying the real key.
     */
    public function toStorage(): array {

        $data = [
            'name'       => $this->name,
            'base_url'   => $this->baseUrl,
            'api_key'    => $this->apiKey,
            'enabled'    => $this->enabled,
            'syncModels' => $this->syncModels,
            'syncAssets' => $this->syncAssets,
            'models'     => $this->models,
            'timeout'    => $this->timeout,
            'lastRun'    => $this->lastRun,
            '_created'   => $this->created,
            '_modified'  => $this->modified,
        ];

        if ($this->id !== null) {
            $data['_id'] = $this->id;
        }

        return $data;
    }

    /**
     * Safe representation. $reveal is opt-in and only used by code that is
     * about to talk to the remote.
     */
    public function toArray(bool $reveal = false): array {

        $data = $this->toStorage();

        $data['api_key'] = $reveal ? $this->apiKey : $this->maskedKey();
        $data['hasKey']  = $this->hasKey();

        return $data;
    }

    /**
     * json_encode() of a Target can never expose the key.
     */
    public function jsonSerialize(): array {
        return $this->toArray();
    }

    public function __toString(): string {
        return $this->name;
    }
}
