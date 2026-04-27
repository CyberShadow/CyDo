import { describe, it, expect, beforeAll } from "vitest";
import { parseShellSemantic, mapShikiTokens } from "./shellSemantic";
import { tokenizeWithScopes } from "../highlight";
import type {
  ShellReadSemantic,
  ShellHeredocWriteSemantic,
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
      "/bin/zsh -lc 'sed -n '1,10p' Cargo.toml'",
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
