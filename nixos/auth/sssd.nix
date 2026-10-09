{ config, ... }:
{
  # LDAP-backed remote users, served by the authentik LDAP outpost running
  # in the "authentik" nixos-container. Local admin accounts (see
  # nixos/admins/) are unaffected.
  services.sssd = {
    enable = true;

    # sshd looks up remote users' public keys via sss_ssh_authorizedkeys
    # (LDAP attribute "sshPublicKey" — see the bootstrap notes in
    # containers/authentik.nix).
    sshAuthorizedKeysIntegration = true;

    # The LDAP bind password is substituted into sssd.conf from this
    # environment file at service start, so it never enters the nix store.
    environmentFile = config.sops.templates."sssd-env".path;

    config = ''
      [sssd]
      services = nss, pam, ssh
      domains = authentik

      [nss]

      [pam]

      [ssh]

      [domain/authentik]
      id_provider = ldap
      auth_provider = ldap

      # authentik LDAP outpost (private host<->container veth; plaintext
      # LDAP is acceptable here since the traffic cannot leave the host —
      # revisit with StartTLS/LDAPS if the outpost ever moves off-host).
      ldap_uri = ldap://10.77.0.2
      ldap_search_base = dc=ldap,dc=goauthentik,dc=io
      ldap_user_search_base = ou=users,dc=ldap,dc=goauthentik,dc=io
      ldap_group_search_base = ou=groups,dc=ldap,dc=goauthentik,dc=io

      # Bind user created manually in authentik (bootstrap step).
      ldap_default_bind_dn = cn=ldapservice,ou=users,dc=ldap,dc=goauthentik,dc=io
      ldap_default_authtok = $LDAP_BIND_PW

      ldap_user_ssh_public_key = sshPublicKey

      # Remote users are dropped into a bubblewrap sandbox on login
      # (see nixos/sandbox/).
      override_shell = /etc/cwrunix/login-sandbox

      # Keep working over short LDAP/outpost outages.
      cache_credentials = true
    '';
  };

  # Create /home/<user> on first login (homes live on the large disk).
  security.pam.services.sshd.makeHomeDir = true;
  security.pam.services.login.makeHomeDir = true;
  security.pam.makeHomeDir.umask = "0077";
}
