<?php

/**
 * Peer REST endpoints, mounted by the core at /api/replica/...
 *
 * These exist because the core has no REST surface for model definitions, and
 * because its POST /api/content/item/{model} strips every key outside the model
 * field list - including _created and _modified. Replicating faithfully
 * therefore needs its own endpoints on both sides.
 *
 *   GET  /api/replica/manifest        capability probe + model inventory
 *   GET  /api/replica/models          full model definitions
 *   POST /api/replica/models          upsert model definitions
 *   GET  /api/replica/items/{model}   items with timestamps intact
 *   POST /api/replica/items/{model}   upsert items with timestamps intact
 *   GET  /api/replica/assets          asset metadata + folder definitions
 *   POST /api/replica/assets          upsert assets (with base64 file data)
 *   GET  /api/replica/assets/file/{id} original file bytes for an asset
 *
 * Auth is the core's api-key (modules/App/api.php reads HTTP_API_KEY and sets
 * the api user). replica/manage is still checked so a restricted key cannot
 * read or overwrite content.
 */

$this->on('restApi.config', function($restApi) {

    $guard = function($app) {

        if (!$app->helper('acl')->isAllowed('replica/manage')) {
            $app->response->status = 403;
            return ['error' => 'Permission denied.'];
        }

        return null;
    };

    $restApi->addEndPoint('/replica/manifest', [

        'GET' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $models = [];

            foreach ($app->module('content')->models() as $name => $model) {
                $models[] = [
                    'name'      => $name,
                    'label'     => $model['label'] ?? $name,
                    'type'      => $model['type'] ?? null,
                    '_modified' => $model['_modified'] ?? null,
                ];
            }

            return [
                'replica' => Replica\Helper\Replica::VERSION,
                'cockpit' => APP_VERSION ?? null,
                'models'  => $models,
            ];
        }
    ]);

    $restApi->addEndPoint('/replica/models', [

        'GET' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $only   = array_filter((array)$app->param('models', []));
            $models = [];

            foreach ($app->module('content')->models() as $name => $model) {

                if (count($only) && !in_array($name, $only)) continue;

                $models[] = $model;
            }

            return ['models' => $models];
        },

        'POST' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $models = $app->param('models', []);
            $mode   = $app->helper('replica')->mode($app->param('mode', 'merge'));

            if (!is_array($models)) {
                $app->response->status = 412;
                return ['error' => 'models must be an array'];
            }

            return $app->helper('replica')->applyModels($models, $mode);
        }
    ]);

    $restApi->addEndPoint('/replica/items/{model}', [

        'GET' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $model = $params['model'];

            if (!$app->module('content')->model($model)) {
                $app->response->status = 404;
                return ['error' => "Model <{$model}> not found"];
            }

            $limit = (int)$app->param('limit', 200);
            $skip  = (int)$app->param('skip', 0);

            // Read straight from storage: the content module's item pipeline
            // populates references and would rewrite what we must copy verbatim.
            // A singleton shares the content/singletons table, keyed by _model.
            if (($app->module('content')->model($model)['type'] ?? '') === 'singleton') {

                $doc = $app->dataStorage->findOne('content/singletons', ['_model' => $model]);

                return ['items' => $doc ? [$doc] : []];
            }

            $items = $app->dataStorage->find("content/collections/{$model}", [
                'sort'  => ['_created' => 1],
                'limit' => max(1, min(500, $limit)),
                'skip'  => max(0, $skip),
            ])->toArray();

            return ['items' => $items];
        },

        'POST' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $model = $params['model'];

            if (!$app->module('content')->model($model)) {
                $app->response->status = 404;
                return ['error' => "Model <{$model}> not found"];
            }

            $items = $app->param('items', []);
            $mode  = $app->helper('replica')->mode($app->param('mode', 'merge'));

            if (!is_array($items)) {
                $app->response->status = 412;
                return ['error' => 'items must be an array'];
            }

            return $app->helper('replica')->applyItems($model, $items, $mode);
        }
    ]);

    $restApi->addEndPoint('/replica/assets', [

        'GET' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $replica = $app->helper('replica');

            return [
                'assets'  => $replica->localAssets(),
                'folders' => $replica->localFolders(),
            ];
        },

        'POST' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $assets  = $app->param('assets', []);
            $folders = $app->param('folders', []);
            $mode    = $app->helper('replica')->mode($app->param('mode', 'merge'));

            if (!is_array($assets) || !is_array($folders)) {
                $app->response->status = 412;
                return ['error' => 'assets and folders must be arrays'];
            }

            return $app->helper('replica')->applyAssets($assets, $folders, $mode);
        }
    ]);

    $restApi->addEndPoint('/replica/assets/file/{id}', [

        'GET' => function($params, $app) use($guard) {

            if ($denied = $guard($app)) return $denied;

            $id = $params['id'];

            $asset = $app->dataStorage->findOne('assets', ['_id' => $id]);

            if (!$asset) {
                $app->response->status = 404;
                return ['error' => 'Asset not found'];
            }

            return ['asset' => $app->helper('replica')->attachAssetData($asset)];
        }
    ]);
});
