#!/usr/bin/env node
/*
 * The pre-commit half: read what is STAGED and refuse a commit that carries a
 * credential.
 *
 *   node scripts/secret-scan-staged.mjs [--repo <path>]
 *
 * It reads staged CONTENT via `git show :file`, not the working tree, because
 * staged is what becomes permanent - and the two differ exactly when somebody
 * has staged something and then edited or deleted it.
 *
 * IT NEVER CONSULTS .gitignore. That is the whole point: the ignore file is the
 * thing being backstopped, and all three ways of defeating it - `git add -f`, an
 * edit to the ignore file, a new secret at an already-allowed path - end with
 * the material STAGED, which is where this looks.
 *
 * Exit 0 clean, 1 refuse, 2 could not check.
 */

import { execFileSync } from "node:child_process";
import { scanContent, verdict } from "./secret-scan.mjs";

const args = process.argv.slice(2);
const ri = args.indexOf("--repo");
const repo = ri !== -1 ? args[ri + 1] : process.cwd();

function git(...a) {
  return execFileSync("git", ["-C", repo, ...a], {
    encoding: "utf8",
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024,
  });
}

let staged;
try {
  // ACR: added, copied, renamed, modified. A DELETION stages no content and
  // cannot leak anything, so it is excluded rather than read and skipped.
  staged = git("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
} catch (err) {
  console.error(`secret-scan: could not read the staged list - ${err.message}`);
  console.error("This is 'could not check', which REFUSES. A hook that cannot look must not pass.");
  process.exit(2);
}

const results = [];
for (const path of staged) {
  let text = "";
  try {
    text = git("show", `:${path}`);
  } catch {
    // A staged path whose blob cannot be read is not proof of innocence. The
    // FILENAME is still checked, which is the half that does not need content.
    text = "";
  }
  results.push({ path, findings: scanContent(path, text) });
}

const v = verdict(results);

if (v.exitCode === 2) {
  console.error(`secret-scan: examined ${v.examined} staged file(s).`);
  console.error("Nothing was examined, so nothing was proved. REFUSING - a hook that looked nowhere is not a clean commit.");
  process.exit(2);
}

console.log(`secret-scan: examined ${v.examined} staged file(s).`);
if (v.findings.length) {
  console.error(`\nREFUSED - ${v.findings.length} credential-shaped item(s) in the STAGED content:\n`);
  for (const f of v.findings) {
    console.error(`  ${f.path}${f.line ? `:${f.line}` : ""}  [${f.kind}] ${f.why}`);
  }
  console.error("\nA credential in a commit is permanent even after the file is deleted.");
  console.error("Unstage it (git restore --staged <file>), then commit.");
  console.error("If this is genuinely a placeholder, make it look like one - an ellipsis or a <PLACEHOLDER>.");
  process.exit(1);
}
console.log("secret-scan: clean.");
