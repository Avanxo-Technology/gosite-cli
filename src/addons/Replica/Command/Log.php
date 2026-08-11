<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

class Log extends Base {

    protected static $defaultName = 'replica:log';

    protected function configure(): void {
        $this
            ->setDescription('Show the replication activity log, newest first')
            ->addOption('target', null, InputOption::VALUE_REQUIRED, 'Only entries for this target (name or id)')
            ->addOption('limit', null, InputOption::VALUE_REQUIRED, 'How many entries to show', '20');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $targetId = null;

        if ($name = $input->getOption('target')) {

            $target = $this->requireTarget($name, $output);

            if (!$target) return Command::FAILURE;

            $targetId = $target->id;
        }

        $log = $this->replica()->log(1, (int)$input->getOption('limit'), $targetId);

        if (!count($log['items'])) {
            $output->writeln('<comment>No activity recorded yet</comment>');
            return Command::SUCCESS;
        }

        foreach ($log['items'] as $entry) {
            $output->writeln(sprintf(
                '%s  %-5s %-18s %-7s%s created %-4d updated %-4d skipped %-4d errors %d',
                date('Y-m-d H:i:s', $entry['_created']),
                $entry['direction'],
                $entry['target_name'] ?? '?',
                $entry['mode'],
                $entry['dryRun'] ? ' [dry]' : '      ',
                $entry['created'], $entry['updated'], $entry['skipped'], $entry['errors']
            ));
        }

        $output->writeln('');
        $output->writeln("<info>{$log['total']} entries total</info>");

        return Command::SUCCESS;
    }
}
