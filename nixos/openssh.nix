{ ... }:
{
  services.openssh = {
    enable = true;
    ports = [ 22 ];

    # SFTP is disabled on purpose: the sftp subsystem would bypass the
    # bubblewrap login sandbox of remote users. scp still works — for
    # remote users it runs *inside* their sandbox.
    allowSFTP = false;

    settings = {
      UseDns = true;
      PermitRootLogin = "prohibit-password";
      # Required so remote (LDAP/authentik) users can log in with their
      # password. SSH keys also work (via sssd's authorized keys lookup)
      # and remain the preferred method.
      PasswordAuthentication = true;

      # Restrictions for remote users: no forwarding/tunneling, so a
      # sandboxed user cannot pivot into host-local or container services.
      # wheel members (local admins) are exempted below.
      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
      X11Forwarding = false;
      PermitTunnel = false;
    };

    extraConfig = ''
      Match Group wheel
        AllowTcpForwarding yes
        AllowAgentForwarding yes
        X11Forwarding yes
        PermitTunnel yes
    '';
  };

  networking.firewall.allowedTCPPorts = [ 22 ];
}
