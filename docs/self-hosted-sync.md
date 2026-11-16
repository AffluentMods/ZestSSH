# Bring-your-own Cloud Sync

ZestSSH Cloud Sync is **end-to-end encrypted**. Your connections, identities,
groups, snippets, and secrets are encrypted on your device with a key derived
from your master password (Argon2id → AES‑256‑GCM) **before** anything leaves
the app. Whatever storage you point ZestSSH at only ever holds an unreadable
blob: it can't read your data, and neither can we.

Because the storage is "dumb" (it just holds one encrypted file), you can use
almost anything as your sync backend:

| Backend | Cost | Self-host? | Best for |
|---|---|---|---|
| **ZestSSH Cloud** | Juiced subscription | - | Zero setup |
| **WebDAV** | Free | ✅ | Nextcloud, a NAS, mailbox.org, Koofr |
| **S3-compatible** | Free tier | ✅ | Cloudflare R2, Backblaze B2, MinIO |
| **Google Drive** | Free (15 GB) | - | "just works" with a Google account |
| **Custom server** | Free | ✅ | Running the ZestSSH sync protocol yourself |

> Bring-your-own backends are **free**: they don't require the Cloud Sync
> (Juiced) subscription, because you're providing the storage.

Set it up in the app under **Profile → Sync storage**. Pick a provider, fill in
the fields, tap **Test connection**, then **Save**. After that, set up sync as
normal (choose a master password + save your recovery key).

---

## WebDAV (recommended for self-hosting)

Works with any standards-compliant WebDAV server: **Nextcloud**, ownCloud,
Synology/QNAP/TrueNAS, mailbox.org, Koofr, and more.

**Fields**

- **Server URL**: the WebDAV endpoint. For Nextcloud this is
  `https://cloud.example.com/remote.php/dav/files/<username>/`
- **Username**: your account name.
- **Password**: use an **app password**, not your login password
  (Nextcloud: *Settings → Security → Create new app password*).
- **Folder** (optional): defaults to `/ZestSSH/sync/`; created automatically.

**Notes**

- The server needs a **valid TLS certificate** (self-signed certs are
  rejected). Use Let's Encrypt or a reverse proxy that terminates TLS.
- ZestSSH stores exactly one file (`zestssh-sync.json`) in that folder.
- ZestSSH compares the file's version before it writes and sends `If-None-Match`
  only on the first create; it sends no `If-Match`. Two devices that push in the
  same moment can both write, and the next sync cycle merges what was replaced.

### Nextcloud quick recipe

1. Create an app password (Settings → Security).
2. Server URL: `https://<your-nextcloud>/remote.php/dav/files/<user>/`
3. Username: `<user>`, Password: the app password.
4. Test connection → Save.

---

## S3-compatible

Works with **Cloudflare R2** (10 GB free, no egress fees), **Backblaze B2**
(10 GB free), **Wasabi**, **AWS S3**, or a self-hosted **MinIO**.

**Fields**

- **Endpoint**: the S3 API origin, e.g.
  - R2: `https://<accountid>.r2.cloudflarestorage.com`
  - B2: `https://s3.<region>.backblazeb2.com`
  - MinIO: `https://minio.example.com` (or `http://host:9000` on a trusted LAN)
- **Region**: `auto` for R2, e.g. `us-west-004` for B2, `us-east-1` for MinIO.
- **Bucket**: a bucket you created for sync (e.g. `zestssh-sync`).
- **Access key ID** / **Secret access key**: an API token scoped to that
  bucket (read/write/delete).
- **Key prefix** (optional): a folder inside the bucket, e.g. `zestssh/`.
- **Path-style addressing**: leave **on** for R2, B2, and MinIO. Only turn it
  off if your provider requires virtual-host style.

Requests are signed with AWS Signature V4. Make sure the device clock is
roughly correct (SigV4 rejects large clock skew).

### Cloudflare R2 quick recipe

1. Create a bucket (e.g. `zestssh-sync`).
2. Create an **R2 API token** with Object Read & Write on that bucket.
3. Endpoint: `https://<accountid>.r2.cloudflarestorage.com`, Region: `auto`.
4. Paste the Access Key ID + Secret, Test connection → Save.

### Self-host with MinIO (Docker)

```bash
docker run -d --name minio -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=admin \
  -e MINIO_ROOT_PASSWORD='choose-a-strong-password' \
  -v /srv/minio:/data \
  quay.io/minio/minio server /data --console-address ":9001"
```

Then create a bucket `zestssh-sync` and an access key in the MinIO console
(`http://<host>:9001`), and point ZestSSH at
`http://<host>:9000`, region `us-east-1`, path-style **on**.

> Put MinIO behind a reverse proxy with TLS for anything beyond a trusted LAN:
> your API keys travel on every request.

---

## Google Drive

Stores the sync file in Drive's hidden **app-data folder** (`drive.appdata`
scope). ZestSSH can only ever see that one file, never the rest of your Drive,
and it's invisible in the normal Drive UI.

1. Select **Google Drive** under Profile → Sync storage.
2. Tap **Test connection** to sign in and authorise the app-data scope.
3. Save.

Auto-sync refreshes the Google token while the app is open. If it ever loses
access, re-open Sync storage and Test connection again.

> **Concurrency note.** Google Drive doesn't expose an atomic compare-and-swap
> primitive, so ZestSSH guards Drive writes with a version check rather than a
> hard lock. If two of your devices push in the exact same moment, one push can
> win and the other's changes are re-sent on its next edit (merge-only means
> nothing is deleted, and the union reconverges). This is fine for a normal
> multi-device setup; if you sync many devices that edit heavily at the same
> time, prefer **S3**, which writes with `If-Match` on the object's ETag.
> WebDAV compares versions as Drive does and mends at the next sync cycle.

---

## Custom ZestSSH server (advanced)

If you run a server that speaks the ZestSSH sync HTTP protocol, point the app at
it here.

- **Server URL (with /v1)**: e.g. `https://sync.example.com/v1`
- **Access token** (optional): a static bearer token, if your server uses one.
  Leave blank to authenticate with your ZestSSH account sign-in (only works if
  your server verifies the same identity provider).

This is the most involved option. For most self-hosters, **WebDAV or MinIO/S3
is simpler** and needs no bespoke server. Prefer those unless you specifically
want the ZestSSH protocol (per-request optimistic locking, server-side password
verification, entitlement hooks).

---

## Switching backends

Changing the storage location while sync is active **disconnects sync on this
device only**: nothing is deleted. Your data stays on this device and on the
old store, and you set sync up again on the new one. To move data between
stores, join sync on each device pointed at the new store, or restore from a
backup.

---

## Security model & limits

- **What the store sees:** one file containing the AES‑256‑GCM ciphertext, the
  DEK wrapped by your password/recovery keys, the KDF salt + parameters, and
  one-way verification hashes. No plaintext, no keys, no password.
- **What the store cannot do:** read your data, or forge a valid blob (any
  tampering fails the GCM auth tag on decrypt: your local data is untouched).
- **What an untrusted store *can* do:** withhold data, or serve an older copy
  (a rollback). ZestSSH tracks the highest version it has seen and merges
  (never deletes) on restore, so a rollback delays convergence rather than
  losing data. Use a store you control or trust.
- **Wrong password:** decryption fails cleanly with a clear error; nothing is
  overwritten.
- **Credentials** (WebDAV password, S3 secret, custom token) are kept in the
  OS-backed secure store, never in plain preferences.
- **Use TLS.** For WebDAV and remote S3/MinIO, always use `https://`. Plain
  `http://` is only reasonable on a trusted LAN: the blob stays encrypted, but
  your store credentials would travel in the clear.
