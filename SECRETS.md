# Secrets

No secret is ever committed to this repo or baked into a container image.

The only secrets are the passwords of the five PostgreSQL roles. Each is one
file on the `/service/shire` NFS share, bind-mounted read-only into the db
container at `/run/secrets/postgres/`:

```
/service/shire/secrets/              0700  $SVC_USER
/service/shire/secrets/postgres      0600  $SVC_USER
/service/shire/secrets/owner         0600  $SVC_USER
/service/shire/secrets/readwrite     0600  $SVC_USER
/service/shire/secrets/readonly      0600  $SVC_USER
/service/shire/secrets/replication   0600  $SVC_USER
```

Each file contains just the password, followed by a newline (the files
`init.sh` generates end with one). The trailing newline is not part of the
password: `sync-roles.sh` strips it, so a file with or without one gives the
same password.

## The files are authoritative

Every time the db container starts, `postgres/sync-roles.sh` sets each role's
password from its file (and creates the role if it is missing). Whatever is
in the files is what the passwords are; a password changed from inside
PostgreSQL with `ALTER ROLE` reverts at the next restart.

`init.sh` generates a random password for any file that does not exist. It
never overwrites an existing file.

## Changing a password

```bash
sudo -u $SVC_USER sh -c 'umask 077 && cat > /service/shire/secrets/readonly'
# type the new password, then Ctrl-D

podman compose up -d --force-recreate db
podman logs pg-db | grep sync-roles      # confirm the sync ran
```

Recreating the db container is a brief outage (a few seconds).

## Reading a password

```bash
sudo -u $SVC_USER cat /service/shire/secrets/readonly
```

To connect without copying the password by hand (works in bash and tcsh):

```bash
env PGPASSWORD="`sudo -u $SVC_USER cat /service/shire/secrets/postgres`" \
    psql -h localhost -U postgres -d postgres
```

If you do copy it from `cat` output, check the file ends with a newline;
otherwise the shell prompt is printed on the same line, straight after the
password, and it is easy to copy a character too many or too few. To add one
to an existing file (this does not change the password):

```bash
sudo -u $SVC_USER sh -c 'f=/service/shire/secrets/readonly; [ -z "$(tail -c1 "$f")" ] || echo >> "$f"'
```

## Ownership and root_squash

`/service/shire` is exported with `root_squash`, so **root on the VM cannot
read or write these files** -- root is mapped to `nobody`. Use the service
account named in `/root/VM.set` (`VMUSER`). If the account is not available by name, use
the numeric ids:

```bash
setpriv --reuid=$SVC_UID --regid=$SVC_GID --clear-groups \
    cat /service/shire/secrets/readonly
```

The containers run as that uid for the same reason: it is the only identity
that can read the password files and write the backup repository.

## What is not secret

The pgBackRest repository in `/service/shire/backups` is not encrypted. It
contains a full copy of the database, including the roles' password
*hashes* (SCRAM verifiers). It is protected by the same NFS ownership as the
secrets.
