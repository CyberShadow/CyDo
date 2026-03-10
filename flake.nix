{
  description = "CyDo - Multi-agent orchestration with Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nodejs = pkgs.nodejs_22;

          frontend = pkgs.buildNpmPackage {
            pname = "cydo-frontend";
            version = "0.1.0";
            src = ./web;
            inherit nodejs;
            npmDepsHash = "sha256-95uXrawmFzUdGYDTx9lifJxl7jtwP2NpapFPNV0TGvA=";

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
            buildInputs = [ pkgs.sqlite pkgs.openssl ];

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

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/cydo";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
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
