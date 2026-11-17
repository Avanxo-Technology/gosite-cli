<?php

/**
 * Token-authenticated REST surface, mounted by the core at /api/forms/...
 *
 *   GET    /api/forms/submissions?form=cotizar&page=1
 *   PATCH  /api/forms/submissions/{id}   {"data": {...}, "recaptcha": {"token", "action"}}
 *   DELETE /api/forms/submissions/{id}
 *   GET    /api/forms/settings/{form}    label and fieldOptions only
 *   GET    /api/forms/export?form=cotizar
 *
 * The core authenticates the API token before these run; forms/manage is still
 * checked so a restricted token cannot read or delete submissions.
 *
 * formSubmissions is a normal collection, but a site changes it only through
 * these endpoints: they sanitize, check forms/manage and keep notifications to
 * the one sent on submit.
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

        // Merges fields into a submission's data; never notifies.
        'PATCH' => function($params, $app) {

            if (!$app->helper('acl')->isAllowed('forms/manage')) {
                $app->response->status = 403;
                return ['error' => 'Permission denied.'];
            }

            $recaptcha = $app->param('recaptcha', null);

            $result = $app->helper('forms')->updateData(
                (string)$params['id'],
                $app->param('data', null),
                is_array($recaptcha) ? $recaptcha : null
            );

            $app->response->status = $result['status'];
            unset($result['status']);

            return $result;
        },

        'DELETE' => function($params, $app) {

            if (!$app->helper('acl')->isAllowed('forms/manage')) {
                $app->response->status = 403;
                return ['error' => 'Permission denied.'];
            }

            return ['success' => $app->helper('forms')->remove($params['id'])];
        }
    ]);

    // What a site needs to render a form: its label and the choices of its
    // fields. Any API token may read it; nothing secret is in the answer.
    $restApi->addEndPoint('/forms/settings/{form}', [

        'GET' => function($params, $app) {

            $form = (string)$params['form'];

            if (!preg_match('/^[a-zA-Z0-9_-]{1,64}$/', $form)) {
                $app->response->status = 400;
                return ['error' => 'Invalid form name.'];
            }

            return $app->helper('forms')->publicSettings($form);
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
