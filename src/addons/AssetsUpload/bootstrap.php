<?php

$this->on('restApi.config', function($restApi) {
    $restApi->addEndPoint('/assets/upload', [
        'POST' => function($params, $app) {
            $meta = ['folder' => $this->param('folder', '')];
            return $this->module('assets')->upload('files', $meta);
        }
    ]);
});
