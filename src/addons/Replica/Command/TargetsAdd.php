<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

class TargetsAdd extends Base {

    protected static $defaultName = 'replica:targets:add';

    protected function configure(): void {
        $this
            ->setDescription('Add a replication target')
            ->addArgument('name', InputArgument::REQUIRED, 'Target name')
            ->addArgument('base_url', InputArgument::REQUIRED, 'Base URL of the remote instance, e.g. http://cms.example.com')
            ->addArgument('api_key', InputArgument::REQUIRED, 'API key issued by the remote instance')
            ->addOption('models', null, InputOption::VALUE_REQUIRED, 'Comma separated collections and singletons to sync (default: all)')
            ->addOption('sync-models', null, InputOption::VALUE_NONE, 'Also replicate model/schema definitions')
            ->addOption('sync-assets', null, InputOption::VALUE_NONE, 'Also replicate assets (files and their metadata)')
            ->addOption('disabled', null, InputOption::VALUE_NONE, 'Create the target disabled');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $models = $input->getOption('models');

        try {
            $target = $this->replica()->saveTarget([
                'name'       => $input->getArgument('name'),
                'base_url'   => $input->getArgument('base_url'),
                'api_key'    => $input->getArgument('api_key'),
                'enabled'    => !$input->getOption('disabled'),
                'syncModels' => (bool)$input->getOption('sync-models'),
                'syncAssets' => (bool)$input->getOption('sync-assets'),
                'models'     => $models ? array_map('trim', explode(',', $models)) : [],
            ]);
        } catch (\Throwable $e) {
            $output->writeln('<error>[x] '.$e->getMessage().'</error>');
            return Command::FAILURE;
        }

        $output->writeln("<info>Target '{$target->name}' created</info> ({$target->id})");

        $ping = $this->replica()->client($target)->ping();

        $output->writeln($ping['ok']
            ? "Reachable, transport: <info>{$ping['transport']}</info>"
            : "<comment>Not reachable yet: {$ping['error']}</comment>");

        return Command::SUCCESS;
    }
}
