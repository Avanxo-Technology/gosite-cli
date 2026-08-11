<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Output\OutputInterface;

class TargetsRemove extends Base {

    protected static $defaultName = 'replica:targets:remove';

    protected function configure(): void {
        $this
            ->setDescription('Remove a replication target')
            ->addArgument('target', InputArgument::REQUIRED, 'Target name or id');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $target = $this->requireTarget($input->getArgument('target'), $output);

        if (!$target) return Command::FAILURE;

        $this->replica()->removeTarget($target->id);

        $output->writeln("<info>Target '{$target->name}' removed</info>");

        return Command::SUCCESS;
    }
}
