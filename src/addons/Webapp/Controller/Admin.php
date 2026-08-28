<?php

namespace Webapp\Controller;

/**
 * Admin screen for Webapp settings and SEO management.
 */
class Admin extends \App\Controller\App {

    public function index() {

        if (!$this->isAllowed('webapp/manage')) {
            return $this->stop(401);
        }

        $webapp = $this->helper('webapp');

        // Creates models on first admin load.
        $webapp->ensureModels();

        return $this->render('webapp:views/index.php', [
            'webappConfig' => $webapp->getWebappConfig(),
            'webappFields' => $webapp->webappFields(),
            'seoPages'     => $webapp->seoPages(),
        ]);
    }
}
