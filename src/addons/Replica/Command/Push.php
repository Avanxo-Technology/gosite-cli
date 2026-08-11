<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

class Push extends Base {

    protected static $defaultName = 'replica:push';

    protected function configure(): void {
        $this
            ->setDescription('Push content to a target (local -> remote)')
            ->addArgument('target', InputArgument::REQUIRED, 'Target name or id')
            ->addArgument('model', InputArgument::OPTIONAL, 'Limit to one collection or singleton (default: the target scope)')
            ->addOption('mode', null, InputOption::VALUE_REQUIRED, 'mirror (source wins) or merge (newest _modified wins)', 'merge')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Report what would change without writing')
            ->addOption('assets', null, InputOption::VALUE_NONE, 'Also replicate assets, even if the target has them excluded')
            ->addOption('reset-map', null, InputOption::VALUE_NONE, 'Forget remembered remote ids first, re-seeding the target from scratch (core transport only)');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $target = $this->requireTarget($input->getArgument('target'), $output);

        if (!$target) return Command::FAILURE;

        if (!$target->enabled) {
            $output->writeln("<error>[x] Target '{$target->name}' is disabled</error>");
            return Command::FAILURE;
        }

        if ($input->getOption('reset-map')) {
            $this->replica()->clearIdMap($target->id);
            $output->writeln('<comment>id map cleared: entries will be recreated on the target</comment>');
        }

        $result = $this->replica()->push($target, [
            'mode'    => $input->getOption('mode'),
            'dryRun'  => (bool)$input->getOption('dry-run'),
            // -v / --verbose is Symfony Console's own global flag; reuse it
            // rather than declaring a conflicting option.
            'verbose' => $output->isVerbose(),
            'model'   => $input->getArgument('model'),
            'assets'  => (bool)$input->getOption('assets'),
        ]);

        return $this->report($result, $output);
    }
}
