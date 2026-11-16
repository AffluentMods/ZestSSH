# The ZestSSH status service

One small Cloudflare Worker. Asked `GET /v1/now`, it checks the health of the ZestSSH Cloud API from
Cloudflare's side and answers, signed, whether the API is up or down, and since when it has been down:

```json
{"v":1,"service":"api.zestssh.com","state":"down","at":1791474000,"until":1791474900,"since":1791452400,"key":"k1","sig":"..."}
```

## What it is for

The app works without ZestSSH Cloud, but what goes through it (sync, changes to a team, new
certificates) waits while it cannot be reached. From inside one device, three different things look
the same: the service is down, the device's network blocks it, the device has no internet. This
service looks from somewhere else, so the app can say which it is:

| The app's own request to the API | This service says | What the person is told |
|---|---|---|
| no answer | down | ZestSSH Cloud is down. Nothing is wrong on your side. |
| no answer | up | ZestSSH Cloud is up, but this network does not let the device reach it. |
| no answer | (no answer either) | This device is not reaching the internet. |

And because the answer is signed with a key the app knows, "down" is proof of an outage. An
Orchard's offline limit (a rule an owner can set: a device that has not reached ZestSSH Cloud for
so many hours closes the Orchard) does not count the time the service itself was down, for up to
seven days in one stretch. That is what `since` is for: a laptop opened in the middle of an outage
learns how long it has lasted, and is not locked out for hours that were ours.

## What it knows and keeps

- Nothing about anyone. The app sends no sign-in and no identifier, and asks only after its own
  request to the API got no answer. No log of who asked is kept (`observability` is off).
- One line about the API, and only while there is something to say: since when it has been down, or
  when it came back. It is kept in a KV namespace so that every place Cloudflare runs the Worker
  says the same `since`.
- It looks at the API once a minute (the cron trigger), so that an outage counts from when it began
  and not from when a device first asked. When it is asked for a statement, it looks again, at most
  twice a minute for each place Cloudflare runs it, however many ask.
- It never says anything unsigned about the API: if it is not set up, it answers 500 and the app
  takes that as no answer.

Two rules keep `since` from claiming more than anybody knows. It is never carried across more than a
quarter of an hour in which nobody looked. And it is never earlier than the last time the API was
found up. So an outage that ended and one that began after it are two. And when the namespace
itself does not answer, a statement is still made from what that one instance of the Worker has
seen, which makes `since` later than it was, not earlier.

## Putting it up

Needs a Cloudflare account that holds the zone of the host name, and Node 20 or later. The free
plan is enough: the Worker, its cron trigger and the KV namespace are all within it (one health
check a minute, and during an outage about three hundred writes a day against a thousand allowed).

1. **Choose the host name.** `status.zestssh.com` is what `wrangler.toml` says. If another is
   chosen, change it there and tell whoever builds the app: the name is compiled into it.

2. **Make the place the one line is kept:**

   ```bash
   npx wrangler kv namespace create STATUS_KV
   ```

   It prints an `id`. Put it into `wrangler.toml` where it says `PUT_THE_ID_HERE`.

3. **Make the keys**, on your own machine:

   ```bash
   node tool/make_keys.mjs
   ```

   It prints two keys, `k1` and `k2`, each with a PUBLIC and a PRIVATE line, once.
   - Give both **PUBLIC** lines to whoever builds the app. They are not secret.
   - `k1`'s **PRIVATE** line goes into the Worker in the next step, and nowhere else.
   - `k2`'s **PRIVATE** line is the spare: keep it offline (a password manager, a printed page).

4. **Give the Worker its key:**

   ```bash
   npx wrangler secret put STATUS_SIGNING_KEY
   ```

   and paste `k1`'s PRIVATE value when it asks.

5. **Deploy:**

   ```bash
   npx wrangler deploy
   ```

6. **Check it**, from anywhere:

   ```bash
   curl https://status.zestssh.com/v1/now
   ```

   It should answer with `"state":"up"`, `"since":0` and a `sig`. Stop the API for a few minutes
   (or point `HEALTH_URL` at an address that does not answer and deploy again) and it should say
   `"down"` within a minute and a half, with a `since` that stays the same from one answer to the
   next. Start the API again and it says `"up"` within half a minute.

## If the key has to go

A leaked `k1` lets its holder make the app believe ZestSSH Cloud is down, or has been for longer
than it was. That holds offline limits open, for at most seven days in one stretch on a device that
reaches nothing else, and does nothing more: it opens no data and signs nobody in. To replace it:

1. `npx wrangler secret put STATUS_SIGNING_KEY` with `k2`'s PRIVATE value.
2. Set `STATUS_KEY_ID = "k2"` in `wrangler.toml` and deploy.
3. Make a new spare (`node tool/make_keys.mjs k3`) and have its PUBLIC line put into the next
   version of the app, in place of `k1`'s.

Every app already installed knows both public keys, so nothing breaks in between.

## Changing it

```bash
npm test
```

runs the tests (Node's own test runner, nothing to install). `test/vectors.json` holds statements
signed with a test key; the app's tests read the same file, which is what keeps the two sides
agreeing on the bytes. If the format is changed on purpose, `UPDATE_VECTORS=1 npm test` writes the
file again, and the app's side has to be changed with it.
