#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function usage() {
  console.error('Usage: node tools/test-stroke-replay-fast.mjs [--config debug|release] INPUT.csv');
}

let configuration = 'debug';
let inputArgument;
for (let index = 2; index < process.argv.length; ++index) {
  const argument = process.argv[index];
  if (argument === '--config' && index + 1 < process.argv.length) {
    configuration = process.argv[++index].toLowerCase();
  } else if (argument === '--help' || argument === '-h') {
    usage();
    process.exit(0);
  } else if (inputArgument === undefined) {
    inputArgument = argument;
  } else {
    usage();
    process.exit(2);
  }
}

if (!inputArgument || !['debug', 'release'].includes(configuration)) {
  usage();
  process.exit(2);
}

const inputPath = isAbsolute(inputArgument)
  ? inputArgument
  : resolve(repositoryRoot, inputArgument);
if (!existsSync(inputPath)) {
  console.error(`FAIL input_not_found=${inputArgument}`);
  process.exit(2);
}

const buildDirectory = configuration === 'release' ? 'startup-release' : 'startup-debug';
const executableName = process.platform === 'win32' ? 'stroke_engine_cli.exe' : 'stroke_engine_cli';
const executablePath = join(repositoryRoot, 'build', buildDirectory, executableName);
if (!existsSync(executablePath)) {
  console.error(`FAIL executable_not_found=${executablePath}`);
  console.error(
    `Build it first with: cmake --build build/${buildDirectory} --target stroke_engine_cli --config ${configuration === 'release' ? 'Release' : 'Debug'}`,
  );
  process.exit(2);
}

const result = spawnSync(executablePath, ['--input', inputPath, '--invariants-only', '--summary'], {
  cwd: repositoryRoot,
  encoding: 'utf8',
});

const output = `${result.stdout ?? ''}${result.stderr ?? ''}`.trim();
if (output) console.log(output);
process.exit(result.status ?? 1);

