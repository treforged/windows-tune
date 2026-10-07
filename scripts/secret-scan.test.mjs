import test from "node:test";
import assert from "node:assert/strict";
import { scanContent, verdict } from "./secret-scan.mjs";

// Built at runtime, never as a literal: a PEM header written out in full is
// credential-SHAPED, so the guard refuses the very commit that adds its own
// tests - and the obvious "fix" for that is to weaken the guard. Measured
// 2026-09-17: this file had been uncommittable for exactly that reason.
const DASH5 = "-".repeat(5);


// Built at runtime so this FILE never contains a credential-shaped literal -
// otherwise the guard would refuse the commit that adds its own tests, and the
// obvious "fix" would be to weaken the guard.
const key = (prefix, len = 40) => prefix + "A1b2C3d4E5".repeat(Math.ceil(len / 10)).slice(0, len);

test("an Anthropic key in staged content is refused", () => {
  const f = scanContent("bin/x.py", `API = "${key("sk-ant-api03-")}"`);
  assert.equal(f.length, 1);
  assert.equal(f[0].kind, "Anthropic key");
});

test("a GitHub token, a Groq key, an AWS id and a Slack token are all refused", () => {
  assert.equal(scanContent("a", key("ghp_", 36)).length, 1);
  assert.equal(scanContent("a", key("gsk_", 36)).length, 1);
  assert.equal(scanContent("a", "AKIA" + "ABCDEFGHIJKLMNOP").length, 1);
  assert.equal(scanContent("a", "xoxb-" + "1234567890abcdef").length, 1);
});

test("Stripe secret, restricted and webhook keys and an ElevenLabs key are refused", () => {
  // The 2026-10-06 gap: a staged Stripe live key committed clean.
  assert.deepEqual(scanContent("a", key("sk_" + "live_", 24)).map((f) => f.kind), ["Stripe secret key"]);
  assert.deepEqual(scanContent("a", key("sk_" + "test_", 24)).map((f) => f.kind), ["Stripe secret key"]);
  assert.deepEqual(scanContent("a", key("rk_" + "live_", 24)).map((f) => f.kind), ["Stripe secret key"]);
  assert.deepEqual(scanContent("a", key("whsec_", 32)).map((f) => f.kind), ["Stripe webhook secret"]);
  assert.deepEqual(scanContent("a", "sk_" + "0a1b2c3d4e5f".repeat(4)).map((f) => f.kind), ["ElevenLabs key"]);
});

test("a Stripe PUBLISHABLE key and ordinary snake_case are NOT refused", () => {
  assert.equal(scanContent("a", key("pk_" + "live_", 24)).length, 0);
  assert.equal(scanContent("a", "const task_live_status = desk_test_runner;").length, 0);
});

test("a PEM private key block is refused", () => {
  assert.equal(scanContent("a", DASH5 + "BEGIN RSA PRIVATE KEY" + DASH5).length, 1);
  assert.equal(scanContent("a", DASH5 + "BEGIN PRIVATE KEY" + DASH5).length, 1);
});

test("THE FILENAME ALONE IS ENOUGH - contents are not needed", () => {
  // A file called .credentials.json does not need inspecting to be refused, and
  // `git add -f llm-keys.env` is caught by this half even if the values inside
  // ever changed shape.
  assert.deepEqual(scanContent(".credentials.json", "").map((f) => f.kind), ["credentials file"]);
  assert.deepEqual(scanContent("bin/anything.env", "").map((f) => f.kind), ["env file"]);
  assert.deepEqual(scanContent("secrets/id_rsa", "").map((f) => f.kind), ["key file"]);
  // `llm-keys.env` matches BOTH the env-file and the keys-file pattern, and
  // reporting both is right rather than a duplicate: they are two independent
  // reasons to refuse, and a reader who fixes one should still see the other.
  // Asserting exactly one finding here was MY error, not the scanner's.
  assert.deepEqual(scanContent("llm-keys.env", "").map((f) => f.kind), ["env file", "keys file"]);
});

test("A DOCUMENTED EXAMPLE IS NOT A SECRET, or the hook is wrong on ordinary work", () => {
  // api-design/SKILL.md really does contain `Bearer eyJhbGciOiJIUzI1NiIs...`
  // and FREE-LLM-EXECUTORS.md shows each provider's key shape. A hook that is
  // wrong on ordinary files is a hook that gets --no-verify'd on the day it
  // matters.
  assert.deepEqual(scanContent("doc.md", "Authorization: Bearer eyJhbGciOiJIUzI1NiIs.eyJzdWIiOiIxMjM0NTY3ODkw..."), []);
  assert.deepEqual(scanContent("doc.md", `export KEY=${key("sk-ant-")} # EXAMPLE`), []);
  assert.deepEqual(scanContent("doc.md", "GROQ_API_KEY=<YOUR_KEY_HERE>"), []);
});

test("the placeholder escape is about the LINE, not the file it lives in", () => {
  // "this file is documentation" is exactly the excuse a real leak would hide
  // behind, so a real key in a .md is still a finding.
  assert.equal(scanContent("README.md", `KEY = "${key("sk-ant-api03-")}"`).length, 1);
});

test("ordinary code is not flagged", () => {
  assert.deepEqual(scanContent("bin/tool.py", "import os\nkey = os.environ['ANTHROPIC_API_KEY']"), []);
  assert.deepEqual(scanContent("a.md", "read the key from ~/.claude/llm-keys.env at runtime"), []);
});

test("EXAMINING ZERO FILES EXITS 2, never 0", () => {
  // A hook that examined nothing - unreadable diff, wrong repo path - must
  // never read as a clean commit. Here that failure would let a key through.
  assert.equal(verdict([]).exitCode, 2);
});

test("a clean set of staged files exits 0, a dirty one exits 1", () => {
  assert.equal(verdict([{ path: "a", findings: [] }]).exitCode, 0);
  assert.equal(verdict([{ path: "a", findings: [{ kind: "x" }] }]).exitCode, 1);
});

test("the count of files examined is reported, so a reader can check it", () => {
  const v = verdict([{ path: "a", findings: [] }, { path: "b", findings: [] }]);
  assert.equal(v.examined, 2);
});

// --- the vendors this machine actually uses -------------------------------
//
// ADDED 2026-09-17 AFTER A MEASURED MISS. A bare OpenRouter key was planted in a
// staged file beside an Anthropic one: the Anthropic line was refused and the
// OpenRouter line passed CLEAN, because the OpenAI-style rule requires
// alphanumerics after `sk-` and an OpenRouter key is `sk-or-v1-<hex>`.
// OpenRouter is one of the keys that really did leak into this machine's git
// history, so this was never a hypothetical shape.
//
// EVERY VALUE HERE IS BUILT AT RUNTIME from repeat(), never written as a
// literal. Otherwise this file would itself carry credential-shaped text, the
// guard would refuse the very commit that adds its own tests, and the obvious
// "fix" would be to weaken the guard.

test("the vendor prefixes this machine uses are all detected", () => {
  const cases = [
    ["OpenRouter key", "sk-or-v1-" + "b".repeat(60)],
    ["Cerebras key", "csk-" + "d".repeat(40)],
    ["Resend key", "re_" + "e".repeat(30)],
    ["Anthropic key", "sk-ant-" + "a".repeat(40)],
  ];
  for (const [kind, value] of cases) {
    const found = scanContent("staged.txt", value + "\n");
    assert.ok(found.length > 0, kind + " was NOT detected - this is the miss the rule exists for");
    assert.ok(
      found.some((f) => f.kind === kind),
      "expected " + kind + ", got " + (found.map((f) => f.kind).join(",") || "nothing"),
    );
  }
});

// NEGATIVE CONTROLS, and they are load-bearing. A rule that flags everything
// passes every positive case perfectly, and a guard that is wrong on ordinary
// work is one somebody --no-verify's on the day it would have caught something.
test("a documented example and ordinary code are NOT refused", () => {
  assert.equal(
    scanContent("docs.md", "sk-or-v1-" + "b".repeat(60) + " ... EXAMPLE\n").length,
    0,
    "a placeholder line must pass - the escape keys on the LINE, not the file",
  );
  assert.equal(
    scanContent("app.ts", "const skipList = [1, 2, 3]; // re_exported helper\n").length,
    0,
    "ordinary code must not trip the re_ or sk- rules",
  );
});

// A STATED LIMIT, ASSERTED so nobody discovers it by being leaked. A Mistral key
// is 32 bare alphanumerics with no prefix - indistinguishable from a hash or an
// id - so it is covered by the FILENAME rule and .gitignore, never by content.
test("a Mistral-shaped value is NOT caught by content, and the filename rule covers it", () => {
  assert.equal(scanContent("notes.txt", "f".repeat(32) + "\n").length, 0);
  assert.ok(
    scanContent("llm-keys.env", "").length > 0,
    "the filename rule is what covers it instead",
  );
});
