<?php

namespace Replica\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Formatter\OutputFormatter;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Output\OutputInterface;

class Diff extends Base {

    protected static $defaultName = 'replica:diff';

    protected function configure(): void {
        $this
            ->setDescription('Compare local and remote entries per model (read-only)')
            ->addArgument('target', InputArgument::REQUIRED, 'Target name or id')
            ->addArgument('model', InputArgument::OPTIONAL, 'Limit to one collection or singleton (default: the target scope)');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {

        $target = $this->requireTarget($input->getArgument('target'), $output);

        if (!$target) return Command::FAILURE;

        try {
            $diff = $this->replica()->diff($target, $input->getArgument('model'));
        } catch (\Throwable $e) {
            $output->writeln('<error>[x] '.OutputFormatter::escape($e->getMessage()).'</error>');
            return Command::FAILURE;
        }

        $output->writeln('');
        $output->writeln("<info>DIFF</info> target=<comment>{$target->name}</comment> transport=<comment>{$diff['transport']}</comment>");

        $failed = false;

        foreach ($diff['models'] as $name => $model) {

            if (isset($model['error'])) {
                $failed = true;
                $output->writeln(sprintf('  %-28s  <error>remote read failed</error>', $name));
                continue;
            }

            $c = $model['counts'];

            $output->writeln(sprintf(
                '  %-28s only-here %-4d newer-here %-4d newer-there %-4d only-there %-4d same %-4d%s',
                $name, $c['only-here'], $c['newer-here'], $c['newer-there'], $c['only-there'], $c['same'],
                $model['protected'] ? '  protected' : ''
            ));

            if (!$output->isVerbose()) continue;

            foreach ($model['entries'] as $entry) {

                if ($entry['state'] === 'same') continue;

                $output->writeln(sprintf(
                    '    %-12s %-20s %s',
                    $entry['state'],
                    OutputFormatter::escape($entry['id'] ?? $entry['remoteId'] ?? '?'),
                    OutputFormatter::escape($entry['title'])
                ));
            }
        }

        foreach ($diff['messages'] as $message) {
            $output->writeln('  <comment>'.OutputFormatter::escape($message).'</comment>');
        }

        return $failed ? Command::FAILURE : Command::SUCCESS;
    }
}
