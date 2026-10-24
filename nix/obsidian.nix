# Obsidian 本体を、この vault のプラグインが実行時に必要とする外部コマンドごと配る。
#
# 配布物の .obsidian に入れたプラグインのうち2つは、Obsidian の中で完結せず PATH のコマンドを
# 呼ぶ: obsidian-git は git を、realclaudian は claude を要求する。素の `nix run nixpkgs#obsidian`
# ではそれらが PATH に無く、プラグインが無言で動かない。ここで1か所にまとめる。
#
# claude のログインは対話が要るのでここでは扱わない(bootstrap の担当)。
#
# pkgs は allowUnfree 済みであること(obsidian と claude-code はどちらも unfree)。
{ pkgs }:

pkgs.symlinkJoin {
  name = "obsidian-memex";
  paths = [ pkgs.obsidian ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/obsidian \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.claude-code ]} \
      --run ${pkgs.lib.escapeShellArg ''
        # WSLg の GPU ドライバ(d3d12 等)は /usr/lib/wsl/lib にあり nix の store には無い。
        # WSL のときだけ探索パスの末尾に足す(先頭に足すと store の同名ライブラリを食う)。
        if [ -d /usr/lib/wsl/lib ]; then
          export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/lib/wsl/lib"
        fi
      ''}
  '';

  meta = pkgs.obsidian.meta // {
    description = "Obsidian(memex-nix 版: git と claude を PATH に載せる)";
    mainProgram = "obsidian";
  };
}
