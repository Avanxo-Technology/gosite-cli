<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

class Pull extends Base {

    protected static $defaultName = 'replica:pull';

    protected function configure(): void {
        $this
            ->setDescription('Pull content from a target (remote -> local)')
            ->addArgument('target', InputArgument::REQUIRED, 'Target name or id')
            ->addArgument('model', InputArgument::OPTIONAL, 'Limit to one collection or singleton (default: the target scope)')
            ->addOption('mode', null, InputOption::VALUE_REQUIRED, 'mirror (source wins) or merge (newest _modified wins)', 'merge')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Report what would change without writing')
            ->addOption('assets', null, InputOption::VALUE_NONE, 'Also replicate assets, even if the target has them excluded');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $target = $this->requireTarget($input->getArgument('target'), $output);

        if (!$target) return Command::FAILURE;

        if (!$target->enabled) {
            $output->writeln("<error>[x] Target '{$target->name}' is disabled</error>");
            return Command::FAILURE;
        }

        $result = $this->replica()->pull($target, [
            'mode'    => $input->getOption('mode'),
            'dryRun'  => (bool)$input->getOption('dry-run'),
            // -v / --verbose is Symfony Console's own global flag; reuse it
            // rather than declaring a conflicting option.
            'verbose' => $output->isVerbose(),
            'model'   => $input->getArgument('model'),
        ]);

        return $this->report($result, $output);
    }
}
