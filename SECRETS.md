# Secrets layout

No secret is ever committed to this repo or baked into a container image.

This example does not use any secrets, but real services typically will. This
document describes the pattern for handling secrets on DiRAC VM infrastructure.

## How secrets are stored

Secrets are placed on the `/service/shire` NFS share and bind-mounted
read-only into the container at runtime. The compose file uses a volume mount
to make them available inside the container without baking them into the image.

Example compose volume entry:

```yaml
volumes:
  - "/service/shire/<service>/secrets:/app/secrets:ro"
```

## Ownership and root_squash

`/service/shire` is exported with `root_squash`, so **root on the VM cannot
write to it** — root is mapped to `nobody`. The tree is owned by the service
account whose name, uid, and gid are defined in `service.conf`.

To place or update secrets, become that user (use the name from `service.conf`):

```bash
sudo -u $SVC_USER install -m 0600 /path/to/secret \
    /service/shire/<service>/secrets/my-secret
```

IT creates this account on the VM, and `init.sh` checks that it matches
`service.conf`. If the account is not available by name, use the numeric ids
from `service.conf` instead:

```bash
setpriv --reuid=$SVC_UID --regid=$SVC_GID --clear-groups \
    install -m 0600 /path/to/secret /service/shire/<service>/secrets/my-secret
```

The container must *run* as that uid, or it cannot read mode-0600 files on the
share. The image creates a user with that uid/gid and the compose file sets
`user:` accordingly. All three values come from `service.conf` with no
hardcoded defaults.

## Permissions

Secret files should be owned by the service account and have restrictive
permissions:

```
/service/shire/<service>/secrets/                0755  $SVC_USER
/service/shire/<service>/secrets/<secret-file>   0600  $SVC_USER
```
