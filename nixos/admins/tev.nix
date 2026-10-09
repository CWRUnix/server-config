{ ... }:
{
  # Local admin account. Local admin UIDs are pinned in the 1000-1099 range;
  # LDAP (authentik) uidNumbers start at 2000, so the two never collide.
  users.users.tev = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    hashedPassword = ''$6$jFmvFtj14aQAG7tk$FEl8XyZCoNEnxqTS1RFS821pmt/NynpTizF6JrOS90kO/qUKR1EeVjBMvIl9RywM.cTKhn8kNXqVzt8XYkY8T.'';
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINILZDzRLWHEXbtv0TfEH+mNG8mN1nN8C7IXT0cqZqWm tev@ROG"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDwL6Uvhyr+mrXDPcM+d3AUD5l0eN2DoN+UqIHBWntB+ tev@ASUS"
    ];
  };
}
