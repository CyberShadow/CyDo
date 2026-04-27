{
  description = "CyDo - Multi-agent orchestration with Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    screenshot-fixtures = {
      url = "git+file:docs/tools/screenshots/fixtures";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, screenshot-fixtures }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [(final: prev: {
          claude-code = prev.claude-code.overrideAttrs (old: rec {
            version = "2.1.97";
            src = prev.fetchzip {
              url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
              hash = "sha256-J92ILqBJmXyAueUPZ+HYZY0ls3OfN2EAhFyQHTOQF5A=";
            };
            npmDeps = prev.fetchNpmDeps {
              name = "claude-code-${version}-npm-deps";
              inherit src;
              postPatch = ''
                cp ${./nix/claude-code-package-lock.json} package-lock.json
              '';
              hash = "sha256-mCyWIb4RRoOuHUzrxFxvkL9oYTjzWihDO5uu7jOrBI8=";
            };
            postPatch = ''
              cp ${./nix/claude-code-package-lock.json} package-lock.json
              substituteInPlace cli.js \
                    --replace-fail '#!/bin/sh' '#!/usr/bin/env sh'
            '';
          });
        })];
        config = {
          allowUnfree = true;
          permittedInsecurePackages = [ "openssl-1.1.1w" ];
        };
      };

      lib = nixpkgs.lib;

      backendSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./source
          ./dub.sdl
          ./dub.selections.json
        ];
      };

      frontendSrc = lib.fileset.toSource {
        root = ./web;
        fileset = lib.fileset.unions [
          ./web/src
          ./web/index.html
          ./web/export.html
          ./web/package.json
          ./web/package-lock.json
          ./web/tsconfig.json
          ./web/vite.config.ts
          ./web/vite.export.config.ts
          ./web/vitest.config.ts
          ./web/eslint.config.mjs
          ./web/.prettierignore
        ];
      };

      screenshotSrc = lib.cleanSourceWith {
        src = ./docs/tools/screenshots;
        filter = _path: _type: true;
      };

      mockApiSrc = lib.cleanSourceWith {
        src = ./tests/mock-api;
        filter = _path: _type: true;
      };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          nodejs = pkgs.nodejs_22;

          # Codex CLI — pre-built static binary from npm
          codexVersion = "0.113.0";
          codexSrc = {
            x86_64-linux = {
              url = "https://registry.npmjs.org/@openai/codex/-/codex-${codexVersion}-linux-x64.tgz";
              hash = "sha256-SNe/LMuQDJJONocCnVeOjhG1UnABR9yUQRmc1kZb5SA=";
              triple = "x86_64-unknown-linux-musl";
            };
            aarch64-linux = {
              url = "https://registry.npmjs.org/@openai/codex/-/codex-${codexVersion}-linux-arm64.tgz";
              hash = "sha256-wyN9xBKGB6MGfY8YQViq2unvAeAFJiYwmb2SOfoyslc=";
              triple = "aarch64-unknown-linux-musl";
            };
          }.${system} or (throw "Codex CLI: unsupported system ${system}");

          codex-cli = pkgs.stdenv.mkDerivation {
            pname = "codex-cli";
            version = codexVersion;
            src = pkgs.fetchurl {
              inherit (codexSrc) url hash;
            };
            unpackPhase = ''
              tar xzf $src
            '';
            installPhase = ''
              mkdir -p $out/bin
              install -m755 package/vendor/${codexSrc.triple}/codex/codex $out/bin/codex
            '';
            meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
          };

          # Copilot CLI — pre-built binary from GitHub releases
          copilotVersion = "1.0.9";
          copilotSrc = {
            x86_64-linux = {
              url = "https://github.com/github/copilot-cli/releases/download/v${copilotVersion}/copilot-linux-x64.tar.gz";
              hash = "sha256-FwRLHgibSeqOuq142SRIuPbIw8YVHgSgmwuH41kvWD0=";
            };
            aarch64-linux = {
              url = "https://github.com/github/copilot-cli/releases/download/v${copilotVersion}/copilot-linux-arm64.tar.gz";
              hash = "sha256-YFaVWsztnMBG3xo4DSAPzlEAMTPLRCYUt34G8M7/yls=";
            };
          }.${system} or (throw "Copilot CLI: unsupported system ${system}");

          copilot-cli = pkgs.stdenv.mkDerivation {
            pname = "copilot-cli";
            version = copilotVersion;
            src = pkgs.fetchurl { inherit (copilotSrc) url hash; };
            dontStrip = true;
            dontPatchELF = true;
            dontFixup = true;
            unpackPhase = ''tar xzf $src'';
            installPhase = ''
              mkdir -p $out/bin $out/lib
              install -m755 copilot $out/lib/copilot
              INTERP=$(cat $NIX_CC/nix-support/dynamic-linker)
              LIB_PATH="${pkgs.lib.makeLibraryPath [
                pkgs.stdenv.cc.cc.lib
                pkgs.glibc
              ]}"
              cat > $out/bin/copilot <<EOF
#!/bin/sh
export COPILOT_RUN_APP=1
exec $INTERP --library-path $LIB_PATH $out/lib/copilot "\$@"
EOF
              chmod +x $out/bin/copilot
            '';
            meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
          };

          frontend = pkgs.buildNpmPackage {
            pname = "cydo-frontend";
            version = "0.1.0";
            src = frontendSrc;
            inherit nodejs;
            npmDepsHash = "sha256-QZaGClia0YVWk5IFBGRcP/qBSgiq01d/a20FkOZnXcA=";

            buildPhase = ''
              runHook preBuild
              npm run build
              npm run build:export
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/dist $out/dist-export
              cp -r dist/. $out/dist/
              cp -r dist-export/. $out/dist-export/
              runHook postInstall
            '';
          };

          backendCommon = {
            pname = "cydo";
            version = "0.1.0";
            src = backendSrc;

            dubLock = ./dub-lock.json;
            dontStrip = true;

            buildInputs = [ pkgs.sqlite pkgs.openssl_1_1 pkgs.zlib ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              install -Dm755 build/cydo $out/bin/
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Multi-agent orchestration with Claude Code";
              platforms = platforms.linux;
            };
          };

          protocol-codegen = pkgs.buildDubPackage {
            pname = "cydo-protocol-codegen";
            version = "0.1.0";
            src = backendSrc;
            dubLock = ./dub-lock.json;
            dontStrip = true;
            buildInputs = [ pkgs.openssl_1_1 pkgs.zlib ];

            buildPhase = ''
              runHook preBuild
              dub build cydo:protocol-codegen --skip-registry=all
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              install -Dm755 build/cydo_protocol-codegen $out/bin/protocol-codegen
              runHook postInstall
            '';
          };

          backend = pkgs.buildDubPackage (backendCommon // {
            dubBuildType = "release-debug";
          });

          backendDebug = pkgs.buildDubPackage (backendCommon // {
            dubBuildType = "debug";
          });

          mkCydo = backendPkg: { defs ? ./defs }: pkgs.stdenv.mkDerivation {
            pname = "cydo";
            version = "0.1.0";

            dontUnpack = true;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/cydo/web
              install -Dm755 ${backendPkg}/bin/cydo $out/share/cydo/
              cp -r ${frontend}/dist/. $out/share/cydo/web/dist/
              cp -r ${frontend}/dist-export/. $out/share/cydo/web/dist-export/
              cp -r ${defs}/. $out/share/cydo/defs/

              makeWrapper $out/share/cydo/cydo $out/bin/cydo
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Multi-agent orchestration with Claude Code";
              platforms = platforms.linux;
              mainProgram = "cydo";
            };
          };

          testDefs = pkgs.runCommand "cydo-test-defs" {} ''
            cp -r ${./defs} $out
            chmod -R u+w $out
            cp ${./tests/defs/task-types.yaml} $out/task-types.yaml
          '';

          cydo = mkCydo backend {};
          cydoDebug = mkCydo backendDebug {};
          cydoTest = mkCydo backendDebug { defs = testDefs; };

          fake-bwrap = pkgs.writeShellScript "bwrap" ''
            chdir=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --) shift; break ;;
                --setenv) export "$2=$3"; shift 3 ;;
                --chdir) chdir="$2"; shift 2 ;;
                --clearenv) shift ;;
                --bind|--ro-bind|--symlink|--dev|--proc|--tmpfs) shift 2 ;;
                *) shift ;;
              esac
            done
            [[ -n "$chdir" ]] && cd "$chdir"
            exec "$@"
          '';

          screenshots = pkgs.stdenv.mkDerivation {
            pname = "cydo-screenshots";
            version = "0.1.0";

            src = screenshotSrc;
            fixtures = screenshot-fixtures;
            inherit cydo;

            nativeBuildInputs = with pkgs; [
              playwright-test
              nodejs_22
              curl
              claude-code
              git
              sqlite
              websocat
            ];

            FONTCONFIG_FILE = pkgs.makeFontsConf {
              fontDirectories = with pkgs; [ roboto jetbrains-mono liberation_ttf ];
            };
            HOME = "/tmp/playwright-home";

            ANTHROPIC_BASE_URL = "http://127.0.0.1:9100";
            ANTHROPIC_API_KEY = "test-key-mock";
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
            DISABLE_TELEMETRY = "1";
            DISABLE_AUTOUPDATER = "1";
            CLAUDE_CONFIG_DIR = "/tmp/screenshot-claude-home";

            CYDO_AUTH_USER = "user";
            CYDO_AUTH_PASS = "screenshot";

            MOCK_SUGGESTIONS = ''["investigate the write latency regression", "add rate limiting to the websocket handler", "run the full test suite"]'';

            buildPhase = let
              fake-bwrap-local = pkgs.writeShellScript "bwrap" ''
                chdir=""
                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    --) shift; break ;;
                    --setenv) export "$2=$3"; shift 3 ;;
                    --chdir) chdir="$2"; shift 2 ;;
                    --clearenv) shift ;;
                    --bind|--ro-bind|--symlink|--dev|--proc|--tmpfs) shift 2 ;;
                    *) shift ;;
                  esac
                done
                [[ -n "$chdir" ]] && cd "$chdir"
                exec "$@"
              '';
            in ''
              mkdir -p /tmp/playwright-home

              # ── Claude CLI config ──────────────────────────────────────
              mkdir -p $CLAUDE_CONFIG_DIR
              cat > $CLAUDE_CONFIG_DIR/settings.json <<'SETTINGS'
              {"hasCompletedOnboarding":true,"theme":"dark","skipDangerousModePermissionPrompt":true,"autoUpdates":false}
              SETTINGS

              # ── Git workspaces ──────────────────────────────────────────
              for ws in \
                /tmp/ws/personal/dotfiles /tmp/ws/personal/k4webadmin \
                /tmp/ws/open-source/cydo /tmp/ws/open-source/ae /tmp/ws/open-source/dunamis /tmp/ws/open-source/graphqld2 /tmp/ws/open-source/dfeed \
                /tmp/ws/external/nixpkgs /tmp/ws/external/linux /tmp/ws/external/forgejo /tmp/ws/external/swayfx /tmp/ws/external/nix; do
                mkdir -p $ws
                cd $ws
                ${pkgs.git}/bin/git init -q
                ${pkgs.git}/bin/git config user.email "test@test"
                ${pkgs.git}/bin/git config user.name "Test"
                echo "test" > README.md
                ${pkgs.git}/bin/git add . && ${pkgs.git}/bin/git commit -qm "init"
              done

              # ── JSONL fixtures ─────────────────────────────────────────
              mkdir -p $CLAUDE_CONFIG_DIR/projects/-tmp-ws-open-source-cydo
              cp $fixtures/sessions/-tmp-ws-cydo/*.jsonl $CLAUDE_CONFIG_DIR/projects/-tmp-ws-open-source-cydo/
              # Reuse 1658's JSONL for the child-less conversation task (9060)
              cp $fixtures/sessions/-tmp-ws-cydo/ee043871-4594-412d-ae25-c41bc3774a02.jsonl \
                 $CLAUDE_CONFIG_DIR/projects/-tmp-ws-open-source-cydo/f8a23c01-7b9e-4d12-b5a4-c2e7d3f16890.jsonl
              chmod u+w $CLAUDE_CONFIG_DIR/projects/-tmp-ws-open-source-cydo/*.jsonl
              mkdir -p $CLAUDE_CONFIG_DIR/projects/-tmp-ws-open-source-ae
              cp $fixtures/sessions/-tmp-ws-ae/*.jsonl $CLAUDE_CONFIG_DIR/projects/-tmp-ws-open-source-ae/

              # ── fake-bwrap ─────────────────────────────────────────────
              mkdir -p /tmp/fake-bin
              ln -sf ${fake-bwrap-local} /tmp/fake-bin/bwrap
              export PATH="/tmp/fake-bin:$PATH"

              # ── CyDo workspace config ─────────────────────────────────
              mkdir -p /tmp/playwright-home/.config/cydo
              cat > /tmp/playwright-home/.config/cydo/config.yaml <<'CYDO_CFG'
              default_agent_type: claude
              workspaces:
                personal:
                  root: /tmp/ws/personal
                open-source:
                  root: /tmp/ws/open-source
                external:
                  root: /tmp/ws/external
              CYDO_CFG

              # ── Mock API ───────────────────────────────────────────────
              mkdir -p /tmp/mock-api
              cp ${mockApiSrc}/server.mjs /tmp/mock-api/
              cp ${mockApiSrc}/patterns.mjs /tmp/mock-api/

              MOCK_API_PORT=9100 MOCK_SUGGESTIONS="$MOCK_SUGGESTIONS" MOCK_STALL_SYSTEM=1 ${pkgs.nodejs_22}/bin/node /tmp/mock-api/server.mjs &
              MOCK_PID=$!
              for i in $(seq 1 15); do
                if curl -sf http://127.0.0.1:9100/api/hello >/dev/null 2>&1; then break; fi
                sleep 1
              done

              # ── Phase 1: Start CyDo to create DB schema ───────────────
              cd /tmp/ws/open-source/cydo
              CYDO_LISTEN_PORT=3950 ${cydo}/bin/cydo &
              CYDO_PID=$!
              for i in $(seq 1 30); do
                if curl -sf http://user:screenshot@127.0.0.1:3950/ >/dev/null 2>&1; then break; fi
                sleep 1
              done
              kill $CYDO_PID
              wait $CYDO_PID 2>/dev/null || true
              sleep 1

              # ── Phase 2: Seed database ─────────────────────────────────
              ${pkgs.sqlite}/bin/sqlite3 /tmp/playwright-home/.local/share/cydo/cydo.db < $fixtures/init.sql

              # ── Phase 3: Restart CyDo with seeded data ────────────────
              CYDO_LISTEN_PORT=3950 ${cydo}/bin/cydo &
              CYDO_PID=$!
              for i in $(seq 1 30); do
                if curl -sf http://user:screenshot@127.0.0.1:3950/ >/dev/null 2>&1; then break; fi
                sleep 1
              done
              # Give time for alive/waiting/active tasks to resume
              sleep 5

              # Send "stall session" to waiting chain tasks via WebSocket.
              # This makes their claude processes call the mock API, which stalls,
              # setting isProcessing=true — required for the "waiting" sidebar icon.
              printf '%s\n%s\n%s\n%s\n' '{"type":"message","tid":1658,"content":[{"type":"text","text":"stall session"}]}' '{"type":"message","tid":1676,"content":[{"type":"text","text":"stall session"}]}' '{"type":"message","tid":1677,"content":[{"type":"text","text":"stall session"}]}' '{"type":"message","tid":1700,"content":[{"type":"text","text":"stall session"}]}' \
                | ${pkgs.websocat}/bin/websocat -n ws://user:screenshot@127.0.0.1:3950/ws &
              WSCAT_PID=$!
              # Wait for the stall to take effect (API calls reach mock, isProcessing=true)
              sleep 3
              kill $WSCAT_PID 2>/dev/null || true

              # ── Capture screenshots ────────────────────────────────────
              mkdir -p /tmp/screenshots
              export CYDO_PORT=3950
              export SCREENSHOT_OUTPUT=/tmp/screenshots

              cp -r $src /tmp/capture
              chmod -R u+w /tmp/capture
              cd /tmp/capture
              playwright test capture.spec.ts || CAPTURE_RESULT=$?

              # ── Cleanup ────────────────────────────────────────────────
              kill $CYDO_PID 2>/dev/null || true
              kill $MOCK_PID 2>/dev/null || true
              wait $CYDO_PID 2>/dev/null || true
              wait $MOCK_PID 2>/dev/null || true

              if [ "''${CAPTURE_RESULT:-0}" != "0" ]; then
                echo "Screenshot capture failed with exit code ''${CAPTURE_RESULT}"
                exit 1
              fi
            '';

            installPhase = ''
              mkdir -p $out/docs/screenshots
              cp /tmp/screenshots/*.png $out/docs/screenshots/
            '';
          };
        in
        {
          inherit frontend backend backendDebug protocol-codegen codex-cli copilot-cli cydo cydoDebug cydoTest fake-bwrap screenshots;
          default = cydo;
        });

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          cydo = self.packages.${system}.default;
          cydoDebug = self.packages.${system}.cydoTest;
          codex = self.packages.${system}.codex-cli;
          copilot = self.packages.${system}.copilot-cli;

          # Fake bwrap that strips sandbox flags and exec's the inner command.
          # Real bwrap can't run inside Nix's build sandbox.
          fake-bwrap = pkgs.writeShellScript "bwrap" ''
            chdir=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --) shift; break ;;
                --setenv) export "$2=$3"; shift 3 ;;
                --chdir) chdir="$2"; shift 2 ;;
                --clearenv) shift ;;
                --symlink|--dev|--proc|--tmpfs) shift 2 ;;
                --bind|--ro-bind)
                  if [ ! -e "$2" ]; then
                    echo "bwrap: Can't find source path $2: No such file or directory" >&2
                    exit 1
                  fi
                  shift 2
                  ;;
                *) shift ;;
              esac
            done
            [[ -n "$chdir" ]] && cd "$chdir"
            exec "$@"
          '';

          fail-claude = pkgs.writeShellScript "fail-claude" ''
            echo "Error: simulated process failure for testing" >&2
            exit 1
          '';

        in
        let
          mkIntegrationTest = {
            name,
            testMatch,
            agentType,
            claudeBin ? null,
            extraNativeBuildInputs ? [],
          }: pkgs.stdenv.mkDerivation {
            pname = "cydo-integration-${name}";
            version = "0.1.0";
            src = ./tests;

            nativeBuildInputs = with pkgs; [
              playwright-test
              nodejs_22
              curl
              claude-code
              codex
              git
              sqlite
            ] ++ extraNativeBuildInputs;

            FONTCONFIG_FILE = pkgs.makeFontsConf {
              fontDirectories = with pkgs; [ roboto jetbrains-mono liberation_ttf ];
            };
            HOME = "/tmp/playwright-home";

            ANTHROPIC_BASE_URL = "http://127.0.0.1:9000";
            ANTHROPIC_API_KEY = "test-key-mock";
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
            DISABLE_TELEMETRY = "1";
            DISABLE_AUTOUPDATER = "1";
            CLAUDE_CONFIG_DIR = "/tmp/claude-test-home";

            OPENAI_BASE_URL = "http://127.0.0.1:9000/v1";
            OPENAI_API_KEY = "test-key-mock";
            CODEX_HOME = "/tmp/codex-test-home";
            CYDO_CODEX_COMPACT_LIMIT = "100";

            # Fixed port env vars — fixtures inherit these
            CYDO_LISTEN_PORT = "3940";
            CYDO_LOG_LEVEL = "trace";
            CYDO_AUTH_USER = "";
            CYDO_AUTH_PASS = "";

            buildPhase = ''
              mkdir -p /tmp/playwright-home

              mkdir -p $CLAUDE_CONFIG_DIR
              cat > $CLAUDE_CONFIG_DIR/settings.json <<'SETTINGS'
              {"hasCompletedOnboarding":true,"theme":"dark","skipDangerousModePermissionPrompt":true,"autoUpdates":false}
              SETTINGS

              mkdir -p $CODEX_HOME
              cat > $CODEX_HOME/config.toml <<'CODEXCFG'
              model = "codex-mini-latest"
              approval_mode = "full-auto"
              CODEXCFG

              mkdir -p /tmp/cydo-test-workspace
              mkdir -p /tmp/cydo-test-workspace/.claude
              cd /tmp/cydo-test-workspace
              ${pkgs.git}/bin/git init -q
              ${pkgs.git}/bin/git config user.email "test@test"
              ${pkgs.git}/bin/git config user.name "Test"
              echo "test" > README.md
              ${pkgs.git}/bin/git add . && ${pkgs.git}/bin/git commit -qm "init"

              ${pkgs.nodejs_22}/bin/node $src/mock-api/server.mjs &
              MOCK_PID=$!
              for i in $(seq 1 15); do
                if curl -sf http://127.0.0.1:9000/api/hello >/dev/null 2>&1; then break; fi
                if ! kill -0 $MOCK_PID 2>/dev/null; then echo "Mock API server died"; exit 1; fi
                sleep 1
              done
              echo "Mock API server ready on port 9000"

              ${lib.optionalString (agentType == "copilot") ''
              mkdir -p /tmp/copilot-test-home
              export COPILOT_HOME=/tmp/copilot-test-home

              node $src/mock-api/copilot-proxy.mjs &
              COPILOT_PROXY_PID=$!
              for i in $(seq 1 30); do
                if curl -s http://127.0.0.1:9001/ >/dev/null 2>&1; then break; fi
                sleep 0.5
              done

              export HTTPS_PROXY=http://127.0.0.1:9001
              export NODE_TLS_REJECT_UNAUTHORIZED=0
              export COPILOT_GITHUB_TOKEN=gho_mock_oauth_token
              ''}

              mkdir -p /tmp/fake-bin
              ln -sf ${fake-bwrap} /tmp/fake-bin/bwrap
              ln -sf ${fail-claude} /tmp/fake-bin/fail-claude
              export PATH="/tmp/fake-bin:$PATH"
              ${if claudeBin != null then "export CYDO_CLAUDE_BIN=\"${claudeBin}\"" else ""}

              ${lib.optionalString (agentType == "copilot") ''
              ln -sf ${copilot}/bin/copilot /tmp/fake-bin/copilot
              ''}

              mkdir -p /tmp/playwright-home/.config/cydo
              cat > /tmp/playwright-home/.config/cydo/config.yaml <<CYDO_CFG
              default_agent_type: ${agentType}
              workspaces:
                local:
                  root: /tmp/cydo-test-workspace
              CYDO_CFG

              export CYDO_BIN="${cydoDebug}/bin/cydo"

              cp -r $src /tmp/tests
              chmod -R u+w /tmp/tests
              chmod +x /tmp/tests/extra-fields-wrapper.sh
              chmod +x /tmp/tests/suggestion-one-shot-fail-wrapper.sh
              chmod +x /tmp/tests/title-one-shot-env-wrapper.sh
              cd /tmp/tests
              playwright test ${testMatch} --workers=1 || TEST_RESULT=$?

              kill $MOCK_PID 2>/dev/null || true
              wait $MOCK_PID 2>/dev/null || true

              ${lib.optionalString (agentType == "copilot") ''
              if [ -n "''${COPILOT_PROXY_PID:-}" ]; then
                kill $COPILOT_PROXY_PID 2>/dev/null || true
                wait $COPILOT_PROXY_PID 2>/dev/null || true
              fi
              ''}

              if [ "''${TEST_RESULT:-0}" != "0" ]; then
                echo "Tests failed with exit code ''${TEST_RESULT}"
                exit 1
              fi
            '';

            installPhase = ''
              mkdir -p $out
              echo "Tests passed" > $out/result
            '';
          };

          # Source for test listing — only test files + config needed for --list
          testListingSrc = lib.fileset.toSource {
            root = ./tests;
            fileset = lib.fileset.unions [
              ./tests/e2e
              ./tests/failure
              ./tests/playwright.config.ts
            ];
          };

          # IFD: enumerate all tests as a JSON manifest
          testManifest = pkgs.stdenv.mkDerivation {
            pname = "cydo-test-manifest";
            version = "0.1.0";
            src = testListingSrc;
            nativeBuildInputs = [ pkgs.playwright-test pkgs.nodejs_22 ];
            buildPhase = ''
              HOME=/tmp/pw-home
              mkdir -p $HOME
              playwright test --list --reporter=json > manifest.json 2>/dev/null || true
            '';
            installPhase = ''
              cp manifest.json $out
            '';
          };

          manifest = builtins.fromJSON (builtins.readFile testManifest);

          # Flatten suites → list of { file, line, title, projectName }
          allTests = lib.concatMap (suite:
            lib.concatMap (spec:
              map (t: {
                file = spec.file;
                line = spec.line;
                title = spec.title;
                projectName = t.projectName;
              }) spec.tests
            ) suite.specs
          ) manifest.suites;

          projectConfig = {
            claude  = { agentType = "claude"; claudeBin = null; extraNativeBuildInputs = []; };
            codex   = { agentType = "codex";  claudeBin = null; extraNativeBuildInputs = []; };
            copilot = { agentType = "copilot"; claudeBin = null; extraNativeBuildInputs = [ copilot ]; };
            failure = { agentType = "claude"; claudeBin = "fail-claude"; extraNativeBuildInputs = []; };
          };

          specStem = file: lib.removeSuffix ".spec.ts" file;

          testAttrName = t:
            "e2e-${t.projectName}-${specStem t.file}-L${toString t.line}";

          testChecks = lib.listToAttrs (map (t:
            let
              cfg = projectConfig.${t.projectName};
            in lib.nameValuePair (testAttrName t) (mkIntegrationTest {
              name = "${t.projectName}-${specStem t.file}-L${toString t.line}";
              # t.file is relative to the default testDir (./e2e).
              # Prepend "e2e/" then normalize away any "e2e/../" prefix.
              testMatch =
                let raw = "e2e/${t.file}:${toString t.line}";
                    normalized = builtins.replaceStrings ["e2e/../"] [""] raw;
                in "${normalized} --project=${t.projectName}";
              inherit (cfg) agentType claudeBin extraNativeBuildInputs;
            })
          ) allTests);
        in
        pkgs.lib.optionalAttrs pkgs.stdenv.isLinux ({
          unittests = pkgs.buildDubPackage {
            pname = "cydo-unittests";
            version = "0.1.0";
            src = backendSrc;

            dubLock = ./dub-lock.json;

            nativeBuildInputs = [ pkgs.git ];
            buildInputs = [ pkgs.sqlite pkgs.openssl_1_1 pkgs.zlib ];

            # Provide git identity so worktree unit tests can create commits.
            GIT_AUTHOR_NAME = "CyDo Test";
            GIT_AUTHOR_EMAIL = "test@example.com";
            GIT_COMMITTER_NAME = "CyDo Test";
            GIT_COMMITTER_EMAIL = "test@example.com";

            buildPhase = ''
              runHook preBuild
              dub test --skip-registry=all
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              touch $out
              runHook postInstall
            '';
          };
          typecheck = pkgs.buildNpmPackage {
            pname = "cydo-typecheck";
            version = "0.1.0";
            src = frontendSrc;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-QZaGClia0YVWk5IFBGRcP/qBSgiq01d/a20FkOZnXcA=";

            buildPhase = ''
              runHook preBuild
              npx tsc --noEmit
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };
          lint = pkgs.buildNpmPackage {
            pname = "cydo-lint";
            version = "0.1.0";
            src = frontendSrc;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-QZaGClia0YVWk5IFBGRcP/qBSgiq01d/a20FkOZnXcA=";

            buildPhase = ''
              runHook preBuild
              npx eslint src/
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };
          format = pkgs.buildNpmPackage {
            pname = "cydo-format-check";
            version = "0.1.0";
            src = frontendSrc;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-QZaGClia0YVWk5IFBGRcP/qBSgiq01d/a20FkOZnXcA=";

            buildPhase = ''
              runHook preBuild
              npx prettier --check src/
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };
          protocol-types-fresh = pkgs.stdenv.mkDerivation {
            pname = "cydo-protocol-types-fresh";
            version = "0.1.0";
            src = frontendSrc;

            nativeBuildInputs = [ self.packages.${system}.protocol-codegen ];

            buildPhase = ''
              runHook preBuild
              protocol-codegen generated-fresh.ts
              if ! diff -u src/generated/protocol.ts generated-fresh.ts; then
                echo ""
                echo "Protocol types are stale — run \`npm run generate\` in web/ and commit the result."
                exit 1
              fi
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };
          frontend-unit-tests = pkgs.buildNpmPackage {
            pname = "cydo-frontend-unit-tests";
            version = "0.1.0";
            src = frontendSrc;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-QZaGClia0YVWk5IFBGRcP/qBSgiq01d/a20FkOZnXcA=";

            buildPhase = ''
              runHook preBuild
              npx vitest run
              runHook postBuild
            '';

            installPhase = ''
              touch $out
            '';
          };
        } // testChecks)
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/cydo";
          meta.description = "CyDo multi-agent orchestration system";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              git
              ldc
              dub
              nodejs_22
              sqlite
              openssl
              zlib
              pkg-config
              playwright-test
            ];
          };
        });
    };
}
