<?php

$this->on('restApi.config', function($restApi) {

    // List all content models
    $restApi->addEndPoint('/models', [
        'GET' => function($params, $app) {
            $models = $app->module('content')->models();

            if (!$app->helper('acl')->isSuperAdmin()) {
                $acl = $app->helper('acl');
                $models = array_filter($models, function($m) use($acl) {
                    return $acl->isAllowed("content/{$m['name']}/read");
                });
            }

            return array_values($models);
        }
    ]);

    // Save (create or update) a content model
    $restApi->addEndPoint('/models/save', [
        'POST' => function($params, $app) {

            $model = $app->param('model');

            if (!$model || !isset($model['name'], $model['type']) || !trim($model['name']) || !trim($model['type'])) {
                $app->response->status = 412;
                return ['error' => 'Model data is missing or invalid'];
            }

            if (!in_array($model['type'], ['collection', 'singleton', 'tree'])) {
                $app->response->status = 412;
                return ['error' => 'Invalid model type'];
            }

            if (!$app->helper('acl')->isAllowed("content/:models/manage") && !$app->helper('acl')->isAllowed("content/{$model['name']}/manage")) {
                $app->response->status = 401;
                return ['error' => 'Permission denied'];
            }

            try {
                $result = $app->module('content')->saveModel($model['name'], $model);
                return $result;
            } catch (\Throwable $e) {
                $app->response->status = 500;
                return ['error' => $e->getMessage()];
            }
        }
    ]);

    // Remove a content model
    $restApi->addEndPoint('/models/remove', [
        'POST' => function($params, $app) {

            $name = $app->param('name');

            if (!$name || !trim($name)) {
                $app->response->status = 412;
                return ['error' => 'Model name is missing'];
            }

            if (!$app->helper('acl')->isAllowed("content/:models/manage")) {
                $app->response->status = 401;
                return ['error' => 'Permission denied'];
            }

            try {
                $app->module('content')->removeModel($name);
                return ['success' => true];
            } catch (\Throwable $e) {
                $app->response->status = 500;
                return ['error' => $e->getMessage()];
            }
        }
    ]);
});
