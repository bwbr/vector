{
  description = "Vector development and build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system;
          overlays = overlays;
        };

        rustChannel = (builtins.fromTOML (builtins.readFile ./rust-toolchain.toml)).toolchain.channel;
        rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

        # Same set as REQUIRES_BINSTALL in scripts/environment/prepare.sh (pinned versions there).
        prepareCargoModules =
          "cargo-deb,cross,cargo-nextest,cargo-deny,cargo-msrv,cargo-hack,cargo-llvm-cov,dd-rust-license-tool,wasm-pack,vdev";

        mkShellHook =
          {
            prepareModules ? prepareCargoModules,
            runPrepare ? true,
          }:
          let
            stampSuffix = builtins.hashString "sha256" (
              prepareModules + (builtins.readFile ./scripts/environment/prepare.sh)
            );
            prepareStampForModules = "\${HOME}/.cache/vector/prepare-${stampSuffix}";
          in
          ''
            # Toolchain from Nix (reproducible). Cargo CLI tools from prepare.sh → ~/.cargo/bin (CI pins).
            export PATH="${rustToolchain}/bin:''${HOME}/.cargo/bin:''${PATH}"

            # cross calls `rustup toolchain list`; keep rustup available without overriding Nix cargo.
            export PATH="${pkgs.rustup}/bin:''${PATH}"
            rustup toolchain install "''${rustChannel}" --profile default 2>/dev/null || true

            export PKG_CONFIG_PATH="${
              pkgs.lib.makeSearchPath "lib/pkgconfig" [
                pkgs.openssl
                pkgs.zlib
                pkgs.cyrus_sasl
                pkgs.xxHash
              ]
            }"

            export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
            export PROTOC="${pkgs.protobuf}/bin/protoc"
            export RUSTFLAGS="''${RUSTFLAGS} -C link-arg=-fuse-ld=mold"
            export PATH="${./scripts/environment/npm-tools}/node_modules/.bin:''${PATH}"

            ${
              if runPrepare then
                ''
                  _prepare_stamp="${prepareStampForModules}"
                  if [[ ! -f "''${_prepare_stamp}" ]] || [[ -n "''${VECTOR_FORCE_PREPARE:-}" ]]; then
                    echo "Installing pinned cargo tools (prepare.sh + cargo-binstall, same as CI)..."
                    # Use Nix cargo/rustc (not rustup's) while prepare runs binstall/install.
                    (
                      export PATH="${rustToolchain}/bin:''${PATH}"
                      unset RUSTUP_TOOLCHAIN
                      ${pkgs.bash}/bin/bash ./scripts/environment/prepare.sh \
                        --modules=${prepareModules}
                    )
                    mkdir -p "$(dirname "''${_prepare_stamp}")"
                    touch "''${_prepare_stamp}"
                  fi
                ''
              else
                ""
            }

            # ~/.cargo/env prepends ~/.cargo/bin; keep Nix toolchain first.
            if [[ -f "''${HOME}/.cargo/env" ]]; then
              # shellcheck source=/dev/null
              source "''${HOME}/.cargo/env"
            fi
            export PATH="${rustToolchain}/bin:''${HOME}/.cargo/bin:''${PATH}"

            export VDEV="''${VDEV:-vdev}"

            echo "Vector dev shell (Rust ${rustChannel})"
            echo "  Toolchain: rust-overlay (flake) | cargo tools: prepare.sh → ~/.cargo/bin"
            echo "  Reinstall tools: VECTOR_FORCE_PREPARE=1 direnv reload"
          '';

        nativeDeps = with pkgs; [
          pkg-config
          openssl
          zlib
          cyrus_sasl
          llvmPackages.libclang
          llvmPackages.clang
          xxHash
          cmake
          perl
          python3
          mold
          protobuf
          autoconf
          automake
          libtool
          gnumake
          git
          curl
          unzip
          bash
        ];

        baseTools = with pkgs; [
          rustToolchain
          rustup
          cargo-binstall
          nodejs_22
          nixfmt-rfc-style
        ];
      in
      {
        devShells = {
          default = pkgs.mkShell {
            buildInputs = nativeDeps ++ baseTools;
            shellHook = mkShellHook { runPrepare = true; };
            OPENSSL_NO_VENDOR = 1;
          };

          build = pkgs.mkShell {
            buildInputs = nativeDeps ++ baseTools;
            shellHook = mkShellHook {
              prepareModules = "cross";
              runPrepare = true;
            };
            OPENSSL_NO_VENDOR = 1;
          };
        };

        packages.dev-shell = self.devShells.${system}.default;
        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
