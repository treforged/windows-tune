/*
 * Refuse a commit that carries credential-shaped material, WHATEVER the ignore
 * file says.
 *
 * WHY, and it is the hole in what was built an hour earlier. `~/.claude` is now
 * an allowlist repo: `/*` ignores everything and six subtrees are named back
 * in. That protects TODAY. It does not protect tomorrow, and a future session
 * can defeat it three ways without any malice at all:
 *
 *   - `git add -f .credentials.json` overrides the ignore file outright
 *   - an edit to `.gitignore` widens what is included
 *   - a new secret lands at a path the allowlist already covers, such as
 *     `bin/whatever.env`
 *
 * A .gitignore IS A DEFAULT, NOT A GATE. This reads what is actually STAGED,
 * which is the thing that becomes permanent, and it does not consult the ignore
 * file at all - so all three bypasses walk into it.
 *
 * WHAT IT STOPS AND WHAT IT DOES NOT. It stops the ACCIDENT: a key pasted into
 * a script, a credential file force-added, a new `.env` in an allowlisted
 * directory. It does NOT stop a determined bypass - `git commit --no-verify`
 * skips every hook, and anyone able to edit the tracked hook can remove it.
 * That is not a fixable property of a local pre-commit hook, and saying so is
 * the point: a guard whose limits are undocumented gets trusted past them.
 */

// Patterns for credential VALUES. Deliberately specific prefixes rather than
// entropy heuristics: entropy flags minified code and base64 test fixtures, and
// a check that cries wolf is a check people bypass - which is exactly the
// failure mode this file exists to prevent.
const VALUE_PATTERNS = [
  { name: "Anthropic key", re: /\bsk-ant-[A-Za-z0-9_-]{20,}/ },
  { name: "OpenAI-style key", re: /\bsk-[A-Za-z0-9]{32,}/ },
  // THE THREE BELOW WERE ADDED 2026-09-17 AFTER A MEASURED MISS, and the
  // mechanism is worth keeping because it recurs with every new vendor.
  //
  // The OpenAI-style rule above requires ALPHANUMERICS after `sk-`. An
  // OpenRouter key is `sk-or-v1-<hex>`, so the hyphens break the match at
  // character three - and OpenRouter is one of the keys that actually leaked
  // into this machine's git history. A planted `sk-or-v1-...` line passed this
  // scanner CLEAN while the Anthropic line beside it was correctly refused.
  //
  // Widening the OpenAI rule to allow hyphens was the obvious fix and is
  // rejected: `sk-` plus 32 hyphenated characters matches ordinary slugs and
  // minified code, and a rule that cries wolf gets bypassed on the day it
  // matters. Name the prefix instead.
  { name: "OpenRouter key", re: /\bsk-or-v1-[A-Za-z0-9]{32,}/ },
  { name: "Cerebras key", re: /\bcsk-[A-Za-z0-9]{20,}/ },
  { name: "Resend key", re: /\bre_[A-Za-z0-9]{20,}/ },
  // NOT COVERED, AND SAID SO RATHER THAN IMPLIED: a Mistral key is 32 bare
  // alphanumerics with no prefix, indistinguishable from a hash, an id or a
  // minified token. No pattern for it would avoid crying wolf, so
  // MISTRAL_API_KEY is caught by the `-keys.` FILENAME rule and by .gitignore,
  // never by content. A reader who assumes otherwise trusts this past its reach.
  { name: "GitHub token", re: /\bgh[pousr]_[A-Za-z0-9]{30,}/ },
  { name: "Groq key", re: /\bgsk_[A-Za-z0-9]{30,}/ },
  { name: "Google API key", re: /\bAIza[0-9A-Za-z_-]{35}/ },
  { name: "AWS access key id", re: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "Slack token", re: /\bxox[baprs]-[A-Za-z0-9-]{10,}/ },
  { name: "private key block", re: /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----/ },
  { name: "JSON Web Token", re: /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\./ },
  { name: "Supabase service role key", re: /\bservice_role["'\s:=]+[A-Za-z0-9._-]{40,}/i },
];

// Filenames that are credentials whatever is inside them. A file called
// `.credentials.json` does not need its contents inspected to be refused.
const NAME_PATTERNS = [
  { name: "credentials file", re: /(^|\/)\.?credentials(\.json)?$/i },
  { name: "env file", re: /(^|\/)[^/]*\.env(\.[^/]+)?$/i },
  { name: "key file", re: /(^|\/)[^/]*(id_rsa|id_ed25519|\.pem|\.pfx|\.p12)$/i },
  { name: "keys file", re: /(^|\/)[^/]*-keys\.[^/]+$/i },
];

/*
 * A line that is an EXAMPLE rather than a secret.
 *
 * `api-design/SKILL.md` documents `Authorization: Bearer eyJhbGciOiJIUzI1NiIs...`
 * and `FREE-LLM-EXECUTORS.md` shows the shape of each provider's key. Refusing
 * those would make the hook wrong on the very files it is meant to let through,
 * and a hook that is wrong on ordinary work is a hook that gets `--no-verify`d
 * on the day it matters.
 *
 * The tell is an ellipsis, an obvious placeholder, or a comment marker - not the
 * file it lives in, because "this file is documentation" is exactly the excuse a
 * real leak would hide behind.
 */
const PLACEHOLDER = /\.\.\.|<[^>]*>|xxx+|YOUR[_ -]?|EXAMPLE|PLACEHOLDER|REDACTED|\bfake\b|\bdummy\b/i;

export function scanContent(path, text) {
  const findings = [];
  for (const p of NAME_PATTERNS) {
    if (p.re.test(path)) {
      findings.push({ path, line: 0, kind: p.name, why: "the FILENAME is a credential, whatever is inside it" });
    }
  }
  const lines = String(text ?? "").split("\n");
  lines.forEach((line, i) => {
    for (const p of VALUE_PATTERNS) {
      if (!p.re.test(line)) continue;
      if (PLACEHOLDER.test(line)) continue;
      findings.push({ path, line: i + 1, kind: p.name, why: "credential-shaped value in staged content" });
    }
  });
  return findings;
}

/**
 * The verdict over every staged file.
 *
 * EXAMINING ZERO FILES EXITS 2, never 0. A hook that examined nothing - because
 * the diff could not be read, or the repo path was wrong - must never read as a
 * clean commit. This machine has produced that failure in four separate tools
 * this week; here it would be the one that lets a key through.
 */
export function verdict(fileResults) {
  const rows = fileResults ?? [];
  const findings = rows.flatMap((r) => r.findings ?? []);
  return {
    examined: rows.length,
    findings,
    exitCode: rows.length === 0 ? 2 : findings.length ? 1 : 0,
  };
}
