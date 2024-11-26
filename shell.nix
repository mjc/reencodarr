{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  # nativeBuildInputs is usually what you want -- tools you need to run
  nativeBuildInputs = with pkgs.buildPackages; [
    erlang
    elixir
    elixir_ls

    git
    gh
    nodePackages.cspell

    # nix lang
    alejandra # nixos formatter
    nil # nix language server

    inotify-tools
  ];
  shellHook = ''
    gh auth switch --user mjc
    export ERL_AFLAGS="-kernel shell_history enabled"
    export DATABASE_URL="ecto://mjc@localhost:5432/reencodarr_dev"
    # note this is not the prod one for real, just for testing.
    export SECRET_KEY_BASE="WEWsPGIpK/OgJA2ZcwzsgZxWKSAp35IsqWPYsvSUmm5awBUGpvsVOcG2kkDteXR1"
  '';
}
