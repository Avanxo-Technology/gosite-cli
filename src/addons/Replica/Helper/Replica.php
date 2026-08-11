<?php

namespace Replica\Helper;

use Replica\Model\Target;

/**
 * Targets, replication operations and the activity log.
 *
 * Local item writes deliberately bypass content->saveItem(): saveItem stamps
 * _modified = time() on every write, which would destroy the very field merge
 * mode compares. Replication must preserve the source timestamps verbatim.
 * See saveLocalItem() for why dataStorage->save() is not usable either.
 */
class Replica extends \Lime\Helper {

    const VERSION = '1.0.0';

    const MODE_MIRROR = 'mirror';
    const MODE_MERGE  = 'merge';

    // ------------------------------------------------------------- targets

    /**
     * @return Target[]
     */
    public function targets(): array {

        $docs = $this->app->dataStorage->find(REPLICA_TARGETS, [
            'sort' => ['name' => 1],
        ])->toArray();

        return array_map(fn($doc) => Target::fromArray($doc), $docs);
    }

    public function target(string $id): ?Target {

        $doc = $this->app->dataStorage->findOne(REPLICA_TARGETS, ['_id' => $id]);

        return $doc ? Target::fromArray($doc) : null;
    }

    /**
     * Resolves a target by _id or by name, so the CLI can take a readable name.
     */
    public function resolveTarget(string $idOrName): ?Target {

        if ($target = $this->target($idOrName)) {
            return $target;
        }

        $doc = $this->app->dataStorage->findOne(REPLICA_TARGETS, ['name' => $idOrName]);

        return $doc ? Target::fromArray($doc) : null;
    }

    /**
     * Creates or updates a target from operator input.
     *
     * @throws \Exception when the input does not describe a usable target
     */
    public function saveTarget(array $input): Target {

        $current = isset($input['_id']) && $input['_id'] ? $this->target((string)$input['_id']) : null;

        if (isset($input['_id']) && $input['_id'] && !$current) {
            throw new \Exception('Target not found.');
        }

        $target = Target::fromInput($input, $current);
        $target->validate();

        /*
         * Names must be unique: resolveTarget() accepts a name so the CLI can
         * take a readable one, and with duplicates it would silently pick
         * whichever came first - the classic symptom being a run that uses a
         * stale key or URL from a target the operator thought they replaced.
         */
        $clash = $this->app->dataStorage->findOne(REPLICA_TARGETS, ['name' => $target->name]);

        if ($clash && ($clash['_id'] ?? null) !== $target->id) {
            throw new \Exception("A target named '{$target->name}' already exists.");
        }

        return $this->persist($target);
    }

    /**
     * Enables or disables a target. Passing null flips the current state, which
     * is what the UI toggle and the bare CLI command do.
     */
    public function toggleTarget(string $idOrName, ?bool $enabled = null): ?Target {

        $target = $this->resolveTarget($idOrName);

        if (!$target) return null;

        $updated = $enabled === null ? $target->toggled() : $target->withEnabled($enabled);

        // Nothing to write when the state already matches.
        if ($updated->enabled === $target->enabled) {
            return $target;
        }

        return $this->persist($updated);
    }

    public function removeTarget(string $id): bool {

        if (!$this->app->dataStorage->findOne(REPLICA_TARGETS, ['_id' => $id])) {
            return false;
        }

        $this->app->dataStorage->remove(REPLICA_TARGETS, ['_id' => $id]);

        // Its id mappings mean nothing without it.
        $this->clearIdMap($id);

        return true;
    }

    /**
     * Writes a target and returns it with the storage-assigned _id.
     */
    protected function persist(Target $target): Target {

        $doc = $target->toStorage();
        $doc['_modified'] = time();

        $this->app->dataStorage->save(REPLICA_TARGETS, $doc);

        return Target::fromArray($doc);
    }

    public function client(Target $target): Client {
        return $this->app->helper('replica.client')->forTarget($target);
    }

    // -------------------------------------------------------------- id map

    /*
     * A plain Cockpit cannot be told which _id to use when creating an entry
     * (its POST answers 200 but writes nothing for an unknown _id, so Replica
     * has to let the remote mint one). Remembering the pair it hands back turns
     * an otherwise one-shot seeding into a repeatable sync: the next push finds
     * the mapping and updates the right entry instead of duplicating it, and a
     * pull can translate the ids back.
     *
     * Peer targets keep our ids verbatim and never touch any of this.
     */

    /**
     * @return array{forward: array<string,string>, reverse: array<string,string>}
     */
    public function idMap(string $targetId, string $model): array {

        $forward = [];
        $reverse = [];

        $docs = $this->app->dataStorage->find(REPLICA_IDMAP, [
            'filter' => ['target' => $targetId, 'model' => $model],
        ])->toArray();

        foreach ($docs as $doc) {

            if (empty($doc['sourceId']) || empty($doc['remoteId'])) continue;

            $forward[$doc['sourceId']] = $doc['remoteId'];
            $reverse[$doc['remoteId']] = $doc['sourceId'];
        }

        return ['forward' => $forward, 'reverse' => $reverse];
    }

    /**
     * @param array<string,string> $pairs sourceId => remoteId
     */
    public function rememberIds(string $targetId, string $model, array $pairs): void {

        foreach ($pairs as $sourceId => $remoteId) {

            if (!$sourceId || !$remoteId) continue;

            $filter = ['target' => $targetId, 'model' => $model, 'sourceId' => (string)$sourceId];

            // Rewrite rather than update: dataStorage->save() cannot upsert.
            $this->app->dataStorage->remove(REPLICA_IDMAP, $filter);

            $doc = $filter + [
                'remoteId'  => (string)$remoteId,
                '_created'  => time(),
            ];

            $this->app->dataStorage->insert(REPLICA_IDMAP, $doc);
        }
    }

    /**
     * Drops mappings whose remote entry no longer exists, so the next run
     * recreates it instead of writing into a void.
     *
     * @param string[] $sourceIds
     */
    public function forgetIds(string $targetId, string $model, array $sourceIds): void {

        foreach ($sourceIds as $sourceId) {
            $this->app->dataStorage->remove(REPLICA_IDMAP, [
                'target'   => $targetId,
                'model'    => $model,
                'sourceId' => (string)$sourceId,
            ]);
        }
    }

    /**
     * Rewrites incoming ids from a core remote into our own.
     *
     * A remote entry we previously seeded comes back under the id the remote
     * minted; mapping it back means it updates the entry it came from instead
     * of landing beside it as a duplicate. Genuinely new remote entries keep
     * their id and are recorded in $learned, so a later push updates them
     * rather than creating a second copy over there.
     *
     * @param array<string,string> $learned filled with sourceId => remoteId
     */
    public function translateIncoming(string $targetId, string $model, array $items, array &$learned = []): array {

        $map     = $this->idMap($targetId, $model);
        $reverse = $map['reverse'];
        $known   = $map['forward'];
        $out     = [];

        foreach ($items as $item) {

            $remoteId = $item['_id'] ?? null;

            if (!$remoteId) {
                $out[] = $item;
                continue;
            }

            if (isset($reverse[$remoteId])) {
                $item['_id'] = $reverse[$remoteId];
            } elseif (!isset($known[$remoteId])) {
                // New over there, and its id is free here: adopt it and record
                // the identity mapping so the pairing survives the next push.
                $learned[$remoteId] = $remoteId;
            }

            $out[] = $item;
        }

        return $out;
    }

    public function countIdMap(string $targetId): int {
        return $this->app->dataStorage->count(REPLICA_IDMAP, ['target' => $targetId]);
    }

    public function clearIdMap(string $targetId): void {
        $this->app->dataStorage->remove(REPLICA_IDMAP, ['target' => $targetId]);
    }

    // -------------------------------------------------------------- local

    /**
     * Local content models that replication can move: collections and
     * singletons. There is no helper('content')->collections() in the core;
     * models() is the real API, and singletons carry type 'singleton'.
     */
    public function localCollections(): array {

        $models = $this->app->module('content')->models();
        $names  = [];

        foreach ($models as $name => $model) {
            if (in_array($model['type'] ?? '', ['collection', 'singleton'])) {
                $names[] = $name;
            }
        }

        sort($names);

        return $names;
    }

    /**
     * Content models with their type, for the admin picker. Sorted by type
     * (collections first), then by name.
     *
     * @return array<int,array{name:string,type:string}>
     */
    public function localModels(): array {

        $models = $this->app->module('content')->models();
        $out    = [];

        foreach ($models as $name => $model) {
            if (in_array($model['type'] ?? '', ['collection', 'singleton'])) {
                $out[] = ['name' => $name, 'type' => (string)($model['type'] ?? '')];
            }
        }

        usort($out, function($a, $b) {
            $order = ['collection' => 0, 'singleton' => 1];
            $ta    = $order[$a['type']] ?? 2;
            $tb    = $order[$b['type']] ?? 2;
            return $ta === $tb ? strcmp($a['name'], $b['name']) : $ta <=> $tb;
        });

        return $out;
    }

    public function localModel(string $name): ?array {
        return $this->app->module('content')->model($name) ?: null;
    }

    public function localType(string $name): string {
        return (string)($this->localModel($name)['type'] ?? '');
    }

    public function localItems(string $model): array {

        // A singleton lives in content/singletons, keyed by its _model field;
        // a collection (or tree) is a collection keyed by the model name.
        if ($this->localType($model) === 'singleton') {
            $doc = $this->app->dataStorage->findOne('content/singletons', ['_model' => $model]);
            return $doc ? [$doc] : [];
        }

        return $this->app->dataStorage->find("content/collections/{$model}", [
            'sort' => ['_created' => 1],
        ])->toArray();
    }

    /**
     * Writes an item locally with its _id and timestamps untouched.
     *
     * Not dataStorage->save(): the driver's save() takes a third $create flag
     * for upsert, but MongoHybrid\Client::save() does not forward it, so saving
     * a document whose _id does not exist locally yet updates zero rows and
     * silently writes nothing.
     *
     * An existing entry is removed and reinserted rather than updated, because
     * update() applies a $set (a merge) and would leave behind fields the
     * source has since deleted - which mirror mode must not do. MongoLite and
     * MongoDB both preserve an explicit _id on insert.
     */
    public function saveLocalItem(string $model, array $item, bool $exists = false): void {

        // Singletons share one table (content/singletons) with _model as the
        // discriminator; collections and trees get their own collection.
        $collection = $this->localType($model) === 'singleton'
            ? 'content/singletons'
            : "content/collections/{$model}";

        if ($collection === 'content/singletons') {
            $item['_model'] = $model;
        }

        if ($exists && isset($item['_id'])) {
            $this->app->dataStorage->remove($collection, ['_id' => $item['_id']]);
        }

        $this->app->dataStorage->insert($collection, $item);
    }

    public function localItemsById(string $model): array {

        $byId = [];

        foreach ($this->localItems($model) as $item) {
            if (isset($item['_id'])) $byId[$item['_id']] = $item;
        }

        return $byId;
    }

    // -------------------------------------------------------------- assets

    /**
     * Local asset metadata (the 'assets' dataStorage collection) and folder
     * definitions ('assets/folders'). Files live under uploads://{path}.
     *
     * The collections may not exist yet on an instance that never uploaded
     * anything, so reads are guarded.
     */
    public function localAssets(): array {

        try {
            return $this->app->dataStorage->find('assets', [
                'sort' => ['_created' => 1],
            ])->toArray();
        } catch (\Throwable $e) {
            return [];
        }
    }

    public function localFolders(): array {

        try {
            return $this->app->dataStorage->find('assets/folders', [
                'sort' => ['_created' => 1],
            ])->toArray();
        } catch (\Throwable $e) {
            return [];
        }
    }

    public function localAssetsById(): array {

        $byId = [];

        foreach ($this->localAssets() as $asset) {
            if (isset($asset['_id'])) $byId[$asset['_id']] = $asset;
        }

        return $byId;
    }

    public function localFoldersById(): array {

        $byId = [];

        foreach ($this->localFolders() as $folder) {
            if (isset($folder['_id'])) $byId[$folder['_id']] = $folder;
        }

        return $byId;
    }

    /**
     * Whether the file behind an asset exists in the local uploads store.
     */
    public function assetFileExists(array $asset): bool {

        $path = trim((string)($asset['path'] ?? ''), '/');

        if (!$path) return false;

        try {
            return $this->app->fileStorage->fileExists("uploads://{$path}");
        } catch (\Throwable $e) {
            return false;
        }
    }

    /**
     * Adds base64 file data to an asset so it can travel over the wire.
     */
    public function attachAssetData(array $asset): array {

        $path = trim((string)($asset['path'] ?? ''), '/');

        if ($path) {

            try {
                if ($this->app->fileStorage->fileExists("uploads://{$path}")) {
                    $asset['fileData'] = base64_encode($this->app->fileStorage->read("uploads://{$path}"));
                }
            } catch (\Throwable $e) {
                // leave fileData unset; the receiver skips the file write
            }
        }

        return $asset;
    }

    /**
     * Writes an asset's metadata with _id and timestamps untouched, and saves
     * its folder entry. Same remove-and-reinsert rule as saveLocalItem().
     */
    public function saveAsset(array $asset, bool $exists = false): void {

        if ($exists && isset($asset['_id'])) {
            $this->app->dataStorage->remove('assets', ['_id' => $asset['_id']]);
        }

        $this->app->dataStorage->insert('assets', $asset);
    }

    public function saveAssetFolder(array $folder, bool $exists = false): void {

        if ($exists && isset($folder['_id'])) {
            $this->app->dataStorage->remove('assets/folders', ['_id' => $folder['_id']]);
        }

        $this->app->dataStorage->insert('assets/folders', $folder);
    }

    /**
     * Writes incoming assets and folders locally: files into uploads://{path},
     * metadata into the 'assets' collection, mirroring what saveLocalItem does
     * for entries.
     */
    public function applyAssets(array $assets, array $folders, string $mode, bool $dryRun = false): array {

        $result = ['created' => 0, 'updated' => 0, 'skipped' => 0, 'errors' => 0, 'messages' => []];

        $currentAssets  = $this->localAssetsById();
        $currentFolders = $this->localFoldersById();

        foreach ($folders as $folder) {

            $id = $folder['_id'] ?? null;

            if (!$id) {
                $result['errors']++;
                $result['messages'][] = 'error: incoming folder without _id';
                continue;
            }

            $existing = $currentFolders[$id] ?? null;

            if ($existing && $mode === self::MODE_MERGE
                && (int)($existing['_modified'] ?? 0) > (int)($folder['_modified'] ?? 0)) {
                $result['skipped']++;
                continue;
            }

            if (!$dryRun) {
                try {
                    $this->saveAssetFolder($folder, (bool)$existing);
                } catch (\Throwable $e) {
                    $result['errors']++;
                    $result['messages'][] = "error folder {$id}: ".$e->getMessage();
                    continue;
                }
            }

            $result[$existing ? 'updated' : 'created']++;
        }

        foreach ($assets as $asset) {

            $id = $asset['_id'] ?? null;

            if (!$id) {
                $result['errors']++;
                $result['messages'][] = 'error: incoming asset without _id';
                continue;
            }

            $existing = $currentAssets[$id] ?? null;

            if ($existing && $mode === self::MODE_MERGE
                && (int)($existing['_modified'] ?? 0) > (int)($asset['_modified'] ?? 0)) {
                $result['skipped']++;
                $result['messages'][] = "skip asset {$id}: destination is newer";
                continue;
            }

            $path = trim((string)($asset['path'] ?? ''), '/');
            $data = $asset['fileData'] ?? null;
            unset($asset['fileData']);

            if (!$dryRun) {

                try {

                    if ($path && $data !== null && $data !== '') {
                        $this->app->fileStorage->write("uploads://{$path}", base64_decode((string)$data));
                    }

                    $this->saveAsset($asset, (bool)$existing);

                } catch (\Throwable $e) {
                    $result['errors']++;
                    $result['messages'][] = "error asset {$id}: ".$e->getMessage();
                    continue;
                }
            }

            $result[$existing ? 'updated' : 'created']++;
            $result['messages'][] = ($dryRun ? 'would ' : '').($existing ? 'update asset ' : 'create asset ').$id;
        }

        return $result;
    }

    /**
     * Dry-run planner for an asset push: what would the remote do.
     */
    protected function planAssets(array $assets, array $folders, array $remote, string $mode): array {

        $result = ['created' => 0, 'updated' => 0, 'skipped' => 0, 'errors' => 0, 'messages' => []];

        $remoteFolders = [];
        $remoteAssets  = [];

        foreach (($remote['folders'] ?? []) as $f) {
            if (isset($f['_id'])) $remoteFolders[$f['_id']] = $f;
        }

        foreach (($remote['assets'] ?? []) as $a) {
            if (isset($a['_id'])) $remoteAssets[$a['_id']] = $a;
        }

        foreach ($folders as $folder) {

            $id = $folder['_id'] ?? null;
            if (!$id) continue;

            $existing = $remoteFolders[$id] ?? null;

            if ($existing && $mode === self::MODE_MERGE
                && (int)($existing['_modified'] ?? 0) > (int)($folder['_modified'] ?? 0)) {
                $result['skipped']++;
                continue;
            }

            $result[$existing ? 'updated' : 'created']++;
        }

        foreach ($assets as $asset) {

            $id = $asset['_id'] ?? null;

            if (!$id) {
                $result['errors']++;
                continue;
            }

            if (!$this->assetFileExists($asset)) {
                $result['errors']++;
                $result['messages'][] = "error asset {$id}: no local file at {$asset['path']}";
                continue;
            }

            $existing = $remoteAssets[$id] ?? null;

            if ($existing && $mode === self::MODE_MERGE
                && (int)($existing['_modified'] ?? 0) > (int)($asset['_modified'] ?? 0)) {
                $result['skipped']++;
                $result['messages'][] = "skip asset {$id}: destination is newer";
                continue;
            }

            $result[$existing ? 'updated' : 'created']++;
            $result['messages'][] = 'would '.($existing ? 'update asset ' : 'create asset ').$id;
        }

        return $result;
    }

    // --------------------------------------------------------- operations

    /**
     * PUSH - local content becomes the source, the target the destination.
     *
     * @return array the log document that was recorded
     */
    public function push(Target $target, array $options = []): array {

        $mode    = $this->mode($options['mode'] ?? self::MODE_MERGE);
        $dryRun  = (bool)($options['dryRun'] ?? false);
        $verbose = (bool)($options['verbose'] ?? false);

        $client  = $this->client($target);
        $result  = $this->newResult('push', $target, $mode, $dryRun);

        try {

            // transport() throws when the target is unreachable, so this is
            // where a dead host surfaces - before anything is read or written.
            $result['transport'] = $client->transport();
            $peer = $client->isPeer();

            if (!$peer) {
                $result['messages'][] = 'Remote does not run Replica: entries only, and the remote will stamp its own _created/_modified.';
            }

            $models = $target->scope($options['model'] ?? null, $this->localCollections());

            if (!count($models)) {
                $result['messages'][] = 'Nothing in scope.';
            }

            /*
             * An explicit target list can silently skip models added later.
             * Surface the gap so a missing model cannot go unnoticed again.
             */
            if (!$target->syncsEverything() && !($options['model'] ?? null)) {

                $missing = array_values(array_diff($this->localCollections(), $models));

                if (count($missing)) {
                    $result['messages'][] = 'Not in target scope: '.implode(', ', $missing)
                        .' (run replica:targets:sync "'.$target->name.'" to include them)';
                }
            }

            // Schema first, so entries land in a model that exists remotely.
            if ($target->syncModels && count($models)) {

                if (!$peer) {
                    $result['messages'][] = 'Model definitions skipped: requires Replica on the remote.';
                } else {

                    $definitions = [];

                    foreach ($models as $name) {
                        if ($model = $this->localModel($name)) {
                            $definitions[] = $model;
                        }
                    }

                    if ($dryRun) {
                        $result['messages'][] = 'would push '.count($definitions).' model definition(s)';
                    } elseif (count($definitions)) {
                        $modelResult = $client->pushModels($definitions, $mode);
                        $result['models'] = $modelResult;
                        $result['messages'][] = 'models: '.json_encode($modelResult);
                    }
                }
            }

            foreach ($models as $name) {

                $items = $this->localItems($name);
                $type  = $this->localType($name);

                // Only a core target needs the id map; a peer keeps our ids.
                $idMap = (!$peer && $target->id) ? $this->idMap($target->id, $name)['forward'] : [];

                if ($dryRun) {
                    $plan = $this->planRemote($client, $name, $items, $mode, $idMap, $type);
                    $this->accumulate($result, $plan, $name, $verbose);
                    continue;
                }

                if (!count($items)) {
                    $result['messages'][] = "{$name}: nothing to send";
                    continue;
                }

                $outcome = $client->pushItems($name, $items, $mode, $idMap, $type);

                if (!$peer && $target->id) {

                    if (count($outcome['idMapStale'] ?? [])) {
                        $this->forgetIds($target->id, $name, $outcome['idMapStale']);
                    }

                    if (count($outcome['idMap'] ?? [])) {
                        $this->rememberIds($target->id, $name, $outcome['idMap']);
                    }
                }

                $this->accumulate($result, $outcome, $name, $verbose);
            }

            // Assets last: their metadata can reference collections and their
            // files are the largest payload, so they should not block entries.
            if ($target->syncAssets) {

                if (!$peer) {
                    $result['messages'][] = 'Assets skipped: requires Replica on the remote.';
                } else {

                    $assets  = $this->localAssets();
                    $folders = $this->localFolders();

                    if (!$dryRun && !count($assets) && !count($folders)) {
                        $result['messages'][] = 'assets: nothing to send';
                    } elseif ($dryRun) {

                        $plan = $this->planAssets($assets, $folders, $client->remoteAssetState(), $mode);
                        $result['assets'] = $plan;
                        $result['messages'][] = 'assets: '.json_encode($plan);

                    } elseif (count($assets) || count($folders)) {

                        $outcome = $client->pushAssets([
                            'assets'  => array_map(fn($a) => $this->attachAssetData($a), $assets),
                            'folders' => $folders,
                        ], $mode);

                        $result['assets'] = $outcome;
                        $result['messages'][] = 'assets: '.json_encode($outcome);
                    }
                }
            }

        } catch (\Throwable $e) {
            $result['errors']++;
            $result['messages'][] = 'FAILED: '.$e->getMessage();
        }

        return $this->finish($result, $target, $dryRun);
    }

    /**
     * PULL - the target is the source, local content the destination.
     */
    public function pull(Target $target, array $options = []): array {

        $mode    = $this->mode($options['mode'] ?? self::MODE_MERGE);
        $dryRun  = (bool)($options['dryRun'] ?? false);
        $verbose = (bool)($options['verbose'] ?? false);

        $client  = $this->client($target);
        $result  = $this->newResult('pull', $target, $mode, $dryRun);

        try {

            // transport() throws when the target is unreachable, so this is
            // where a dead host surfaces - before anything is read or written.
            $result['transport'] = $client->transport();
            $peer = $client->isPeer();

            if (!$peer) {
                $result['messages'][] = 'Remote does not run Replica: entries only, timestamps come from the remote as stored.';
            }

            $available = $peer ? $client->remoteContentModels() : [];
            $models    = $target->scope($options['model'] ?? null, $available);

            if (!count($models)) {
                $result['messages'][] = $peer
                    ? 'Nothing in scope.'
                    : 'Nothing in scope: a non-Replica remote cannot list its models, so select collections on the target.';
            }

            if (!$target->syncsEverything() && !($options['model'] ?? null) && count($available)) {

                $missing = array_values(array_diff($available, $models));

                if (count($missing)) {
                    $result['messages'][] = 'Not in target scope: '.implode(', ', $missing)
                        .' (run replica:targets:sync "'.$target->name.'" to include them)';
                }
            }

            if ($target->syncModels && count($models)) {

                if (!$peer) {
                    $result['messages'][] = 'Model definitions skipped: requires Replica on the remote.';
                } else {
                    $definitions = array_filter(
                        $client->remoteModels(),
                        fn($m) => in_array($m['name'] ?? '', $models)
                    );
                    $modelResult = $this->applyModels($definitions, $mode, $dryRun);
                    $result['models'] = $modelResult;
                    $result['messages'][] = ($dryRun ? 'would apply models: ' : 'models: ').json_encode($modelResult);
                }
            }

            foreach ($models as $name) {

                // Peer transport ignores the type (the remote branches server
                // side); the hint is what lets a core target read a singleton
                // through the singular item endpoint once the model exists.
                $items = $client->fetchItems($name, 200, $this->localType($name));

                if (!$this->localModel($name)) {
                    $result['errors']++;
                    $result['messages'][] = "{$name}: no local model - enable model sync or create it first";
                    continue;
                }

                /*
                 * A core remote hands back ITS ids. Translating them through
                 * the map keeps a push-then-pull round trip stable: without it
                 * every entry we previously seeded would come home under a
                 * second id and duplicate itself locally.
                 */
                $learned = [];

                if (!$peer && $target->id) {
                    $items = $this->translateIncoming($target->id, $name, $items, $learned);
                }

                $outcome = $this->applyItems($name, $items, $mode, $dryRun);

                if (!$dryRun && count($learned) && $target->id) {
                    $this->rememberIds($target->id, $name, $learned);
                }

                $this->accumulate($result, $outcome, $name, $verbose);
            }

            // Assets after the entries that may reference them.
            if ($target->syncAssets) {

                if (!$peer) {
                    $result['messages'][] = 'Assets skipped: requires Replica on the remote.';
                } else {

                    $remote  = $client->remoteAssetState();
                    $assets  = $remote['assets'] ?? [];
                    $folders = $remote['folders'] ?? [];

                    if (!$dryRun && !count($assets) && !count($folders)) {
                        $result['messages'][] = 'assets: nothing to fetch';
                    } elseif ($dryRun) {

                        $plan = $this->applyAssets($assets, $folders, $mode, true);
                        $result['assets'] = $plan;
                        $result['messages'][] = 'assets: '.json_encode($plan);

                    } else {

                        $outcome = $this->applyAssets(
                            $client->attachRemoteFiles($assets),
                            $folders,
                            $mode,
                            false
                        );

                        $result['assets'] = $outcome;
                        $result['messages'][] = 'assets: '.json_encode($outcome);
                    }
                }
            }

        } catch (\Throwable $e) {
            $result['errors']++;
            $result['messages'][] = 'FAILED: '.$e->getMessage();
        }

        return $this->finish($result, $target, $dryRun);
    }

    // ----------------------------------------------------------- appliers

    /**
     * Writes incoming items into a local collection.
     *
     * mirror - the source always wins.
     * merge  - the newest _modified wins; a newer local entry is left alone.
     */
    public function applyItems(string $model, array $items, string $mode, bool $dryRun = false): array {

        $result  = ['created' => 0, 'updated' => 0, 'skipped' => 0, 'errors' => 0, 'messages' => []];
        $current = $this->localItemsById($model);

        foreach ($items as $item) {

            $id = $item['_id'] ?? null;

            if (!$id) {
                $result['errors']++;
                $result['messages'][] = 'error: incoming item without _id';
                continue;
            }

            $existing = $current[$id] ?? null;

            if ($existing && $mode === self::MODE_MERGE) {

                $localModified  = (int)($existing['_modified'] ?? 0);
                $sourceModified = (int)($item['_modified'] ?? 0);

                if ($localModified > $sourceModified) {
                    $result['skipped']++;
                    $result['messages'][] = "skip {$id}: destination is newer";
                    continue;
                }
            }

            if (!$dryRun) {
                try {
                    $this->saveLocalItem($model, $item, (bool)$existing);
                } catch (\Throwable $e) {
                    $result['errors']++;
                    $result['messages'][] = "error {$id}: ".$e->getMessage();
                    continue;
                }
            }

            if ($existing) {
                $result['updated']++;
                $result['messages'][] = ($dryRun ? 'would update ' : 'update ').$id;
            } else {
                $result['created']++;
                $result['messages'][] = ($dryRun ? 'would create ' : 'create ').$id;
            }
        }

        return $result;
    }

    /**
     * Writes incoming model definitions locally, through the content module so
     * its model cache stays coherent.
     */
    public function applyModels(array $models, string $mode, bool $dryRun = false): array {

        $result  = ['created' => 0, 'updated' => 0, 'skipped' => 0, 'errors' => 0, 'messages' => []];
        $content = $this->app->module('content');

        foreach ($models as $model) {

            $name = $model['name'] ?? null;

            if (!$name) {
                $result['errors']++;
                continue;
            }

            $existing = $content->exists($name) ? $content->model($name) : null;

            if ($existing && $mode === self::MODE_MERGE) {

                $localModified  = (int)($existing['_modified'] ?? 0);
                $sourceModified = (int)($model['_modified'] ?? 0);

                if ($localModified > $sourceModified) {
                    $result['skipped']++;
                    $result['messages'][] = "skip model {$name}: destination is newer";
                    continue;
                }
            }

            // _id belongs to the source database, never to ours.
            unset($model['_id']);

            if (!$dryRun) {
                try {
                    if ($existing) {
                        $content->updateModel($name, $model);
                    } else {
                        $content->createModel($name, $model);
                    }
                } catch (\Throwable $e) {
                    $result['errors']++;
                    $result['messages'][] = "error model {$name}: ".$e->getMessage();
                    continue;
                }
            }

            if ($existing) {
                $result['updated']++;
                $result['messages'][] = ($dryRun ? 'would update model ' : 'update model ').$name;
            } else {
                $result['created']++;
                $result['messages'][] = ($dryRun ? 'would create model ' : 'create model ').$name;
            }
        }

        return $result;
    }

    /**
     * Dry-run planner for a push: what would the remote do with these items.
     */
    protected function planRemote(Client $client, string $model, array $items, string $mode, array $idMap = [], string $type = ''): array {

        $result = ['created' => 0, 'updated' => 0, 'skipped' => 0, 'errors' => 0, 'messages' => []];
        $remote = [];

        try {
            foreach ($client->fetchItems($model, 200, $type) as $item) {
                if (isset($item['_id'])) $remote[$item['_id']] = $item;
            }
        } catch (\Throwable $e) {
            // A model that does not exist remotely yet simply has nothing.
            // accumulate() prefixes the model name, so do not repeat it here.
            $result['messages'][] = 'remote read failed ('.$e->getMessage().')';
        }

        foreach ($items as $item) {

            $id = $item['_id'] ?? null;

            // Same correspondence rule pushItems() applies, so the plan matches
            // what a real run would do against a core target.
            $remoteId = null;

            if ($id && isset($remote[$id])) {
                $remoteId = $id;
            } elseif ($id && isset($idMap[$id]) && isset($remote[$idMap[$id]])) {
                $remoteId = $idMap[$id];
            }

            $existing = $remoteId ? $remote[$remoteId] : null;

            if ($existing && $mode === self::MODE_MERGE
                && (int)($existing['_modified'] ?? 0) > (int)($item['_modified'] ?? 0)) {
                $result['skipped']++;
                $result['messages'][] = "skip {$id}: destination is newer";
                continue;
            }

            if ($existing) {
                $result['updated']++;
                $result['messages'][] = 'would update '.$id.($remoteId === $id ? '' : " (remote {$remoteId})");
            } else {
                $result['created']++;
                $result['messages'][] = 'would create '.$id;
            }
        }

        return $result;
    }

    // ---------------------------------------------------------------- log

    protected function newResult(string $direction, Target $target, string $mode, bool $dryRun): array {
        return [
            'direction' => $direction,
            'target'    => $target->id,
            'target_name' => $target->name,
            'mode'      => $mode,
            'dryRun'    => $dryRun,
            'transport' => null,
            'created'   => 0,
            'updated'   => 0,
            'skipped'   => 0,
            'errors'    => 0,
            'collections' => [],
            'models'    => null,
            'assets'    => null,
            'messages'  => [],
        ];
    }

    protected function accumulate(array &$result, array $outcome, string $model, bool $verbose): void {

        foreach (['created', 'updated', 'skipped', 'errors'] as $key) {
            $result[$key] += (int)($outcome[$key] ?? 0);
        }

        $result['collections'][$model] = [
            'created' => (int)($outcome['created'] ?? 0),
            'updated' => (int)($outcome['updated'] ?? 0),
            'skipped' => (int)($outcome['skipped'] ?? 0),
            'errors'  => (int)($outcome['errors'] ?? 0),
        ];

        if ($verbose) {
            foreach (($outcome['messages'] ?? []) as $message) {
                $result['messages'][] = "{$model}: {$message}";
            }
        } else {
            // Errors are always worth keeping, even when not verbose.
            foreach (($outcome['messages'] ?? []) as $message) {
                if (str_starts_with($message, 'error')) {
                    $result['messages'][] = "{$model}: {$message}";
                }
            }
        }
    }

    /**
     * Records the operation and stamps the target's last run.
     */
    protected function finish(array $result, Target $target, bool $dryRun): array {

        $result['_created'] = time();

        // Keep the log document bounded regardless of collection size.
        if (count($result['messages']) > 500) {
            $result['messages'] = array_slice($result['messages'], 0, 500);
            $result['messages'][] = '... truncated';
        }

        $this->app->dataStorage->insert(REPLICA_LOG, $result);

        if (!$dryRun && $target->id !== null) {
            $this->persist($target->withLastRun([
                'at'        => $result['_created'],
                'direction' => $result['direction'],
                'mode'      => $result['mode'],
                'created'   => $result['created'],
                'updated'   => $result['updated'],
                'skipped'   => $result['skipped'],
                'errors'    => $result['errors'],
                'assets'    => [
                    'created' => (int)($result['assets']['created'] ?? 0),
                    'updated' => (int)($result['assets']['updated'] ?? 0),
                    'skipped' => (int)($result['assets']['skipped'] ?? 0),
                    'errors'  => (int)($result['assets']['errors'] ?? 0),
                ],
            ]));
        }

        return $result;
    }

    public function log(int $page = 1, int $limit = 25, ?string $targetId = null): array {

        $page   = max(1, $page);
        $limit  = max(1, min(100, $limit));
        $filter = [];

        if ($targetId) $filter['target'] = $targetId;

        $total = $this->app->dataStorage->count(REPLICA_LOG, $filter);

        $items = $this->app->dataStorage->find(REPLICA_LOG, [
            'filter' => $filter,
            'sort'   => ['_created' => -1],
            'limit'  => $limit,
            'skip'   => ($page - 1) * $limit,
        ])->toArray();

        return [
            'items' => $items,
            'total' => $total,
            'page'  => $page,
            'pages' => (int)ceil($total / $limit),
        ];
    }

    public function mode(?string $mode): string {
        return $mode === self::MODE_MIRROR ? self::MODE_MIRROR : self::MODE_MERGE;
    }
}
