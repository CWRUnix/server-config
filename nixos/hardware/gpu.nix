{ pkgs, ... }:
{
  # AMD GPU(s) in zeus. Kernel driver is amdgpu (early KMS for a sane
  # console); userspace is Mesa — RADV for Vulkan, radeonsi for GL. The
  # config is card-agnostic on purpose.
  #
  # Hardware history note: the box originally also had an AMD Instinct
  # MI60 (Vega 20) — a PASSIVELY-cooled 300W server card whose onboard
  # buzzer + red LED fired (understandably) in a desktop case with no
  # directed airflow. It was physically removed (2026-10); if a blower/
  # actively-cooled card goes in later, nothing here needs to change.
  # ROCm (compute stack) is not set up: the remaining RDNA1 card is
  # unsupported by ROCm; revisit if a gfx1100-class (or Instinct with
  # proper chassis airflow) card lands.
  boot.initrd.kernelModules = [ "amdgpu" ];

  # hardware.graphics (née hardware.opengl) populates /run/opengl-driver
  # with the Mesa build and the Vulkan/GL ICDs. nixpkgs' vulkan-loader and
  # libglvnd are patched to look there by default, so any nix-built binary
  # — including ones running in member sandboxes, which bind-mount that
  # dir (see sandbox/ (cwrunix-sandbox)) — finds the GPU drivers without any
  # environment plumbing. This is what makes GPU access driver-agnostic
  # for members: apps just open Vulkan/GL and Mesa handles the rest.
  hardware.graphics.enable = true;

  # GPU access is an OPT-IN member privilege, granted by LDAP group: the
  # "gpu" group exists locally with a pinned gid, and the same name+gid is
  # served by authentik's LDAP outpost (tofu/main.tf, authentik_group.gpu).
  # udev hands render nodes to it (headless Vulkan/GL/compute only needs
  # renderD*; card* — display/GBM master — stays with the defaults).
  # Members' sessions pick the group up via sssd initgroups at login; the
  # sandbox bind-mounts /dev/dri through (see sandbox/ (cwrunix-sandbox)).
  # To grant GPU: add the member to the "gpu" group in authentik.
  users.groups.gpu.gid = 2600; # pinned: must match the LDAP side exactly
  services.udev.extraRules = ''
    KERNEL=="renderD*", SUBSYSTEM=="drm", GROUP="gpu", MODE="0660"
  '';

  # vulkaninfo / glxinfo for verifying the stack (host: as root or tev;
  # members can run the sandboxed copies from the profile).
  environment.systemPackages = with pkgs; [
    vulkan-tools
    mesa-demos
  ];
}
