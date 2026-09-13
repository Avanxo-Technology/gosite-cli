<?php

// Cockpit configuration for __PROJECT__.
//
// Two files, merged in this order:
//   config.core.php   gosite's defaults, rewritten by `gosite generate`
//   config.local.php  this site's own settings; gosite never touches it
//
// Keep this file as it is: a core upgrade then reaches the CMS on the next
// `gosite generate`, and a local change is never lost to one.

$config = require __DIR__.'/config.core.php';

if (is_file(__DIR__.'/config.local.php')) {
    $config = array_replace_recursive($config, require __DIR__.'/config.local.php');
}

return $config;
