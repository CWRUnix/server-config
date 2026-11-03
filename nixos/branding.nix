{ inputs, pkgs, ... }:
let
  marketing = inputs.marketing.packages.${pkgs.system}.default;

  # The 10000px poster PNG is ~3 MB — far too heavy for a login page.
  # Downscale to a 1920-wide webp (~100 KB), dimmed + blurred so the login
  # card stays readable on top of it. The 500px logo is used as-is.
  # Tune to taste: -blur <radius>x<sigma>, -modulate <brightness pct>.
  brandAssets = pkgs.runCommand "cwrunix-brand-assets" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    mkdir -p $out
    cp ${marketing}/logo/solid-dark-500-logo.png $out/logo.png
    magick ${marketing}/posters/signs/solid-dark-10000-right.png \
      -resize 1920x -blur 0x6 -modulate 60,100 -quality 85 $out/bg.webp
  '';
in
{
  # Serve the club logo + login background next to authentik; the default
  # brand and the login flow point at these relative URLs (patched by the
  # ensure script — see nixos/ensure-source-on-login.py). Short cache: the
  # URLs are stable across deploys while the content can change.
  services.nginx.virtualHosts."authentik-zeus.cwrunix.com".locations."/branding/" = {
    alias = "${brandAssets}/";
    extraConfig = ''
      add_header Cache-Control "public, max-age=300";
    '';
  };
}
