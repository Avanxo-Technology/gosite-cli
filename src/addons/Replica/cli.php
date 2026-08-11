<?php

/**
 * CLI commands. The core registers commands as Symfony Console classes
 * ($cli->add(new Command($app))), following modules/Content/cli.php.
 *
 *   replica:targets:list
 *   replica:targets:add     <name> <base_url> <api_key> [--models=] [--sync-models]
 *   replica:targets:toggle  <target> [--on|--off]
 *   replica:targets:sync    <target>
 *   replica:targets:remove  <target>
 *   replica:push            <target> [model] [--mode=] [--dry-run] [--verbose]
 *   replica:pull            <target> [model] [--mode=] [--dry-run] [--verbose]
 *   replica:log             [--target=] [--limit=]
 */

if (!isset($cli, $app) || PHP_SAPI !== 'cli') {
    return;
}

$cli->add(new Replica\Command\TargetsList($app));
$cli->add(new Replica\Command\TargetsAdd($app));
$cli->add(new Replica\Command\TargetsToggle($app));
$cli->add(new Replica\Command\TargetsSync($app));
$cli->add(new Replica\Command\TargetsRemove($app));
$cli->add(new Replica\Command\Push($app));
$cli->add(new Replica\Command\Pull($app));
$cli->add(new Replica\Command\Log($app));
