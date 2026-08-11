<?php

namespace Replica\Command;

use Replica\Model\Target;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Shared plumbing for the replica:* commands.
 */
abstract class Base extends Command {

    protected $app = null;

    public function __construct(\Lime\App $app) {
        $this->app = $app;
        parent::__construct();
    }

    protected function replica() {
        return $this->app->helper('replica');
    }

    /**
     * Resolves a target by _id or name, printing a usable error when missing.
     */
    protected function requireTarget(string $idOrName, OutputInterface $output): ?Target {

        $target = $this->replica()->resolveTarget($idOrName);

        if (!$target) {
            $output->writeln("<error>[x] Target '{$idOrName}' not found</error>");
            return null;
        }

        return $target;
    }

    /**
     * Prints an operation result and returns the process exit code.
     */
    protected function report(array $result, OutputInterface $output): int {

        $label = strtoupper($result['direction']).($result['dryRun'] ? ' (dry run)' : '');

        $output->writeln('');
        $output->writeln("<info>{$label}</info> target=<comment>{$result['target_name']}</comment> mode=<comment>{$result['mode']}</comment> transport=<comment>".($result['transport'] ?: 'n/a').'</comment>');

        foreach (($result['collections'] ?? []) as $name => $counts) {
            $output->writeln(sprintf(
                '  %-28s created %-5d updated %-5d skipped %-5d errors %d',
                $name, $counts['created'], $counts['updated'], $counts['skipped'], $counts['errors']
            ));
        }

        foreach (($result['messages'] ?? []) as $message) {
            $tag = str_contains($message, 'FAILED') || str_starts_with($message, 'error') ? 'error' : 'comment';
            $output->writeln("  <{$tag}>{$message}</{$tag}>");
        }

        $output->writeln(sprintf(
            "<info>total</info> created %d, updated %d, skipped %d, errors %d",
            $result['created'], $result['updated'], $result['skipped'], $result['errors']
        ));

        return $result['errors'] === 0 ? Command::SUCCESS : Command::FAILURE;
    }
}
