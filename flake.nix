{
  description = "CyDo - Multi-agent orchestration with Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      pkgsFor = system: import nixpkgs {
        inherit system;
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
          ./web/package.json
          ./web/package-lock.json
          ./web/tsconfig.json
          ./web/vite.config.ts
        ];
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

          frontend = pkgs.buildNpmPackage {
            pname = "cydo-frontend";
            version = "0.1.0";
            src = frontendSrc;
            inherit nodejs;
            npmDepsHash = "sha256-4b5H74iCWo+/3m0c5nNIAGefz4CxpQfj9+Fep6vil1o=";

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r dist/. $out/
              runHook postInstall
            '';
          };

          backend = pkgs.buildDubPackage {
            pname = "cydo";
            version = "0.1.0";
            src = backendSrc;

            dubLock = ./dub-lock.json;
            dubBuildType = "release-debug";
            dontStrip = true;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = [ pkgs.sqlite pkgs.openssl_1_1 ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/cydo/web
              install -Dm755 build/cydo $out/share/cydo/
              cp -r ${frontend}/. $out/share/cydo/web/dist/

              makeWrapper $out/share/cydo/cydo $out/bin/cydo \
                --run 'if [ ! -e web/dist ]; then mkdir -p web && ln -snf '"$out"'/share/cydo/web/dist web/dist; fi'
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Multi-agent orchestration with Claude Code";
              platforms = platforms.linux;
              mainProgram = "cydo";
            };
          };
        in
        {
          inherit frontend backend codex-cli;
          default = backend;
        });

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          cydo = self.packages.${system}.default;
          codex = self.packages.${system}.codex-cli;

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
                --bind|--ro-bind|--symlink|--dev|--proc|--tmpfs) shift 2 ;;
                *) shift ;;
              esac
            done
            [[ -n "$chdir" ]] && cd "$chdir"
            exec "$@"
          '';
        in
        let
          mkIntegrationTest = { name, testMatch }: pkgs.stdenv.mkDerivation {
            pname = "cydo-integration-${name}";
            version = "0.1.0";
            src = ./tests;
            taskTypeDocs = ./defs/task-types;

            nativeBuildInputs = with pkgs; [
              playwright-test
              nodejs_22
              curl
              claude-code
              codex
              git
            ];

            FONTCONFIG_FILE = pkgs.makeFontsConf {
              fontDirectories = [ pkgs.liberation_ttf ];
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
              cd /tmp/cydo-test-workspace
              ${pkgs.git}/bin/git init -q
              ${pkgs.git}/bin/git config user.email "test@test"
              ${pkgs.git}/bin/git config user.name "Test"
              echo "test" > README.md
              ${pkgs.git}/bin/git add . && ${pkgs.git}/bin/git commit -qm "init"

              mkdir -p /tmp/cydo-test-workspace/defs
              cp -r $taskTypeDocs /tmp/cydo-test-workspace/defs/task-types
              chmod -R u+w /tmp/cydo-test-workspace/defs/task-types

              ${pkgs.nodejs_22}/bin/node $src/mock-api/server.mjs &
              MOCK_PID=$!
              for i in $(seq 1 15); do
                if curl -sf http://127.0.0.1:9000/api/hello >/dev/null 2>&1; then break; fi
                if ! kill -0 $MOCK_PID 2>/dev/null; then echo "Mock API server died"; exit 1; fi
                sleep 1
              done
              echo "Mock API server ready"

              mkdir -p /tmp/fake-bin
              ln -sf ${fake-bwrap} /tmp/fake-bin/bwrap
              export PATH="/tmp/fake-bin:$PATH"

              ${cydo}/bin/cydo &
              CYDO_PID=$!
              for i in $(seq 1 30); do
                if curl -sf http://127.0.0.1:3456/ >/dev/null 2>&1; then break; fi
                if ! kill -0 $CYDO_PID 2>/dev/null; then echo "CyDo backend died"; exit 1; fi
                sleep 1
              done
              echo "CyDo backend ready"

              cp -r $src /tmp/tests
              chmod -R u+w /tmp/tests
              cd /tmp/tests
              playwright test --reporter=list ${testMatch} || TEST_RESULT=$?

              kill $CYDO_PID $MOCK_PID 2>/dev/null || true
              wait $CYDO_PID $MOCK_PID 2>/dev/null || true

              if [ "''${TEST_RESULT:-0}" != "0" ]; then
                echo "Tests failed with exit code ''${TEST_RESULT}"
                find /tmp/tests/test-results -name '*.md' -exec echo "=== {} ===" \; -exec cat {} \; 2>/dev/null || true
                exit 1
              fi
            '';

            installPhase = ''
              mkdir -p $out
              echo "Tests passed" > $out/result
            '';
          };
        in
        pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          unittests = pkgs.buildDubPackage {
            pname = "cydo-unittests";
            version = "0.1.0";
            src = backendSrc;

            dubLock = ./dub-lock.json;

            buildInputs = [ pkgs.sqlite pkgs.openssl_1_1 ];

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
          integration-claude = mkIntegrationTest {
            name = "claude";
            testMatch = "--project=claude";
          };
          integration-codex = mkIntegrationTest {
            name = "codex";
            testMatch = "--project=codex";
          };
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/cydo";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              ldc
              dub
              nodejs_22
              sqlite
              openssl
              pkg-config
            ];
          };
        });
    };
}
