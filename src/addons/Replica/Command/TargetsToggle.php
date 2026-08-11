<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Enables or disables a target without touching the rest of its configuration.
 *
 * A disabled target keeps its URL, key and scope but refuses to run, which is
 * the safe way to pause replication to an instance that is down or mid-deploy.
 */
class TargetsToggle extends Base {

    protected static $defaultName = 'replica:targets:toggle';

    protected function configure(): void {
        $this
            ->setDescription('Enable or disable a target')
            ->setHelp('Without --on or --off the current state is flipped.')
            ->addArgument('target', InputArgument::REQUIRED, 'Target name or id')
            ->addOption('on', null, InputOption::VALUE_NONE, 'Force enabled')
            ->addOption('off', null, InputOption::VALUE_NONE, 'Force disabled');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $on  = (bool)$input->getOption('on');
        $off = (bool)$input->getOption('off');

        if ($on && $off) {
            $output->writeln('<error>[x] --on and --off are mutually exclusive</error>');
            return Command::FAILURE;
        }

        if (!$this->requireTarget($input->getArgument('target'), $output)) {
            return Command::FAILURE;
        }

        $enabled = $on ? true : ($off ? false : null);
        $target  = $this->replica()->toggleTarget($input->getArgument('target'), $enabled);

        $output->writeln($target->enabled
            ? "<info>Target '{$target->name}' is now enabled</info>"
            : "<comment>Target '{$target->name}' is now disabled</comment>");

        return Command::SUCCESS;
    }
}
