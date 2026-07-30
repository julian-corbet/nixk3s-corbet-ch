# The smallest NixOS configuration that lets `nixk3s.host` be evaluated as part
# of a real system, used by the `host-module-evaluates` check.
#
# This is not a machine anyone would run. Everything below is either a stub a
# bootable configuration is required to have, or the one line that turns the
# module on. Nothing here describes real hardware, and no disk, hostname or
# network from any real host appears.
{ ... }:
{
  # ── The module under test ────────────────────────────────────────────────
  # No option here has a required value: `enable = true` is the whole contract,
  # and the role, labels and component set all carry defaults.
  nixk3s.host.enable = true;

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  # A root filesystem and a bootloader must exist for the evaluation to reach
  # system.build.toplevel. `nodev`/`tmpfs` keeps it honest: this config could
  # never boot a real machine, which is the point.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
