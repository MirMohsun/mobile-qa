#!/usr/bin/env node
// Runs on `npm install` (or `pnpm add`) of this package as a dependency.
// npm has no concept of ".claude/skills/" — a plain install just drops
// these files in node_modules/mobile-qa, where Claude Code never looks.
// This script is what actually makes the skill usable: it copies the
// bundle (SKILL.md, rules/, scripts/, examples/) into
// <consuming project>/.claude/skills/mobile-qa, the one place Claude Code
// reads skills from.
//
// Re-running (every `npm install` that touches this package) overwrites
// the destination — same semantics as `git clone`/`git pull`, not a merge.
'use strict';

const fs = require('fs');
const path = require('path');

const PACKAGE_ROOT = __dirname;
// INIT_CWD is the directory the install command was actually run from —
// set by npm, pnpm and yarn classic alike for lifecycle scripts. Falls
// back to cwd for a direct `node postinstall.js` run.
const PROJECT_ROOT = process.env.INIT_CWD || process.cwd();
const DEST = path.join(PROJECT_ROOT, '.claude', 'skills', 'mobile-qa');

const FILES_TO_COPY = ['SKILL.md', 'rules', 'scripts', 'examples'];

function copyRecursive(src, dest) {
  const stat = fs.statSync(src);
  if (stat.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src))
      copyRecursive(path.join(src, entry), path.join(dest, entry));
  }
  else {
    fs.copyFileSync(src, dest);
    if (src.endsWith('.sh'))
      fs.chmodSync(dest, 0o755);
  }
}

function main() {
  if (path.resolve(PROJECT_ROOT) === path.resolve(PACKAGE_ROOT)) {
    // Running inside the mobile-qa repo itself (e.g. `npm install` for
    // local development) — nothing to install into, skip quietly.
    return;
  }

  fs.mkdirSync(DEST, { recursive: true });
  for (const name of FILES_TO_COPY) {
    const src = path.join(PACKAGE_ROOT, name);
    if (fs.existsSync(src))
      copyRecursive(src, path.join(DEST, name));
  }

  console.log(`mobile-qa: skill installed to ${path.relative(PROJECT_ROOT, DEST)}`);
  console.log('Next: run its doctor.sh to check the environment:');
  console.log(`  ${path.relative(PROJECT_ROOT, DEST)}/scripts/doctor.sh`);
}

main();
