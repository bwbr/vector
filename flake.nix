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
        runtimeLibs = with pkgs; [
          openssl
          zlib
          cyrus_sasl
          xxHash
        ];

        shellHook = ''
          export PATH="${rustToolchain}/bin:''${HOME}/.cargo/bin:''${PATH}"
          export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath runtimeLibs}:''${LD_LIBRARY_PATH:-}"

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
          for clang_include in "${pkgs.llvmPackages.libclang.lib}"/lib/clang/*/include; do
            export BINDGEN_EXTRA_CLANG_ARGS="-I''${clang_include} ''${BINDGEN_EXTRA_CLANG_ARGS:-}"
          done
          export PROTOC="${pkgs.protobuf}/bin/protoc"
          export RUSTFLAGS="''${RUSTFLAGS} -C link-arg=-fuse-ld=mold"
          export PATH="${./scripts/environment/npm-tools}/node_modules/.bin:''${PATH}"

          if [[ -f "''${HOME}/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "''${HOME}/.cargo/env"
          fi
          export PATH="${rustToolchain}/bin:''${HOME}/.cargo/bin:''${PATH}"

          echo "Vector dev shell (Rust ${rustChannel})"
          echo "  Toolchain: rust-overlay (flake)"
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
          nodejs_22
          nodePackages.prettier
          nixfmt-rfc-style
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = nativeDeps ++ baseTools;
          inherit shellHook;
          hardeningDisable = [ "fortify" ];
          OPENSSL_NO_VENDOR = 1;
        };

        packages.dev-shell = self.devShells.${system}.default;
        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
