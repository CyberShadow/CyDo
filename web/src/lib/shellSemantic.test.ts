import { describe, it, expect } from "vitest";
import { parseShellSemantic } from "./shellSemantic";
import type {
  ShellReadSemantic,
  ShellHeredocWriteSemantic,
} from "./shellSemantic";

// ---------------------------------------------------------------------------
// Accepted read forms
// ---------------------------------------------------------------------------

describe("cat reads", () => {
  it("cat README.md → read with filePath", () => {
    const r = parseShellSemantic("cat README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "all" });
    expect(v.presentation.lineNumbers).toBe(false);
  });

  it("cat -- README.md → read", () => {
    const r = parseShellSemantic("cat -- README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });
});

describe("nl reads", () => {
  it("nl -ba -w 4 -s ': ' source/app.d → read with lineNumbers presentation", () => {
    const r = parseShellSemantic("nl -ba -w 4 -s ': ' source/app.d");
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
  it("sed -n '10,20p' web/src/main.tsx → read with lines range", () => {
    const r = parseShellSemantic("sed -n '10,20p' web/src/main.tsx");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("web/src/main.tsx");
    expect(v.range).toEqual({ type: "lines", start: 10, end: 20 });
  });
});

describe("head reads", () => {
  it("head -n 25 README.md → read with head range", () => {
    const r = parseShellSemantic("head -n 25 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "head", count: 25 });
  });

  it("head README.md → read with default range (Codex parity)", () => {
    const r = parseShellSemantic("head README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "all" });
  });

  it("head -n50 Cargo.toml → read with no space (Codex parity)", () => {
    const r = parseShellSemantic("head -n50 Cargo.toml");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("Cargo.toml");
    expect(v.range).toEqual({ type: "head", count: 50 });
  });
});

describe("tail reads", () => {
  it("tail -n +40 README.md → read with tail range", () => {
    const r = parseShellSemantic("tail -n +40 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail", startLine: 40 });
  });

  it("tail -n+10 README.md → read with no space (Codex parity)", () => {
    const r = parseShellSemantic("tail -n+10 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail", startLine: 10 });
  });
});

// ---------------------------------------------------------------------------
// Accepted heredoc write forms
// ---------------------------------------------------------------------------

describe("heredoc writes", () => {
  it("cat > README.md <<EOF\\n# Title\\nEOF → write", () => {
    const cmd = "cat > README.md <<EOF\n# Title\nEOF";
    const r = parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const v = r.value as ShellHeredocWriteSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.heredoc.content).toBe("# Title");
    expect(v.heredoc.quoted).toBe(false);
  });

  it("cat <<'EOF' > README.md\\n# Title\\nEOF → write with quoted heredoc", () => {
    const cmd = "cat <<'EOF' > README.md\n# Title\nEOF";
    const r = parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const v = r.value as ShellHeredocWriteSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.heredoc.quoted).toBe(true);
  });

  it("heredoc segments concatenate back to the original command", () => {
    const cmd = "cat > README.md <<EOF\n# Title\nEOF";
    const r = parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellHeredocWriteSemantic;
    const reconstructed = v.segments.map((s) => s.text).join("");
    expect(reconstructed).toBe(cmd);
  });

  it("quoted heredoc segments concatenate back to the original command", () => {
    const cmd = "cat <<'EOF' > README.md\n# Title\nEOF";
    const r = parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellHeredocWriteSemantic;
    const reconstructed = v.segments.map((s) => s.text).join("");
    expect(reconstructed).toBe(cmd);
  });
});

// ---------------------------------------------------------------------------
// sh -c '...' unwrapping (Codex commandExecution wraps commands this way)
// ---------------------------------------------------------------------------

describe("shell -c/-lc wrapper unwrapping", () => {
  it("sh -c 'cat README.md' → read", () => {
    const r = parseShellSemantic("sh -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("sh -c 'head -n 10 src/main.ts' → read with head range", () => {
    const r = parseShellSemantic("sh -c 'head -n 10 src/main.ts'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.ts");
    expect(v.range).toEqual({ type: "head", count: 10 });
  });

  it("bash -c 'cat README.md' → read", () => {
    const r = parseShellSemantic("bash -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("zsh -c 'cat README.md' → read", () => {
    const r = parseShellSemantic("zsh -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("zsh -lc 'cat README.md' → read (login shell flag)", () => {
    const r = parseShellSemantic("zsh -lc 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/bin/bash -c 'cat README.md' → read (absolute path)", () => {
    const r = parseShellSemantic("/bin/bash -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/bin/zsh -lc 'sed -n '1,10p' Cargo.toml' → read", () => {
    const r = parseShellSemantic("/bin/zsh -lc 'sed -n '1,10p' Cargo.toml'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("Cargo.toml");
    expect(v.range).toEqual({ type: "lines", start: 1, end: 10 });
  });

  it("/run/current-system/sw/bin/zsh -c 'cat README.md' → read (NixOS path)", () => {
    const r = parseShellSemantic(
      "/run/current-system/sw/bin/zsh -c 'cat README.md'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/nix/store/abc-bash-5.2/bin/bash -lc 'head -n 5 file.ts' → read (Nix store path)", () => {
    const r = parseShellSemantic(
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
  it("pipe: cat README.md | sed -n '1p' → reject (unsafe_shell_syntax)", () => {
    const r = parseShellSemantic("cat README.md | sed -n '1p'");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsafe_shell_syntax");
  });

  it("substitution: cat $(pwd)/README.md → reject", () => {
    const r = parseShellSemantic("cat $(pwd)/README.md");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsafe_shell_syntax");
  });

  it("variable: cat $FILE → reject", () => {
    const r = parseShellSemantic("cat $FILE");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsafe_shell_syntax");
  });

  it("multiple paths: cat README.md package.json → reject (multiple_paths)", () => {
    const r = parseShellSemantic("cat README.md package.json");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("multiple_paths");
  });

  it("redirection on read: cat README.md > out.txt → reject (redirection_on_read)", () => {
    const r = parseShellSemantic("cat README.md > out.txt");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("redirection_on_read");
  });

  it("invalid range: sed -n '20,10p' README.md → reject (invalid_range)", () => {
    const r = parseShellSemantic("sed -n '20,10p' README.md");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("invalid_range");
  });

  it("unsupported tail form: tail -n 20 README.md → reject (unsupported_option)", () => {
    const r = parseShellSemantic("tail -n 20 README.md");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsupported_option");
  });

  it("variable in heredoc: cat <<EOF > $FILE\\nhello\\nEOF → reject", () => {
    const r = parseShellSemantic("cat <<EOF > $FILE\nhello\nEOF");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsafe_shell_syntax");
  });
});
