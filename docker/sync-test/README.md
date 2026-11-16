# Local sync test stack

Spin up a MinIO (S3) store and a WebDAV server to exercise ZestSSH's
bring-your-own cloud sync end-to-end, with no cloud account.

## Start

```bash
docker compose -f docker/sync-test/docker-compose.yml up -d
```

Wait a few seconds, then check the bucket was created:

```bash
docker compose -f docker/sync-test/docker-compose.yml logs minio-init
```

You should see `MinIO ready: bucket zestssh-sync`.

## Point ZestSSH at it

In the app: **Profile → Sync storage**, pick a provider, enter the settings
below, tap **Test connection**, then **Save**. Then set up sync as normal
(choose a master password + save the recovery key).

### S3-compatible (MinIO)

| Field | Value |
|---|---|
| Endpoint | `http://localhost:9000` |
| Region | `us-east-1` |
| Bucket | `zestssh-sync` |
| Access key ID | `zestadmin` |
| Secret access key | `zestadmin123` |
| Key prefix | *(leave blank, or `zestssh/`)* |
| Path-style addressing | **on** |

MinIO console (to watch the object appear): http://localhost:9001
(login `zestadmin` / `zestadmin123`). After a sync you'll see
`zestssh-sync/zestssh-sync.json`.

### WebDAV

| Field | Value |
|---|---|
| Server URL | `http://localhost:8088/` |
| Username | `zest` |
| Password | `zestpass` |
| Folder | `/ZestSSH/sync/` |

## Multi-device / conflict testing

To exercise convergence and the create-race/CAS fixes with one machine:

1. Set up sync on device A (or a desktop build) against MinIO.
2. On device B (a second build / emulator), **Join** the same store with the
   same master password.
3. Make different edits on each while both are up, then let auto-sync run:
   both should converge to the union (nothing lost).
4. Kill MinIO mid-transfer (`docker compose ... stop minio`) to test failure
   handling and cancellation, then bring it back.

## Reset / tear down

```bash
# wipe stored objects but keep containers
docker compose -f docker/sync-test/docker-compose.yml down
docker volume rm zest-test_minio-data zest-test_webdav-data 2>/dev/null || true

# or full teardown
docker compose -f docker/sync-test/docker-compose.yml down -v
```

> These are **test** credentials for a throwaway local stack: don't reuse
> them anywhere real.
