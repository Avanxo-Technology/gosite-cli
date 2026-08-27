<?php

namespace Blog\Controller;

/**
 * Admin screen. Extends App\Controller\App so anonymous visitors are rerouted
 * to the login page and the panel layout is applied.
 */
class Admin extends \App\Controller\App {

    public function index() {

        if (!$this->isAllowed('blog/manage')) {
            return $this->stop(401);
        }

        $blog = $this->helper('blog');

        // Makes a fresh install self-installing: the collections are created
        // the first time somebody opens the screen.
        $blog->ensureModels();

        return $this->render('blog:views/index.php', [
            'blogs'   => $blog->blogs(),
            'siteUrl' => $blog->siteUrl(),
        ]);
    }
}
