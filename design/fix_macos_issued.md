# Dario's findings on fixing the macOS issue

## curl installation

curl won't work for installation from internal procter-gamble repositories.

## ssh key installation failed

```text
adding SSH key to GitHub...
HTTP 404: Not Found (https://api.github.com/user/keys?per_page=100)
This API operation needs the "admin:public_key" scope. To request it, run:  gh auth refresh -h github.com -s admin:public_key
SSH key add failed; upgrading token scope...

! First copy your one-time code: XXXX-YYYY
Press Enter to open https://github.com/login/device in your browser...
This 'device_code' has expired. (expired_token)
could not refresh admin:public_key scope
2026-05-26 14:26:58|INFO|configure.sh:31|<configure>phase_configure_git: configuring git identity...
configuring git...
```

^^ so, left it open, it failed because it was too long, but it happily continued

### Comments

so far:

- doc: put it at the top
- doc: git clone is the only one that works (this is authenticated); you can have one-liner if using gh command that however needs to be - preinstalled
- doc: give users a hint on how long it will take
- installation: recognize potential issues with git key authorization
- shell: my customizations are all gone and broken

```text
$> which df
/Users/berzano.dc/.nix-profile/bin/df
```

^^ nope that's super-duper-BAD

those utilities behave differently on macOS vs. Linux
nix is installing Linux-like utilities system-wide on macOS, overriding the default ones
meaning that every script that relies on macOS behaviour (like the ones I use) will fail

that's an anti-pattern, standard unix utilities should never be overridden
like, this is making development harder
