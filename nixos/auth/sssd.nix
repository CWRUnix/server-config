{ config, lib, ... }:
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
      # Never resolve local system account names via LDAP (defense in
      # depth; the authoritative guard is the pam_localuser gate below).
      filter_users = ${lib.concatStringsSep "," (lib.attrNames config.users.users)}
      filter_groups = ${lib.concatStringsSep "," (lib.attrNames config.users.groups)}

      [pam]

      [ssh]

      [domain/authentik]
      id_provider = ldap
      auth_provider = ldap
      chpass_provider = ldap
      access_provider = ldap

      # authentik LDAP outpost (private host<->container veth; plaintext
      # LDAP is acceptable here since the traffic cannot leave the host —
      # revisit with LDAPS (port 6636 + proper certs) if the outpost ever
      # moves off-host). sssd demands StartTLS by default and refuses
      # password auth over plaintext LDAP, so both must be disabled
      # explicitly.
      ldap_uri = ldap://10.77.0.2:3389
      ldap_id_use_start_tls = false
      ldap_auth_disable_tls_never_use_in_production = true
      ldap_schema = rfc2307bis
      ldap_search_base = dc=ldap,dc=goauthentik,dc=io
      ldap_user_search_base = ou=users,dc=ldap,dc=goauthentik,dc=io
      ldap_group_search_base = dc=ldap,dc=goauthentik,dc=io
      ldap_user_object_class = user
      ldap_user_name = cn
      ldap_group_object_class = group
      ldap_group_name = cn

      # Bind user managed by the OpenTofu bootstrap (see tofu/); its
      # password is the sops secret "ldap/bind_password".
      ldap_default_bind_dn = cn=ldapservice,ou=users,dc=ldap,dc=goauthentik,dc=io
      ldap_default_authtok = $LDAP_BIND_PW

      # SSH public keys come from the user's "sshPublicKey" attribute in
      # authentik (list of keys, managed via the authentik UI).
      ldap_user_ssh_public_key = sshPublicKey

      # Never let authentik-deactivated users in.
      ldap_access_order = filter
      ldap_access_filter = ak-active=true

      # Remote users are dropped into a bubblewrap sandbox on login
      # (see nixos/sandbox/).
      override_shell = /etc/cwrunix/login-sandbox

      # Keep working over short LDAP/outpost outages.
      cache_credentials = true
    '';
  };

  # Create /home/<user> on first login (homes live on the large disk).
  security.pam.makeHomeDir.umask = "0077";

  # Username-collision guard. Without this, an authentik user whose name
  # matches a LOCAL account (root, tev, ...) can log in with their LDAP
  # password: pam_sss authenticates them, then NSS resolves the name via
  # /etc/passwd (files wins over sss) and the session runs AS THE LOCAL
  # USER. pam_localuser skips the pam_sss lines whenever the name exists
  # locally, so local names only ever authenticate against their local
  # (usually absent) password; remote-only names are unaffected. Orders sit
  # immediately before the pam_sss rules the sssd module injects at fixed
  # positions (auth 12100, account 10400, password 10900) — skip=1 must land
  # exactly on pam_sss, verified against the rendered /etc/pam.d/*.
  security.pam.services =
    let
      gate = order: {
        inherit order;
        control = "[success=1 default=ignore]";
        modulePath = "pam_localuser.so";
      };
    in
    lib.recursiveUpdate
      {
        sshd.makeHomeDir = true;
        login.makeHomeDir = true;
      }
      (lib.genAttrs [ "sshd" "login" "su" "sudo" ] (_: {
        rules.auth.localuser-gate = gate 11900;
        rules.account.localuser-gate = gate 10300;
        rules.password.localuser-gate = gate 10500;
      }));
}
