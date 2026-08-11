<?php

/**
 * Token-authenticated REST surface, mounted by the core at /api/forms/...
 *
 *   GET    /api/forms/submissions?form=cotizar&page=1
 *   DELETE /api/forms/submissions/{id}
 *   GET    /api/forms/export?form=cotizar
 *
 * The core authenticates the API token before these run; forms/manage is still
 * checked so a restricted token cannot read or delete submissions.
 *
 * Note that formSubmissions is a normal collection, so the standard content API
 * (/api/content/items/formSubmissions) works too - these endpoints only add the
 * per-form shaping and the CSV export.
 */

$this->on('restApi.config', function($restApi) {

    $restApi->addEndPoint('/forms/submissions', [

        'GET' => function($params, $app) {

            if (!$app->helper('acl')->isAllowed('forms/manage')) {
                $app->response->status = 403;
                return ['error' => 'Permission denied.'];
            }

            return $app->helper('forms')->listSubmissions(
                $app->param('form', null),
                (int)$app->param('page', 1),
                (int)$app->param('limit', 25)
            );
        }
    ]);

    $restApi->addEndPoint('/forms/submissions/{id}', [

        'DELETE' => function($params, $app) {

            if (!$app->helper('acl')->isAllowed('forms/manage')) {
                $app->response->status = 403;
                return ['error' => 'Permission denied.'];
            }

            return ['success' => $app->helper('forms')->remove($params['id'])];
        }
    ]);

    $restApi->addEndPoint('/forms/export', [

        'GET' => function($params, $app) {

            if (!$app->helper('acl')->isAllowed('forms/manage')) {
                $app->response->status = 403;
                return ['error' => 'Permission denied.'];
            }

            $csv = $app->helper('forms')->exportCsv($app->param('form', null));

            header('Content-Type: text/csv; charset=utf-8');
            header('Content-Disposition: attachment; filename="submissions.csv"');

            echo $csv;
            exit;
        }
    ]);
});
