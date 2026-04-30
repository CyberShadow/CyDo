import { describe, it, expect, beforeAll } from "vitest";
import { parseShellSemantic, mapShikiTokens } from "./shellSemantic";
import { parseCommandSourceTree } from "./sourceTree";
import { tokenizeWithScopes } from "../highlight";
import type {
  ShellReadSemantic,
  ShellHeredocWriteSemantic,
  ShellDiffSemantic,
  ShellScriptExecSemantic,
} from "./shellSemantic";

// ---------------------------------------------------------------------------
// Scope-pinning tests (verify tokenizer layer produces correct roles)
// ---------------------------------------------------------------------------

describe("scope pinning: mapShikiTokens role assignment", () => {
  let cachedTokenize: (
    cmd: string,
  ) => Promise<import("../highlight").TokenWithScopes[][] | null>;

  beforeAll(() => {
    cachedTokenize = tokenizeWithScopes;
  });

  it("pipe | in 'cat file | head' gets role pipe", async () => {
    const lines = await cachedTokenize("cat file | head");
    expect(lines).not.toBeNull();
    const tokens = mapShikiTokens(lines!);
    const pipeToken = tokens.find((t) => t.text === "|");
    expect(pipeToken?.role).toBe("pipe");
  });

  it("pipe | inside double-quoted string does NOT get role pipe", async () => {
    const lines = await cachedTokenize('echo "a | b"');
    expect(lines).not.toBeNull();
    const tokens = mapShikiTokens(lines!);
    // No token should have role pipe
    expect(tokens.filter((t) => t.role === "pipe")).toHaveLength(0);
  });

  it("&& in 'cd foo && cat bar' gets role and", async () => {
    const lines = await cachedTokenize("cd foo && cat bar");
    expect(lines).not.toBeNull();
    const tokens = mapShikiTokens(lines!);
    const andToken = tokens.find((t) => t.role === "and");
    expect(andToken).toBeDefined();
    expect(andToken?.text).toBe("&&");
  });

  it("cat gets role command", async () => {
    const lines = await cachedTokenize("cat README.md");
    expect(lines).not.toBeNull();
    const tokens = mapShikiTokens(lines!);
    const cmdToken = tokens.find((t) => t.role === "command");
    expect(cmdToken?.text).toBe("cat");
  });

  it("-n flag gets role flag", async () => {
    const lines = await cachedTokenize("head -n 50 file.txt");
    expect(lines).not.toBeNull();
    const tokens = mapShikiTokens(lines!);
    const flagToken = tokens.find((t) => t.role === "flag");
    expect(flagToken?.text).toBe("-n");
  });
});

// ---------------------------------------------------------------------------
// Accepted read forms
// ---------------------------------------------------------------------------

describe("cat reads", () => {
  it("cat README.md → read with filePath", async () => {
    const r = await parseShellSemantic("cat README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "all" });
    expect(v.presentation.lineNumbers).toBe(false);
  });

  it("cat -- README.md → read", async () => {
    const r = await parseShellSemantic("cat -- README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });
});

describe("nl reads", () => {
  it("nl -ba -w 4 -s ': ' source/app.d → read with lineNumbers presentation", async () => {
    const r = await parseShellSemantic("nl -ba -w 4 -s ': ' source/app.d");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("source/app.d");
    expect(v.presentation.lineNumbers).toMatchObject({
      style: "nl",
      width: 4,
      separator: ": ",
    });
  });
});

describe("sed reads", () => {
  it("sed -n '10,20p' web/src/main.tsx → read with lines range", async () => {
    const r = await parseShellSemantic("sed -n '10,20p' web/src/main.tsx");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("web/src/main.tsx");
    expect(v.range).toEqual({ type: "lines", start: 10, end: 20 });
  });
});

describe("head reads", () => {
  it("head -n 25 README.md → read with head range", async () => {
    const r = await parseShellSemantic("head -n 25 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "head", count: 25 });
  });

  it("head README.md → read with default range (Codex parity)", async () => {
    const r = await parseShellSemantic("head README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "all" });
  });

  it("head -n50 Cargo.toml → read with no space (Codex parity)", async () => {
    const r = await parseShellSemantic("head -n50 Cargo.toml");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("Cargo.toml");
    expect(v.range).toEqual({ type: "head", count: 50 });
  });
});

describe("tail reads", () => {
  it("tail -n +40 README.md → read with tail range", async () => {
    const r = await parseShellSemantic("tail -n +40 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail", startLine: 40 });
  });

  it("tail -n+10 README.md → read with no space (Codex parity)", async () => {
    const r = await parseShellSemantic("tail -n+10 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail", startLine: 10 });
  });

  it("tail -n 30 README.md → read with tail-count range (v2 parity)", async () => {
    const r = await parseShellSemantic("tail -n 30 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail-count", count: 30 });
  });

  it("tail README.md → read with all range", async () => {
    const r = await parseShellSemantic("tail README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "all" });
  });
});

// ---------------------------------------------------------------------------
// Pipeline reads
// ---------------------------------------------------------------------------

describe("pipe reads (should succeed as Read)", () => {
  it("cat file.txt | head -5 → read with filePath file.txt", async () => {
    const r = await parseShellSemantic("cat file.txt | head -5");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.kind).toBe("read");
    expect(v.filePath).toBe("file.txt");
  });

  it("cat tui/Cargo.toml | sed -n '1,200p' → read with filePath tui/Cargo.toml", async () => {
    const r = await parseShellSemantic("cat tui/Cargo.toml | sed -n '1,200p'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("tui/Cargo.toml");
  });

  it("nl -ba src/main.rs | sed -n '1200,1720p' → read with filePath src/main.rs", async () => {
    const r = await parseShellSemantic(
      "nl -ba src/main.rs | sed -n '1200,1720p'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.rs");
  });

  it("sed -n '260,640p' src/main.rs | nl -ba → read with filePath src/main.rs", async () => {
    const r = await parseShellSemantic(
      "sed -n '260,640p' src/main.rs | nl -ba",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.rs");
  });

  it("cat file.txt | wc -l → read (wc is always-formatting)", async () => {
    const r = await parseShellSemantic("cat file.txt | wc -l");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("file.txt");
  });

  it("cat file.txt | sort | head -5 → read (sort+head without file are formatting)", async () => {
    const r = await parseShellSemantic("cat file.txt | sort | head -5");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("file.txt");
  });
});

describe("pipe reads (should reject)", () => {
  it("cat file.txt | rm -rf / → reject (rm is not formatting)", async () => {
    const r = await parseShellSemantic("cat file.txt | rm -rf /");
    expect(r.ok).toBe(false);
  });

  it("echo hello | cat → reject (no primary file operand)", async () => {
    const r = await parseShellSemantic("echo hello | cat");
    expect(r.ok).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// cd + read patterns
// ---------------------------------------------------------------------------

describe("cd && read (should succeed)", () => {
  it("cd foo && cat file.txt → read with path foo/file.txt", async () => {
    const r = await parseShellSemantic("cd foo && cat file.txt");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("foo/file.txt");
  });

  it("cd dir1 && cd dir2 && cat file.txt → read with path dir1/dir2/file.txt", async () => {
    const r = await parseShellSemantic("cd dir1 && cd dir2 && cat file.txt");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("dir1/dir2/file.txt");
  });
});

describe("cd && read (should reject)", () => {
  it("cd foo && echo hello → reject (echo is not a read command)", async () => {
    const r = await parseShellSemantic("cd foo && echo hello");
    expect(r.ok).toBe(false);
  });

  it("cd foo && cat file.txt && echo done → reject (trailing command)", async () => {
    const r = await parseShellSemantic("cd foo && cat file.txt && echo done");
    expect(r.ok).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Accepted heredoc write forms
// ---------------------------------------------------------------------------

describe("heredoc writes", () => {
  it("cat > README.md <<EOF\\n# Title\\nEOF → write", async () => {
    const cmd = "cat > README.md <<EOF\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const v = r.value as ShellHeredocWriteSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.heredoc.content).toBe("# Title");
    expect(v.heredoc.quoted).toBe(false);
  });

  it("cat <<'EOF' > README.md\\n# Title\\nEOF → write with quoted heredoc", async () => {
    const cmd = "cat <<'EOF' > README.md\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const v = r.value as ShellHeredocWriteSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.heredoc.quoted).toBe(true);
  });

  it("heredoc segments concatenate back to the original command", async () => {
    const cmd = "cat > README.md <<EOF\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellHeredocWriteSemantic;
    const reconstructed = v.segments.map((s) => s.text).join("");
    expect(reconstructed).toBe(cmd);
  });

  it("quoted heredoc segments concatenate back to the original command", async () => {
    const cmd = "cat <<'EOF' > README.md\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellHeredocWriteSemantic;
    const reconstructed = v.segments.map((s) => s.text).join("");
    expect(reconstructed).toBe(cmd);
  });
});

// ---------------------------------------------------------------------------
// sh -c/-lc wrapper unwrapping (Codex commandExecution wraps commands this way)
// ---------------------------------------------------------------------------

describe("shell -c/-lc wrapper unwrapping", () => {
  it("sh -c 'cat README.md' → read", async () => {
    const r = await parseShellSemantic("sh -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("sh -c 'head -n 10 src/main.ts' → read with head range", async () => {
    const r = await parseShellSemantic("sh -c 'head -n 10 src/main.ts'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.ts");
    expect(v.range).toEqual({ type: "head", count: 10 });
  });

  it("bash -c 'cat README.md' → read", async () => {
    const r = await parseShellSemantic("bash -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("zsh -c 'cat README.md' → read", async () => {
    const r = await parseShellSemantic("zsh -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("zsh -lc 'cat README.md' → read (login shell flag)", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/bin/bash -c 'cat README.md' → read (absolute path)", async () => {
    const r = await parseShellSemantic("/bin/bash -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/bin/zsh -lc 'sed -n '1,10p' Cargo.toml' → read", async () => {
    const r = await parseShellSemantic(
      `/bin/zsh -lc "sed -n '1,10p' Cargo.toml"`,
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("Cargo.toml");
    expect(v.range).toEqual({ type: "lines", start: 1, end: 10 });
  });

  it("/run/current-system/sw/bin/zsh -c 'cat README.md' → read (NixOS path)", async () => {
    const r = await parseShellSemantic(
      "/run/current-system/sw/bin/zsh -c 'cat README.md'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/nix/store/abc-bash-5.2/bin/bash -lc 'head -n 5 file.ts' → read (Nix store path)", async () => {
    const r = await parseShellSemantic(
      "/nix/store/abc-bash-5.2/bin/bash -lc 'head -n 5 file.ts'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("file.ts");
    expect(v.range).toEqual({ type: "head", count: 5 });
  });
});

// ---------------------------------------------------------------------------
// Rejected forms
// ---------------------------------------------------------------------------

describe("rejected forms", () => {
  it("substitution: cat $(pwd)/README.md → reject", async () => {
    const r = await parseShellSemantic("cat $(pwd)/README.md");
    expect(r.ok).toBe(false);
  });

  it("variable: cat $FILE → reject", async () => {
    const r = await parseShellSemantic("cat $FILE");
    expect(r.ok).toBe(false);
  });

  it("multiple paths: cat README.md package.json → reject (multiple_paths)", async () => {
    const r = await parseShellSemantic("cat README.md package.json");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("multiple_paths");
  });

  it("redirection on read: cat README.md > out.txt → reject (redirection_on_read)", async () => {
    const r = await parseShellSemantic("cat README.md > out.txt");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("redirection_on_read");
  });

  it("invalid range: sed -n '20,10p' README.md → reject (invalid_range)", async () => {
    const r = await parseShellSemantic("sed -n '20,10p' README.md");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("invalid_range");
  });

  it("variable in heredoc: cat <<EOF > $FILE\\nhello\\nEOF → reject", async () => {
    const r = await parseShellSemantic("cat <<EOF > $FILE\nhello\nEOF");
    expect(r.ok).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// git diff / git show / git log -p / diff binary (ShellDiffSemantic)
// ---------------------------------------------------------------------------

describe("git diff commands (should succeed as diff)", () => {
  it("git diff → diff, subcommand: diff", async () => {
    const r = await parseShellSemantic("git diff");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.commandName).toBe("git");
    expect(v.subcommand).toBe("diff");
  });

  it("git diff HEAD~1 → diff", async () => {
    const r = await parseShellSemantic("git diff HEAD~1");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff --cached → diff", async () => {
    const r = await parseShellSemantic("git diff --cached");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff --staged → diff", async () => {
    const r = await parseShellSemantic("git diff --staged");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff branch1..branch2 → diff", async () => {
    const r = await parseShellSemantic("git diff branch1..branch2");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git show abc123 → diff, subcommand: show", async () => {
    const r = await parseShellSemantic("git show abc123");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.subcommand).toBe("show");
  });

  it("git log -p -1 → diff, subcommand: log", async () => {
    const r = await parseShellSemantic("git log -p -1");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.subcommand).toBe("log");
  });

  it("git log --patch -1 → diff", async () => {
    const r = await parseShellSemantic("git log --patch -1");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });
});

describe("diff binary (should succeed as diff)", () => {
  it("diff -u old.txt new.txt → diff, commandName: diff", async () => {
    const r = await parseShellSemantic("diff -u old.txt new.txt");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.commandName).toBe("diff");
  });

  it("diff file1 file2 → diff", async () => {
    const r = await parseShellSemantic("diff file1 file2");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });
});

describe("git show HEAD:file (should succeed as read)", () => {
  it("git show HEAD:src/main.ts → read, filePath: src/main.ts", async () => {
    const r = await parseShellSemantic("git show HEAD:src/main.ts");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.ts");
  });

  it("git show abc123:README.md → read, filePath: README.md", async () => {
    const r = await parseShellSemantic("git show abc123:README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
  });
});

describe("git diff pipelines (should succeed as diff)", () => {
  it("git diff | head -100 → diff (pipeline with formatting)", async () => {
    const r = await parseShellSemantic("git diff | head -100");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff | sed -n '1,260p' → diff (pipeline with formatting)", async () => {
    const r = await parseShellSemantic("git diff | sed -n '1,260p'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });
});

describe("unsupported git commands (should reject)", () => {
  it("git push origin main → reject", async () => {
    const r = await parseShellSemantic("git push origin main");
    expect(r.ok).toBe(false);
  });

  it("git commit -m 'msg' → reject", async () => {
    const r = await parseShellSemantic("git commit -m 'msg'");
    expect(r.ok).toBe(false);
  });

  it("git log (without -p) → reject", async () => {
    const r = await parseShellSemantic("git log");
    expect(r.ok).toBe(false);
  });
});

describe("shell wrapper with git/diff commands", () => {
  it("sh -c 'git diff' → diff", async () => {
    const r = await parseShellSemantic("sh -c 'git diff'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("bash -lc 'git show HEAD:file.ts' → read", async () => {
    const r = await parseShellSemantic("bash -lc 'git show HEAD:file.ts'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("file.ts");
  });
});

// ---------------------------------------------------------------------------
// Script execution — heredoc
// ---------------------------------------------------------------------------

describe("script-exec: heredoc", () => {
  it("python - <<'PY' → script-exec, language python", async () => {
    const cmd = "python - <<'PY'\nimport json\nprint(\"hi\")\nPY";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("python");
    expect(v.commandName).toBe("python");
    expect(v.scriptSource.type).toBe("heredoc");
    if (v.scriptSource.type === "heredoc") {
      expect(v.scriptSource.content).toBe('import json\nprint("hi")');
      expect(v.scriptSource.quoted).toBe(true);
      expect(v.scriptSource.delimiter).toBe("PY");
    }
  });

  it("python3 - <<'PYTHON' → script-exec, language python", async () => {
    const cmd = "python3 - <<'PYTHON'\nprint(\"hello\")\nPYTHON";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("python");
    expect(v.commandName).toBe("python3");
  });

  it("node - <<'JS' → script-exec, language javascript", async () => {
    const cmd = "node - <<'JS'\nconsole.log(42)\nJS";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("javascript");
    expect(v.commandName).toBe("node");
  });

  it("ruby - <<'RUBY' → script-exec, language ruby", async () => {
    const cmd = "ruby - <<'RUBY'\nputs \"hello\"\nRUBY";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("ruby");
  });

  it("ruby - <<RUBY (unquoted delimiter) → script-exec", async () => {
    const cmd = 'ruby - <<RUBY\nputs "hello"\nRUBY';
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    if (v.scriptSource.type === "heredoc") {
      expect(v.scriptSource.quoted).toBe(false);
    }
  });

  it("segments concatenate back to original command", async () => {
    const cmd = "python3 - <<'PY'\nprint(42)\nPY";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellScriptExecSemantic;
    const joined = v.segments.map((s) => s.text).join("");
    // header ends with \n, content is the body, footer starts with \n
    expect(joined).toBe("python3 - <<'PY'\nprint(42)\nPY");
  });
});

// ---------------------------------------------------------------------------
// Script execution — inline -c/-e
// ---------------------------------------------------------------------------

describe("script-exec: inline", () => {
  it("python3 -c '...' → script-exec, language python", async () => {
    const cmd = "python3 -c 'import sys; print(sys.version)'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("python");
    expect(v.scriptSource.type).toBe("inline");
    if (v.scriptSource.type === "inline") {
      expect(v.scriptSource.flag).toBe("-c");
      expect(v.scriptSource.content).toBe("import sys; print(sys.version)");
    }
  });

  it("node -e 'console.log(42)' → script-exec, language javascript", async () => {
    const cmd = "node -e 'console.log(42)'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("javascript");
    if (v.scriptSource.type === "inline") {
      expect(v.scriptSource.flag).toBe("-e");
    }
  });

  it("perl -e 'print \"hello\\n\"' → script-exec, language perl", async () => {
    const cmd = "perl -e 'print \"hello\\n\"'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("perl");
  });
});

// ---------------------------------------------------------------------------
// Script execution — rejections
// ---------------------------------------------------------------------------

describe("script-exec: rejections", () => {
  it("python script.py → reject (running a file, not embedding code)", async () => {
    const r = await parseShellSemantic("python script.py");
    expect(r.ok).toBe(false);
  });

  it("unknown_interpreter - <<'EOF' → reject (not in INTERPRETER_LANG)", async () => {
    const cmd = "unknown_interpreter - <<'EOF'\ncode\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(false);
  });
});

describe("source tree parsing and invariants", () => {
  it("quoted wrapper command parses to a root shell node with payload embed", () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc 'program --some-flag -y \"hello world\"'";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.value.language).toBe("bash");
    expect(parsed.value.text).toBe(cmd);
    const payload = parsed.value.segments.find((s) => s.kind === "embed");
    expect(payload?.kind).toBe("embed");
    if (!payload) return;
    expect(parsed.value.text.slice(payload.span.start, payload.span.end)).toBe(
      'program --some-flag -y "hello world"',
    );
    expect(payload.content.language).toBe("bash");
    expect(payload.content.text).toBe('program --some-flag -y "hello world"');
  });

  it("wrapper payload command remains semantic unsupported_command", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc 'program --some-flag -y \"hello world\"'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsupported_command");
  });

  it("wrapped python heredoc creates nested wrapper + heredoc embeds", () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"python - <<'PY'\nprint('x')\nPY\"";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find((s) => s.kind === "embed");
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;
    const heredoc = wrapper.content.segments.find((s) => s.kind === "embed");
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;
    expect(heredoc.escaping).toEqual({
      kind: "shell-heredoc",
      delimiter: "PY",
      quoted: true,
      supportsExitReentry: false,
    });
    expect(heredoc.content.language).toBe("python");
    expect(heredoc.content.text).toBe("print('x')");
    expect(parsed.value.text).toBe(cmd);
  });

  it("segment spans are offsets into each containing node text", () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    for (const segment of parsed.value.segments) {
      const parentSlice = parsed.value.text.slice(
        segment.span.start,
        segment.span.end,
      );
      expect(parentSlice.length).toBe(segment.span.end - segment.span.start);
      if (segment.kind === "embed") {
        expect(segment.content.text).toBe("# Title");
      }
    }
  });

  it("dynamic double-quoted wrapper payload rejects source-tree parsing", () => {
    const parsed = parseCommandSourceTree(
      '/run/current-system/sw/bin/zsh -lc "cat $HOME/README.md"',
    );
    expect(parsed.ok).toBe(false);
  });

  it("multiple heredocs and <<- remain rejected safely", () => {
    const multiple = parseCommandSourceTree("cat <<'A'\na\nA\ncat <<'B'\nb\nB");
    expect(multiple.ok).toBe(false);
    const tabs = parseCommandSourceTree("cat <<-EOF\nx\nEOF");
    expect(tabs.ok).toBe(false);
    const missing = parseCommandSourceTree("cat <<'EOF'\nhello");
    expect(missing.ok).toBe(false);
  });

  it("quoted << literal remains parseable and keeps search semantic behavior", async () => {
    const cmd = "rg -n '<<' web/src/lib/sourceTree.ts";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const semantic = await parseShellSemantic(cmd);
    expect(semantic.ok).toBe(true);
    if (!semantic.ok) return;
    expect(semantic.value.kind).toBe("search");
  });
});

describe("batch 1 wrapper quoting and heredoc source preservation", () => {
  it("zsh -cl wrapper is supported", async () => {
    const r = await parseShellSemantic("zsh -cl 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("single-quoted wrapper payload supports close/escape/reopen syntax", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat '\\''README.md'\\'''");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("single-quoted wrapper rejects adjacent payload pieces", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat README.md''x'");
    expect(r.ok).toBe(false);
  });

  it("conservative double-quoted wrapper rejects dynamic expansions", async () => {
    const bad = [
      '/run/current-system/sw/bin/zsh -lc "cat $HOME/README.md"',
      '/run/current-system/sw/bin/zsh -lc "cat $(pwd)/README.md"',
      '/run/current-system/sw/bin/zsh -lc "cat ${x}"',
      '/run/current-system/sw/bin/zsh -lc "cat `pwd`/README.md"',
    ];
    for (const cmd of bad) {
      const r = await parseShellSemantic(cmd);
      expect(r.ok).toBe(false);
    }
  });

  it("wrapped python heredoc preserves exact command and wrapper segments", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"python - <<'PY'\nprint('x')\nPY\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    expect(r.value.command).toBe(cmd);
    const joined = (r.value.inputSegments ?? []).map((s) => s.text).join("");
    expect(joined).toBe(cmd);
  });

  it("wrapped markdown heredoc with trailing ls -l && sed gets output plan", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"mkdir -p /tmp/a\ncat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\nls -l /tmp/a/output.md && sed -n '1,80p' /tmp/a/output.md\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    expect(r.value.outputPlan?.blocks.map((b: { id: string }) => b.id)).toEqual(
      ["listing", "sed-output"],
    );
    expect(r.value.outputPlan?.blocks[1]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
    const sourceTree = r.value.sourceTree;
    expect(sourceTree?.language).toBe("bash");
    const wrapper = sourceTree?.segments.find((s) => s.kind === "embed");
    expect(wrapper?.kind).toBe("embed");
    if (wrapper) {
      const heredoc = wrapper.content.segments.find((s) => s.kind === "embed");
      expect(heredoc?.kind).toBe("embed");
      if (heredoc) {
        expect(heredoc.content.language).toBe("markdown");
      }
    }
    expect((r.value.inputSegments ?? []).map((s) => s.kind)).toEqual([
      "wrapper-prefix",
      "command-header",
      "embedded-content",
      "heredoc-terminator",
      "command-trailing",
      "wrapper-suffix",
    ]);
    const joined = (r.value.inputSegments ?? []).map((s) => s.text).join("");
    expect(joined).toBe(cmd);
  });

  it("wrapped markdown heredoc with ls -1 dir has no markdown output plan", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"mkdir -p /tmp/a\ncat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\nls -1 /tmp/a\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    expect(r.value.outputPlan).toBeUndefined();
    const joined = (r.value.inputSegments ?? []).map((s) => s.text).join("");
    expect(joined).toBe(cmd);
  });

  it("escaped wrapper payload keeps heredoc body projection aligned", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"cat > /tmp/a\\\\b.md <<'EOF'\n# T\nEOF\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const writeBody = (r.value.inputSegments ?? []).find(
      (s) => s.kind === "embedded-content" && s.role === "write-content",
    );
    expect(writeBody?.text).toBe("# T");
    expect(r.value.embeddedContent?.[0]?.source.rawText).toBe("# T");
    const joined = (r.value.inputSegments ?? []).map((s) => s.text).join("");
    expect(joined).toBe(cmd);
  });

  it("heredoc body containing << does not trigger false multi-heredoc rejection", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"mkdir -p /tmp/a\ncat > /tmp/a/output.md <<'EOF'\nline with << inside body\nEOF\nls -1 /tmp/a\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("trailing quoted << literal after heredoc does not trigger false multi-heredoc rejection", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\necho '<<'";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const joined = (r.value.inputSegments ?? []).map((s) => s.text).join("");
    expect(joined).toBe(cmd);
  });

  it("trailing comment with << after heredoc does not trigger false multi-heredoc rejection", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\n# << comment";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("trailing ;# comment with << after heredoc does not trigger false multi-heredoc rejection", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\n:;# << comment";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("trailing here-string <<< after heredoc is not treated as second heredoc", async () => {
    const cmd =
      "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\ngrep foo <<< 'bar'";
    const parsed = parseCommandSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("unwrapped heredoc embedded-content source span points to body text", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    expect(r.value.embeddedContent?.[0]?.source.rawText).toBe("# Title");
  });
});

describe("batch 1 rg/sed/structured output plans", () => {
  it("supported rg -n emits search semantic and line-number plan", async () => {
    const r = await parseShellSemantic(
      'rg -n "formatGenericInput" web/src/components/ToolCall.tsx',
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("search");
    const v = r.value;
    expect(v.outputPlan?.blocks[0]?.id).toBe("rg-results");
    expect(v.outputPlan?.blocks[0]?.location).toEqual({
      kind: "whole-output",
      validator: "rg-line-number-prefixed",
    });
  });

  it("supported grep -n emits search semantic and line-number plan", async () => {
    const r = await parseShellSemantic(
      'grep -n "formatGenericInput" web/src/components/ToolCall.tsx',
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("search");
    const v = r.value;
    expect(v.outputPlan?.blocks[0]?.id).toBe("rg-results");
    expect(v.outputPlan?.blocks[0]?.location).toEqual({
      kind: "whole-output",
      validator: "rg-line-number-prefixed",
    });
  });

  it("unsupported rg forms reject", async () => {
    const bad = [
      "rg --json foo README.md",
      "rg -n foo .",
      "rg -n foo README.md package.json",
      "rg -n -A3 foo README.md",
      "rg -n --context=3 foo README.md",
      "rg -n --column foo README.md",
      "rg -n --with-filename foo README.md",
      "rg -n --color=always foo README.md",
      "rg -n --replace=bar foo README.md",
    ];
    for (const cmd of bad) {
      const r = await parseShellSemantic(cmd);
      expect(r.ok).toBe(false);
    }
  });

  it("single sed read includes whole-output plan", async () => {
    const r = await parseShellSemantic("sed -n '1,20p' README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect(r.value.outputPlan?.blocks[0]?.id).toBe("sed-output");
  });

  it("ls -l same-file && sed emits structured-output with listing + sed blocks", async () => {
    const r = await parseShellSemantic(
      "ls -l README.md && sed -n '1,20p' README.md",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const v = r.value;
    expect(v.outputPlan?.blocks.map((b: { id: string }) => b.id)).toEqual([
      "listing",
      "sed-output",
    ]);
    expect(v.outputPlan?.blocks[1]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("sed/printf multiline list emits unique-literal separator anchors", async () => {
    const cmd = [
      "sed -n '1,20p' /tmp/a.md",
      "printf '\\n--- spike ---\\n'",
      "sed -n '1,20p' /tmp/b.md",
    ].join("\n");
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const sedBlock = r.value.outputPlan?.blocks.find((b) => b.id === "sed-0");
    expect(sedBlock?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "before-block", blockId: "printf-1" },
      validator: "non-empty",
    });
    expect(
      r.value.outputPlan?.blocks.some(
        (b: { location: { kind: string } }) =>
          b.location.kind === "unique-literal",
      ),
    ).toBe(true);
  });

  it("printf conversion forms are not accepted in structured sed/printf lists", async () => {
    const cmd = [
      "sed -n '1,20p' /tmp/a.md",
      "printf '%s\\n'",
      "sed -n '1,20p' /tmp/b.md",
    ].join("\n");
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(false);
  });
});
