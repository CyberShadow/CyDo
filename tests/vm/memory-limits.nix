{ pkgs, cydoTest, mockApiSrc, claude, testsSrc }:

pkgs.testers.runNixOSTest {
  name = "cydo-memory-limits";

  nodes.machine = { pkgs, ... }:
    let
      clientPython = pkgs.python3.withPackages (ps: [ ps.websockets ]);
      cydoEnv = {
        ANTHROPIC_BASE_URL = "http://127.0.0.1:9000";
        ANTHROPIC_API_KEY = "test-key-mock";
        CLAUDE_CONFIG_DIR = "/home/alice/.claude";
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
        CLAUDE_CODE_BASH_EDIT_DIFF = "1";
        DISABLE_TELEMETRY = "1";
        DISABLE_AUTOUPDATER = "1";
        OPENAI_BASE_URL = "http://127.0.0.1:9000/v1";
        OPENAI_API_KEY = "test-key-mock";
        CODEX_API_KEY = "";
        CODEX_HOME = "/home/alice/.codex";
        CLAUDE_CODE_ENTRYPOINT = "";
        CLAUDE_CODE_OAUTH_TOKEN = "";
        CYDO_REAL_CLAUDE_BIN = "";
        CYDO_CAPTURE_DIR = "";
        COPILOT_HOME = "";
        COPILOT_GITHUB_TOKEN = "";
        GH_TOKEN = "";
        GITHUB_TOKEN = "";
        COPILOT_MODEL = "";
        HTTPS_PROXY = "";
        NODE_TLS_REJECT_UNAUTHORIZED = "";
        CYDO_AUTH_USER = "";
        CYDO_AUTH_PASS = "";
        CYDO_LISTEN_PORT = "3940";
      };
      envArgs = pkgs.lib.mapAttrsToList (name: value: "${name}=${value}") cydoEnv;
    in {
      virtualisation = {
        memorySize = 4096;
        cores = 2;
      };
      # The NixOS test default of 2 panics on a cgroup OOM.
      boot.kernel.sysctl."vm.panic_on_oom" = 1;
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };
      environment.systemPackages = [ claude cydoTest pkgs.git pkgs.sqlite clientPython ];

      systemd.services.mock-api = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.nodejs_22}/bin/node ${mockApiSrc}/server.mjs";
        };
      };
      systemd.user.services.cydo = {
        path = [ pkgs.bash claude pkgs.coreutils pkgs.git ];
        environment = cydoEnv;
        serviceConfig = {
          ExecStart = "${cydoTest}/bin/cydo";
          Restart = "on-failure";
          RestartSec = 1;
        };
      };
      environment.etc = {
        "cydo-vm/config-base.yaml".source = testsSrc + "/e2e/test-config-base.yaml";
        "cydo-vm/cydo-client.py".source = ./cydo-client.py;
        "cydo-vm/environment.json".text = builtins.toJSON envArgs;
      };
    };

  testScript = builtins.readFile ./memory-limits.py;
}
