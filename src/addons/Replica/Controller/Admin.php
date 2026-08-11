<?php

namespace Replica\Controller;

/**
 * Admin screen. Extends App\Controller\App so anonymous visitors are rerouted
 * to the login page and the panel layout is applied.
 */
class Admin extends \App\Controller\App {

    public function index() {

        if (!$this->isAllowed('replica/manage')) {
            return $this->stop(401);
        }

        $replica = $this->helper('replica');

        return $this->render('replica:views/index.php', [
            'targets'     => $replica->targets(),  // masked by Target::jsonSerialize()
            'collections' => $replica->localModels(),
        ]);
    }
}
