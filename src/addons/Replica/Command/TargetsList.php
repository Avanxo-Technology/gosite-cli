<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

class TargetsList extends Base {

    protected static $defaultName = 'replica:targets:list';

    protected function configure(): void {
        $this
            ->setDescription('List replication targets')
            ->setHelp('Lists configured targets. API keys are masked unless --ping is used to test them.')
            ->addOption('ping', null, InputOption::VALUE_NONE, 'Contact each target and report its transport');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $targets = $this->replica()->targets();

        if (!count($targets)) {
            $output->writeln('<comment>No targets configured. Add one with replica:targets:add</comment>');
            return Command::SUCCESS;
        }

        foreach ($targets as $target) {

            $state = $target->enabled ? '<info>enabled</info>' : '<comment>disabled</comment>';

            $output->writeln("<info>{$target->name}</info>  {$target->id}");
            $output->writeln("  url        {$target->baseUrl}");
            $output->writeln('  api key    '.$target->maskedKey());
            $output->writeln("  state      {$state}");
            $output->writeln('  scope      '.$target->scopeLabel());
            $output->writeln('  models     '.($target->syncModels ? 'included' : 'not included'));
            $output->writeln('  assets     '.($target->syncAssets ? 'included' : 'not included'));

            if ($mapped = $this->replica()->countIdMap($target->id)) {
                $output->writeln("  id map     {$mapped} entries (target cannot keep our ids)");
            }

            if ($last = $target->lastRun) {
                $output->writeln(sprintf(
                    '  last run   %s %s - created %d, updated %d, skipped %d, errors %d',
                    date('Y-m-d H:i', $last['at']), $last['direction'],
                    $last['created'], $last['updated'], $last['skipped'], $last['errors']
                ));
            }

            if ($input->getOption('ping')) {
                $ping = $this->replica()->client($target)->ping();
                $output->writeln($ping['ok']
                    ? "  reachable  <info>yes</info> (transport: {$ping['transport']})"
                    : "  reachable  <error>no</error> ({$ping['error']})");
            }

            $output->writeln('');
        }

        return Command::SUCCESS;
    }
}
