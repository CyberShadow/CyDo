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
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          nodejs = pkgs.nodejs_22;

          frontend = pkgs.buildNpmPackage {
            pname = "cydo-frontend";
            version = "0.1.0";
            src = ./web;
            inherit nodejs;
            npmDepsHash = "sha256-VLV2bM1qb9Um4msABMUi5svNGh689CEmbXYvz1+Qhu0=";

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
            src = ./.;

            dubLock = ./dub-lock.json;

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
          inherit frontend backend;
          default = backend;
        });

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          cydo = self.packages.${system}.default;

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
        pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          integration = pkgs.stdenv.mkDerivation {
            pname = "cydo-integration-test";
            version = "0.1.0";
            src = ./tests;

            nativeBuildInputs = with pkgs; [
              playwright-test
              nodejs_22
              curl
              claude-code
              git
            ];

            FONTCONFIG_FILE = pkgs.makeFontsConf {
              fontDirectories = [ pkgs.liberation_ttf ];
            };
            HOME = "/tmp/playwright-home";

            # Claude Code configuration — use mock API server
            ANTHROPIC_BASE_URL = "http://127.0.0.1:9000";
            ANTHROPIC_API_KEY = "test-key-mock";
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
            DISABLE_TELEMETRY = "1";
            DISABLE_AUTOUPDATER = "1";
            CLAUDE_CONFIG_DIR = "/tmp/claude-test-home";

            buildPhase = ''
              mkdir -p /tmp/playwright-home

              # Pre-create Claude config directory
              mkdir -p $CLAUDE_CONFIG_DIR
              cat > $CLAUDE_CONFIG_DIR/settings.json <<'SETTINGS'
              {"hasCompletedOnboarding":true,"theme":"dark","skipDangerousModePermissionPrompt":true,"autoUpdates":false}
              SETTINGS

              # Create a workspace directory with a git project for CyDo
              mkdir -p /tmp/cydo-test-workspace
              cd /tmp/cydo-test-workspace
              ${pkgs.git}/bin/git init -q
              ${pkgs.git}/bin/git config user.email "test@test"
              ${pkgs.git}/bin/git config user.name "Test"
              echo "test" > README.md
              ${pkgs.git}/bin/git add . && ${pkgs.git}/bin/git commit -qm "init"

              # 1. Start mock API server
              ${pkgs.nodejs_22}/bin/node $src/mock-api/server.mjs &
              MOCK_PID=$!
              for i in $(seq 1 15); do
                if curl -sf http://127.0.0.1:9000/api/hello >/dev/null 2>&1; then break; fi
                if ! kill -0 $MOCK_PID 2>/dev/null; then echo "Mock API server died"; exit 1; fi
                sleep 1
              done
              echo "Mock API server ready"

              # 2. Install fake bwrap (real bwrap can't run inside Nix sandbox)
              mkdir -p /tmp/fake-bin
              ln -sf ${fake-bwrap} /tmp/fake-bin/bwrap
              export PATH="/tmp/fake-bin:$PATH"

              # 3. Start CyDo backend
              ${cydo}/bin/cydo &
              CYDO_PID=$!
              for i in $(seq 1 30); do
                if curl -sf http://127.0.0.1:3456/ >/dev/null 2>&1; then break; fi
                if ! kill -0 $CYDO_PID 2>/dev/null; then echo "CyDo backend died"; exit 1; fi
                sleep 1
              done
              echo "CyDo backend ready"

              # 4. Run Playwright tests (copy to writable dir since Playwright writes test-results/)
              cp -r $src /tmp/tests
              chmod -R u+w /tmp/tests
              cd /tmp/tests
              playwright test --reporter=list || TEST_RESULT=$?

              # 5. Cleanup
              kill $CYDO_PID $MOCK_PID 2>/dev/null || true
              wait $CYDO_PID $MOCK_PID 2>/dev/null || true

              if [ "''${TEST_RESULT:-0}" != "0" ]; then
                echo "Tests failed with exit code ''${TEST_RESULT}"
                # Dump error context files for debugging
                find /tmp/tests/test-results -name '*.md' -exec echo "=== {} ===" \; -exec cat {} \; 2>/dev/null || true
                exit 1
              fi
            '';

            installPhase = ''
              mkdir -p $out
              echo "Tests passed" > $out/result
            '';
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
