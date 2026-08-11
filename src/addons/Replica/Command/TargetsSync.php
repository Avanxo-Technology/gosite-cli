<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Reconciles a target's model scope with this instance's content models.
 *
 * A hand-maintained models list drifts: models added locally later are not in
 * it, so push/pull silently skip them. This brings the list back to "every
 * content model this instance offers" so nothing is left out.
 */
class TargetsSync extends Base {

    protected static $defaultName = 'replica:targets:sync';

    protected function configure(): void {
        $this
            ->setDescription('Bring a target\'s model scope up to date with this instance')
            ->addArgument('target', InputArgument::REQUIRED, 'Target name or id');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $target = $this->requireTarget($input->getArgument('target'), $output);

        if (!$target) return Command::FAILURE;

        $local   = $this->replica()->localCollections();
        $current = array_values(array_unique($target->models));

        if ($target->syncsEverything()) {
            $output->writeln('<info>Target already syncs every content model</info> ('.count($local).' models). Nothing to do.');
            return Command::SUCCESS;
        }

        $added   = array_values(array_diff($local, $current));
        $removed = array_values(array_diff($current, $local));

        if (!count($added) && !count($removed)) {
            $output->writeln('<info>Target scope is up to date</info> ('.count($current).' models).');
            return Command::SUCCESS;
        }

        $models = array_values(array_unique(array_merge($current, $added)));
        sort($models);

        try {
            $this->replica()->saveTarget(['_id' => $target->id, 'models' => $models]);
        } catch (\Throwable $e) {
            $output->writeln('<error>[x] '.$e->getMessage().'</error>');
            return Command::FAILURE;
        }

        foreach ($added as $name) {
            $output->writeln('<info>added</info>     '.$name);
        }

        foreach ($removed as $name) {
            $output->writeln('<comment>removed</comment>  '.$name.' (no local content model)');
        }

        $output->writeln(sprintf('Target scope now covers <info>%d</info> content models.', count($models)));

        return Command::SUCCESS;
    }
}
