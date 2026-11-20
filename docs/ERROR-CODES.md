# ZestSSH error codes

<!-- Written by tool/error_codes.dart from lib/core/errors/error_codes.dart. Not edited by hand. -->

Some messages in ZestSSH end in a code in parentheses, like (ZS-1101). The code is the same in every
language the app speaks. This page says for each code what is going on, what still works, and what to
do. A message with much behind it (a connection that failed, a file that could not be read) has a
"Copy details" button instead of, or beside, its code: what it copies names the code as well, with
the names of hosts, people and folders, addresses, keys and passwords taken out.

## ZS-1001: Mosh is not installed on this computer

**What it means.** The host is set to connect over Mosh, and this computer is set to open Mosh sessions through the mosh program installed on it instead of the built-in client (Settings, Terminal and SSH, on a Mac or Linux), and that program is not installed here. Before 4.0 every computer used that program (on Windows through WSL). Nothing was sent to the host. Other hosts, and this one over SSH, connect as usual.

**What to do.**

1. Turn on Built-in Mosh client in Settings, Terminal and SSH: ZestSSH then needs no mosh program on this computer.
2. Or install Mosh with the command the message shows for your system: brew install mosh on a Mac, the package manager on Linux (sudo apt install mosh, for example).
3. Connect again. The host needs mosh-server installed as well.

**For whoever is helping.** Shown when a Mosh host is opened with the system client chosen and no mosh program is found, in the PATH or where Homebrew and the package managers put it. Versions before 4.0 showed it on Windows too, after `wsl which mosh`. A message that the connection started and then failed is a different problem (ZS-1004 to ZS-1008).

*Since ZestSSH 3.0.*

## ZS-1002: Eternal Terminal is not installed on this computer

**What it means.** The host is set to connect over Eternal Terminal, and ZestSSH opens such a session through the et program of the computer itself, which is not installed here (on Windows: not installed in WSL, or WSL itself is missing). Nothing was sent to the host. Other hosts, and this one over SSH, connect as usual.

**What to do.**

1. Install Eternal Terminal with the command the message shows for your system: brew install MisterTea/et/et on a Mac, the package manager on Linux.
2. On Windows, install WSL first (wsl --install), then et inside it (wsl sudo apt install et). ZestSSH runs et through WSL by itself.
3. Connect again. The host needs etserver installed and running as well.

**For whoever is helping.** Shown when an Eternal Terminal host is opened and no et program is found: on macOS and Linux in the PATH or where Homebrew and the package managers put it, on Windows by `wsl which et`.

*Since ZestSSH 3.0.*

## ZS-1003: Eternal Terminal hosts open on a computer only

**What it means.** The host is set to connect over Eternal Terminal, which ZestSSH opens through the et program of the computer it runs on. A phone or a tablet has no such program, so the host does not open there. It often shows for a host added on a computer and synced to the phone. Nothing was sent to the host. (Before 4.0 Mosh hosts showed it too; ZestSSH now has its own Mosh client on every device.)

**What to do.**

1. Open the host on a computer with ZestSSH, where it connects as set.
2. Or, to connect from this device, edit the host and set it to SSH or Mosh. Keep-alive and reconnecting keep an SSH session going on an unsteady network, and Mosh keeps one through changes of network.

*Since ZestSSH 3.0.*

## ZS-1004: mosh-server is not installed on the host

**What it means.** ZestSSH signed in to the host over SSH to start mosh-server there, which a Mosh session needs on the host, and the host has none: its shell did not find mosh-server by name, nor in the folders package managers put it in. Nothing else was changed on the host, and the host still opens over SSH.

**What to do.**

1. Install Mosh on the host with its package manager (sudo apt install mosh, sudo dnf install mosh, brew install mosh on a Mac), then connect again.
2. Or edit the host and set it to SSH.

**For whoever is helping.** mosh-server was run over SSH by name, then as /usr/local/bin, /opt/homebrew/bin, /opt/local/bin, /usr/bin and /snap/bin/mosh-server; each ended with "command not found" or exit status 127. The connection log lists each try.

*Since ZestSSH 4.0.*

## ZS-1005: mosh-server found no UTF-8 locale on the host

**What it means.** mosh-server is installed on the host but refuses to start without a UTF-8 locale, and the host has neither of the two ZestSSH asks for (en_US.UTF-8, then C.UTF-8). Nothing else was changed on the host, and the host still opens over SSH.

**What to do.**

1. On the host, make a UTF-8 locale, for example: sudo locale-gen en_US.UTF-8 (Debian and Ubuntu), or install glibc-langpack-en (Fedora and RHEL).
2. Connect again.

**For whoever is helping.** mosh-server said "needs a UTF-8 native locale to run" for -l LANG=en_US.UTF-8 and for -l LANG=C.UTF-8. What it said is under the message, with the key of any session taken out.

*Since ZestSSH 4.0.*

## ZS-1006: mosh-server did not start on the host

**What it means.** ZestSSH ran mosh-server on the host over SSH, and it printed no MOSH CONNECT line with the port and key a Mosh session needs. What it said instead is under the message. The host still opens over SSH.

**What to do.**

1. Read what mosh-server said under the message: it often names the problem (no free UDP port in 60000 to 61000, a full disk, a shell that prints something at sign-in that breaks it).
2. Try mosh-server new on the host in an SSH session to see the same.
3. Or edit the host and set it to SSH.

**For whoever is helping.** The command was mosh-server new -s -c 256 -p 60000:61000 -l LANG=en_US.UTF-8 (without -s through a jump host), run without a terminal. The output shown has the banner and any session key taken out.

*Since ZestSSH 4.0.*

## ZS-1007: mosh-server started, and nothing answered over UDP

**What it means.** mosh-server started on the host and waits for this device on a UDP port between 60000 and 61000, and none of what ZestSSH sent there got an answer within 15 seconds. Almost always a firewall drops UDP to those ports: the host's own (ufw, firewalld), a cloud provider's security group, or a network on the way. The host still opens over SSH, which needs only its TCP port.

**What to do.**

1. Open UDP ports 60000 to 61000 to the host: sudo ufw allow 60000:61000/udp, firewall-cmd --add-port=60000-61000/udp, or the inbound rules of the cloud provider.
2. Connect again. A host behind a jump host or a network that lets no UDP through cannot be reached over Mosh: set it to SSH.

**For whoever is helping.** The message names the port mosh-server chose. mosh-server ends by itself after 60 seconds without contact, so nothing is left running on the host. Datagrams went to each address the host name resolves to.

*Since ZestSSH 4.0.*

## ZS-1008: The Mosh session could not go on

**What it means.** The built-in Mosh client stopped: the host's mosh-server speaks another version of the protocol, no UDP socket could be opened on this device, or the client met something it could not handle. What it said is under the message. Other sessions are not touched, and the host still opens over SSH.

**What to do.**

1. Connect to the host again: a new session starts a new mosh-server.
2. If it happens again, update mosh on the host (a version from 1.2 on speaks the same protocol), or set the host to SSH, and send the details to support.

*Since ZestSSH 4.0.*

## ZS-1101: ZestSSH Cloud is not responding

**What it means.** The app asked ZestSSH Cloud for something and got no answer, while this device has a network. Nothing on the device is affected: your hosts, saved logins and keys, sessions that are running, and team certificates the device already holds all keep working. What waits until the service answers again is whatever goes through it: sync to ZestSSH Cloud, changes to a team (members, roles, rules, invitations), new team certificates, access requests, live session sharing and support tickets. The app keeps checking by itself and catches up when the service is back.

**What to do.**

1. Open another website on this device. If nothing opens, the problem is the connection of this device, not ZestSSH Cloud.
2. If other sites open, the service is down or cannot be reached from your network. Nothing needs doing: the app keeps checking and catches up by itself.
3. On a company network, a firewall, VPN or proxy that blocks api.zestssh.com looks the same. Ask for it to be allowed, or try another network.
4. To connect to a host in the meantime, connect as usual: connecting does not go through ZestSSH Cloud.

**For whoever is helping.** Shown when a request to the API host fails with no HTTP answer (refused, reset, timed out, no DNS) and the system reports a network. If only one user reports it, suspect their network (DNS filtering, TLS inspection, a blocked host). If many do at once, it is an outage. It is what one failed request can say by itself. Within seconds the app asks the ZestSSH status service, and its notice then says which of three it is: ZS-1105 (the service is down), ZS-1106 (it is up and this network blocks it) or ZS-1107 (the device reaches nothing of ZestSSH). A message shown at the very moment a request failed says ZS-1101 in any build; one that still says it a minute later came from a build with no status service set up.

*Since ZestSSH 3.0.*

## ZS-1102: This device is offline

**What it means.** The device has no network, so ZestSSH Cloud cannot be reached from it. Everything on the device keeps working for hosts it can still reach (on the same local network, for example). Whatever goes through ZestSSH Cloud waits until the device is online again, and then catches up by itself.

**What to do.**

1. Connect the device to a network (Wi-Fi, cable or mobile data).
2. If the system says it is connected and this still shows, turn the connection off and on, or restart the app.

**For whoever is helping.** Shown when a request to the API host fails and the system reports no network at all. On Linux without NetworkManager the system cannot say how the network stands; the app then reports ZS-1101 instead.

*Since ZestSSH 3.0.*

## ZS-1103: ZestSSH Cloud answered with a fault

**What it means.** ZestSSH Cloud, or the network in front of it, answered with a server error (an HTTP status from 500 to 599). The fault is on the side of the service, not on this device and not in what you entered. Everything on the device keeps working; what goes through the service waits, and the app tries again by itself.

**What to do.**

1. Wait a few minutes and try again: these faults usually pass.
2. If the same thing fails for more than an hour, send the details (Copy details, where the message offers it) to support with the time it happened.

**For whoever is helping.** The HTTP status is in the message and in the copied details. 502, 503, 504 and 520 to 530 mean the service could not be reached behind its front; 500 is a fault inside the service: look in its log at that time.

*Since ZestSSH 3.0.*

## ZS-1104: No secure connection to ZestSSH Cloud

**What it means.** The device reached something at the address of ZestSSH Cloud but could not verify that it is ZestSSH Cloud: the certificate it was shown did not check out. The app refuses to talk to it then, so nothing was sent. The two usual causes are a wrong date or time on the device (a certificate is only valid within its dates) and a network that reads connections on the way (a company proxy or security appliance, some antivirus programs, the sign-in page of a guest Wi-Fi). Everything on the device keeps working.

**What to do.**

1. Check the date, the time and the time zone of the device, and set them to automatic.
2. On a guest or hotel Wi-Fi, open a browser and finish the sign-in page of the network first.
3. On a company network, ask whether connections are inspected: api.zestssh.com has to be let through unchanged.
4. Try another network, such as the hotspot of a phone. If it works there, the first network is the cause.

**For whoever is helping.** The app checks the certificate against the trusted roots of the system and does not accept one that fails, on purpose: accepting it would let whoever is in the middle read what the account sends. There is no switch in the app to turn this off, and none should be advised.

*Since ZestSSH 3.0.*

## ZS-1105: ZestSSH Cloud is down

**What it means.** ZestSSH Cloud is down, and the app knows it for certain: when the service gave no answer, the app asked the ZestSSH status service, which runs apart from it and looks at it from outside, and the status service said, signed, that the service is down. Nothing is wrong on this device or with its network. Everything on the device keeps working: your hosts, saved logins and keys, sessions that are running, and team certificates the device already holds. What goes through the service waits (sync to ZestSSH Cloud, changes to a team, new team certificates, access requests, live session sharing, support tickets), and the app keeps checking and catches up by itself when the service is back. Where a team has set an offline limit, the time the service itself is down is not counted against a device, for up to seven days in one stretch.

**What to do.**

1. Nothing needs doing on this device, and nothing done on it would help: the fault is on the side of the service.
2. To connect to a host in the meantime, connect as usual: connecting does not go through ZestSSH Cloud.
3. The app checks again by itself every few minutes. On a computer, a click on the notice in the status bar checks at once.

**For whoever is helping.** Shown instead of ZS-1101 when the status service (which runs apart from the API) answered with a signed "down". The notice says since when. If a user reports ZS-1105 while the service is in fact up, look at the status service itself: it says "down" only when the health check of the API gets no answer, an HTTP status from 500 to 599, or an answer that says it is not ok, twice in a row.

*Since ZestSSH 3.0.*

## ZS-1106: ZestSSH Cloud is up, but this network does not let the device reach it

**What it means.** The app got no answer from ZestSSH Cloud, asked the ZestSSH status service (which looks at the service from outside), and was told, signed, that the service is up. So the service works, and something between this device and it is in the way: a firewall, a VPN, a proxy, a DNS filter or a security program, on the device or on the network it is on. Everything on the device keeps working; what goes through ZestSSH Cloud waits until the device can reach it.

**What to do.**

1. Try another network, such as the hotspot of a phone. If it works there, the first network is the cause.
2. If a VPN is in use, turn it off for a moment (or on, if it was off) and see whether that changes it.
3. On a company network, ask for api.zestssh.com to be allowed (HTTPS, port 443).
4. If a DNS filter or an ad blocker for the whole network is in use (Pi-hole, NextDNS, a setting of the router), allow api.zestssh.com there.

**For whoever is helping.** The device reached the status service and not the API host (api.zestssh.com). Look for a rule that names the API host: DNS filtering, an allow list of a proxy, inspection of secure connections that breaks only some hosts. If many users on different networks report it at the same time, the way between the provider and the API may be at fault although the status service says "up": treat that as an incident.

*Since ZestSSH 3.0.*

## ZS-1107: Nothing of ZestSSH could be reached from this device

**What it means.** The system says this device has a network, but the app reached neither ZestSSH Cloud nor the ZestSSH status service, which run apart from each other. The most likely reason by far is that the device is not reaching the internet at all: a Wi-Fi that wants a sign-in first, a router whose line is down, a network with no way out. Hosts the device can still reach (on the same local network, for example) keep working, and so does everything stored on the device.

**What to do.**

1. Open any website in a browser on this device. If none opens, the device has no internet: that is what to fix.
2. On a guest or hotel Wi-Fi, a sign-in page usually shows in the browser: finish it.
3. Check the date and the time of the device, and set them to automatic.
4. If other websites open, something blocks both ZestSSH addresses (a firewall or a DNS filter): try another network, or ask for api.zestssh.com to be allowed.

**For whoever is helping.** Shown when the API gave no answer, the system reports a network, and the status service gave no statement the app could believe: no answer, or an answer that is no signed statement (the sign-in page of a guest network, for one). A wrong clock on the device lands here too, because a statement is believed only when its time is now, give or take five minutes: ask for the date and time of the device. A build with no status service set up reports this situation as ZS-1101.

*Since ZestSSH 3.0.*

## ZS-1108: ZestSSH Cloud sent more than an answer may be

**What it means.** What came back to a request was much longer than any answer of the service, so ZestSSH stopped reading it. It may be something on this network answering in the service's place. Nothing of it was used. SSH to your hosts and everything on this device work as usual.

**What to do.**

1. Try again in a little while.
2. If it keeps showing, try another network, and tell support with Copy details.

**For whoever is helping.** The limit is 16 MB for an answer of the API, and 128 MB for sync and teams, which carry records. Copy details names the host that answered.

*Since ZestSSH 3.3.*

## ZS-1201: Your sync storage cannot be reached

**What it means.** Background sync could not reach the place your data syncs to (ZestSSH Cloud, or your own WebDAV, S3 or Google Drive storage). Nothing is lost: changes made on this device are kept and marked to go. The app tries again by itself, after 30 seconds at first and then at most every 15 minutes, and at once when the network of the device comes back. Sync is not paused and nothing has to be pressed.

**What to do.**

1. Nothing needs doing if the storage is only down for a while.
2. If it is your own storage, check that it is running and that its address has not changed (Account, Sync storage).
3. To try at once, press "Sync now" on the Account page.

**For whoever is helping.** Before 3.0 three such failures in a row stopped background sync until the app was restarted. If a user on an older version reports sync that "just stopped", that is why: a restart or "Sync now" resumes it.

*Since ZestSSH 3.0.*

## ZS-1202: Sync could not finish on this device

**What it means.** A step of sync failed on the device itself and not at the storage: reading what was to be sent, or taking in what was fetched. The storage was reached and is fine. Nothing was lost: what is on the device is as it was, and so is what the storage holds. After three such failures in a row background sync pauses until "Sync now" is pressed or the app is started again.

**What to do.**

1. Press "Sync now" on the Account page.
2. If it fails again, restart the app and try once more.
3. If it still fails, copy the details from the message and send them to support: they say what the device could not do.

**For whoever is helping.** The details name the error that was caught. A database that is locked, or a device that is out of storage, are the usual causes. Changes from other devices that this version of the app cannot read are a different message, which asks for the app to be updated.

*Since ZestSSH 3.0.*

## ZS-1203: Another device synced at the same moment

**What it means.** Two of your devices sent changes to the sync storage at the same moment, and this one came second, twice in a row. The storage takes one writer at a time, so that neither writes over the other. Nothing was lost: the changes made on this device are kept and marked to go, and the app tries again by itself, first fetching what the other device sent.

**What to do.**

1. Nothing needs doing: it passes by itself, usually within a minute.
2. If it still shows after an hour, press "Sync now" on the Account page of this device.
3. If "Sync now" says the same, copy the details and send them to support.

**For whoever is helping.** Versions before 3.0 showed this as "Version conflict: server is at v1, expected v3. Pull and retry." They also showed it for ever on a device whose sync storage had been restored from a backup: the storage was behind the device, and every write was refused as out of date. From 3.0 a device notices storage that went back, merges what it holds and sends what it lacks. A user on an older version who keeps seeing the old text after a restore should update.

*Since ZestSSH 3.0.*

## ZS-1204: ZestSSH Cloud storage comes with Juiced

**What it means.** Sync was to keep its copy on ZestSSH Cloud, the storage ZestSSH runs, and that storage comes with Juiced. The account signed in here has no Juiced, so ZestSSH Cloud keeps no copy for it. Sync itself is free: it works the same with storage of your own (WebDAV, Nextcloud, S3 or Google Drive). Nothing on this device was changed or lost.

**What to do.**

1. To sync for free, choose storage of your own: on the Account page, Storage, then WebDAV, S3 or Google Drive.
2. To keep the copy on ZestSSH Cloud, get Juiced, then set up sync again.
3. If Juiced was bought with another account, sign out and sign in with that one: a purchase belongs to the account that made it.

**For whoever is helping.** ZestSSH Cloud answers any sync request of an account without Cloud Sync (Juiced) with 403 and the code ENTITLEMENT_REQUIRED. Versions before 3.0 said "Couldn't reach the sync server" for it while sync was being set up, which reads as an outage: ask whether ZestSSH Cloud was the storage chosen and whether the account has Juiced.

*Since ZestSSH 3.0.*

## ZS-1205: ZestSSH Cloud syncs up to 7 devices for one person

**What it means.** ZestSSH Cloud syncs one person's hosts and keys on up to 7 devices (Juiced, and each seat of a team; a member of a Business team has no limit). The account signed in here already syncs on 7 that signed in before this one, so this device was refused. Nothing on this device was changed or lost, and sync to storage of your own is never limited.

**What to do.**

1. On a device you still use: Profile & Sync, Devices, then sign out a device you no longer use. This one then syncs at its next try.
2. Or sign this device out instead, if it is the one you no longer need.

**For whoever is helping.** ZestSSH Cloud answers a sync request from a device past the cap with 403 and the code cloud-device-limit (from 22 October 2026). The first 7 signed-in devices, oldest first, keep syncing; devices signed out, or signed out by "Sign out everywhere", do not count; a request that does not say which device it is (an app from before 3.0) is not counted. A team vault's items answer the same way.

*Since ZestSSH 3.0.*

## ZS-1206: This device cannot read a key's saved secret

**What it means.** One of your SSH keys has a secret saved on this device (its private key, passphrase, password or certificate) that the device cannot open. So that the key is not passed on as one with no secret, sync and backups stop on this device until the secret reads again. Nothing was lost: nothing was sent or written, your other devices and your sync storage keep their copy of the key, and connecting from this device with your other keys still works.

**What to do.**

1. If the app is locked, unlock it and press "Sync now".
2. Open the key the message names, on this device, and save its private key, passphrase or password again.
3. If you do not have the private key at hand, export the key on another of your devices and import it on this one.
4. Do not delete the key on this device to get sync going: a deletion syncs to your other devices.

**For whoever is helping.** With Encrypt data at rest on, secrets in the system storage are sealed with a key kept in the app's database. One sealed by another database (a restored or moved profile, a storage copied from another install) or damaged does not open. Before 4.0 it read as "no secret" and was synced as that, and every other device deleted its readable copy. The details name the storage slot, never the secret. Saving the secret again writes it under this database's seal.

*Since ZestSSH 4.0.*

## ZS-1210: The recovery key could not be checked

**What it means.** While restoring with a recovery key, the sync server did not answer the question whether the key is the right one (it was not reached, or it answered with a fault). Nothing was said about the key: it may be perfectly right.

**What to do.**

1. Do not throw the key away and do not assume it is wrong.
2. Try again in a few minutes.
3. If it keeps failing, check the connection of the device (see ZS-1101 and ZS-1102).

**For whoever is helping.** Before 3.0 every failure of a restore said "That recovery key didn't work", a network failure included. A user who was told so on an older version may hold a good key.

*Since ZestSSH 3.0.*

## ZS-1211: The recovery key is not the one for this vault

**What it means.** The store was asked and answered: this recovery key does not open the synced data. Either it was typed with a mistake, or it is an older key (a recovery key that was replaced no longer works), or it belongs to another account.

**What to do.**

1. Type it again, slowly. A key begins with ZEST, and the letters I, L and O and the digits 0 and 1 are never part of one.
2. If the key was replaced at some point (Account, Recovery key, Replace), only the newest one works.
3. Check that you are signed in to the account the key was made for.
4. If you remember the sync password after all, you do not need the key: go back and enter the password.

**For whoever is helping.** There is no way to recover synced data without the sync password or the current recovery key: the service never holds either. Say so plainly.

*Since ZestSSH 3.0.*

## ZS-1301: No port for the browser to come back to

**What it means.** Signing in on a computer happens in the browser, which then comes back to ZestSSH on a port of this computer alone (never reachable from outside it). ZestSSH asked for one at 32768 or above, the ones the website sends a sign-in back to, and could not have one. Nothing was sent anywhere. Your hosts connect as usual; this concerns only signing in.

**What to do.**

1. Try again: a port that was taken may be free now.
2. If it keeps showing, something on this computer holds or blocks those ports (a firewall, a security tool, or a setting that moved the range of ports the system hands out). Allow ZestSSH to listen on 127.0.0.1.

**For whoever is helping.** Copy details gives what the system said. `netsh int ipv4 show dynamicport tcp` on Windows, or `sysctl net.ipv4.ip_local_port_range` on Linux, shows the range the system hands out. The website refuses a loopback callback below 32768, so a lower port is not used.

*Since ZestSSH 3.3.*

## ZS-1302: This account's data on this computer did not open

**What it means.** You signed in, and the hosts, keys and settings this account keeps on this computer did not open. Nothing was changed and nothing was deleted, and the app stays where it was, so what is on screen still works.

**What to do.**

1. Choose Retry, or sign in again.
2. If it keeps showing, write to support with this code. Your data stays on this computer as it is.

**For whoever is helping.** The account is known on this computer and its database did not open with its key: a full disk, a file another program holds, or a damaged database. Never ask the person to delete anything: every profile has its own folder and keys, and what did not open is still there.

*Since ZestSSH 3.3.*

## ZS-1303: What ZestSSH Cloud holds does not open this account's data here

**What it means.** While an account is signed out, its data on a computer is locked with a secret that ZestSSH Cloud keeps. ZestSSH Cloud handed one back, and it does not open the copy on this computer. Nothing was changed, and the data on this computer is still there, locked.

**What to do.**

1. Try signing in again.
2. If it keeps showing, write to support with this code. Do not remove anything from this computer in the meantime.

**For whoever is helping.** This should not happen: the device checks that a secret opens its copy before it forgets it, and the copy is bound to its profile and its id. Ask whether the app's files or this OS user's keychain were restored from elsewhere.

*Since ZestSSH 3.3.*

## ZS-1304: This account's old data on this computer can no longer be opened

**What it means.** The secret that opened this account's locked data on this computer was deleted, in Settings, Account, so that copy can never be opened again. The app made a new, empty profile for the account. What you synced comes back with sync. The old files stay on this computer, and nothing uses them.

**What to do.**

1. Turn sync on with your sync password to bring back what you synced.
2. Hosts and keys that were never synced cannot be recovered from the old copy: add them again.

*Since ZestSSH 3.3.*

## ZS-1305: Your data is hidden, not locked

**What it means.** You signed out, and the app did not lock this account's data, because it could not be sure ZestSSH Cloud holds the secret that locks it: this computer had never been able to tell ZestSSH Cloud the secret, the secret was deleted under Locked copies on your computers, or this computer could not ask ZestSSH Cloud as you signed out (it was offline, or ZestSSH Cloud did not answer). The app no longer shows the data and nothing is lost, but its key is still on this computer, so someone who can read this OS user's keychain could open it.

**What to do.**

1. Sign in again, then sign out while online: the sign-in tells ZestSSH Cloud the secret where it does not hold it, and a sign-out that finds it there locks the data.

*Since ZestSSH 3.3.*

## ZS-1306: Opening this account's data takes a recent sign-in

**What it means.** ZestSSH Cloud hands back what opens a signed-out account's data only after a sign-in from the last ten minutes, so a session copied off this computer cannot fetch it. This sign-in is older than that. Nothing was changed, and the data on this computer is still there, locked.

**What to do.**

1. Sign in again, and open it right away.
2. If it keeps showing, check that this computer's clock is right.

*Since ZestSSH 3.3.*

## ZS-1307: The link to choose a password could not be sent

**What it means.** ZestSSH Cloud did not send the email: it is busy, or out of reach. Nothing about the account or its password changed.

**What to do.**

1. On a computer, open the sign-in page on zestssh.com and choose Forgot password? there: it reaches the email service another way.
2. Or try again in a moment.

**For whoever is helping.** ZestSSH Cloud's answer was 429 (too many asked for this address or from this network) or 503 (its mail is not configured or down), or none came. A computer holds no Firebase of its own, so the website is what it goes to.

*Since ZestSSH 3.3.*

## ZS-1308: This computer holds as many accounts as it can

**What it means.** A computer keeps the data of five accounts at most, and guest data does not count. This account would be the sixth, so nothing was made for it, and nothing on this computer changed.

**What to do.**

1. Open the account row at the bottom left and choose Remove from this computer beside an account you no longer use here. Then sign in again.

**For whoever is helping.** Removing an account deletes its folder and its keys on this computer. What it synced stays at ZestSSH Cloud, and it comes back when that account signs in here again.

*Since ZestSSH 3.3.*

## ZS-1309: The other account could not be opened

**What it means.** The data of the account you picked did not open, or the browser signed in to another account than that one, so the app stayed where it was. Nothing of either account was changed or lost.

**What to do.**

1. Try again, and sign in to the account you picked.
2. If it keeps showing, restart ZestSSH. Copy details gives what went wrong.

**For whoever is helping.** Its database did not open or its settings could not be read before anything else changed. ZS-1302 is the same at a sign-in.

*Since ZestSSH 3.3.*

## ZS-1310: An account could not be removed from this computer

**What it means.** Its folder would not go, as something holds a file in it. Nothing opens it now, and the removal is tried again each time the app starts.

**What to do.**

1. Restart ZestSSH.
2. If it stays, close whatever may have the folder open, such as a backup tool.

*Since ZestSSH 3.3.*

## ZS-1311: A locked copy could not be listed or deleted

**What it means.** ZestSSH Cloud could not be asked, or would not do it this time. Hosts on this computer connect as usual, and nothing else depends on this.

**What to do.**

1. Check the connection and try again.

**For whoever is helping.** Deleting one takes a sign-in or a confirmation from the last ten minutes (recent-sign-in-required); the app asks for one first.

*Since ZestSSH 3.3.*

## ZS-1312: Two-step sign-in went off while switching to the other kind

**What it means.** An account uses passkeys or an authenticator app for two-step sign-in, not both, so switching from one to the other removes the old one first. The old one was removed, and the new one could not be set up, so two-step sign-in is off now and the backup codes stopped working: signing in needs only the password, or Google, Apple, Microsoft or the company sign-in. Nothing else of the account changed, and the hosts and keys stay on every device.

**What to do.**

1. Open Settings, Account and add the passkey again, or set up the authenticator app: either turns two-step sign-in on again.
2. Save the new backup codes it gives you.

**For whoever is helping.** ZestSSH Cloud answered authenticator-removed-passkey-failed (the authenticator app went, and the bridge of the passkey was not enrolled or kept), or the setup of the authenticator app stopped after DELETE /v1/account/two-step/passkeys. The account was emailed. Firebase holds one TOTP factor per account, which is why the old one goes before the new one comes.

*Since ZestSSH 3.3.*

## ZS-1313: This account uses the other kind of second step

**What it means.** An account uses passkeys or an authenticator app for two-step sign-in, not both: the sign-in service keeps one of the two for each account. This account has the other kind, so nothing was added and nothing changed. Signing in works as before.

**What to do.**

1. Add it again and choose Replace when ZestSSH asks: the one the account has goes as the new one comes.
2. Or keep the one the account has. Your backup codes work with either.

**For whoever is helping.** ZestSSH Cloud answered authenticator-app-on, or Firebase answered maximum-second-factor-count-exceeded (SECOND_FACTOR_LIMIT_EXCEEDED). The app asks before it replaces one with the other; this shows where what it knew of the account was out of date.

*Since ZestSSH 3.3.*

## ZS-1401: A watched Crate, and nobody can be asked to watch

**What it means.** The host is in a team Crate whose sessions are watched: a session starts once someone else who manages the Crate has joined to watch it. Asking someone goes through ZestSSH Cloud, which this device cannot reach right now (ZS-1101 to ZS-1107 say which way), so nobody can be asked. An owner of the team may then connect after giving a reason; everyone else may only where the owners allowed that for this Crate, and here they have not. Nothing is wrong with the host. Hosts in Crates that are not watched connect as ever.

**What to do.**

1. Ask an owner of the team to connect, if it cannot wait: an owner is asked for a reason and let through, and the other owners are told afterwards.
2. Or wait: once ZestSSH Cloud answers again, connecting asks someone to watch as usual.
3. An owner who wants the team to get through an outage by itself can allow it for the Crate: under Team, Crates, in the watched Crate's row. Each such session is then reported to the owners with its reason.

**For whoever is helping.** This is the team's own rule and is kept by the app on the device. It is never shown to an owner. A session that goes on with nobody watching is reported in the team's record once the device is back online: who connected, to which host, when and why.

*Since ZestSSH 3.0.*

## ZS-1402: Too many tries with invite codes

**What it means.** Joining a team with an invite code was tried too often with codes that did not work, from this account or from this network, so ZestSSH Cloud takes no more tries for now. The code itself may be fine. Nothing else is held up: hosts, sync and the teams you are in work as ever.

**What to do.**

1. Wait an hour, then enter the code again.
2. Check the code with whoever sent it, or ask them for a new one: a code works once, and stops working when it lapses or is cancelled.

**For whoever is helping.** Only tries that found no live code count: ten an hour for each account and thirty an hour for each network address. Looking at a live code and joining with it do not count.

*Since ZestSSH 3.0.*

## ZS-1403: ZestSSH Cloud lost recent changes to a team

**What it means.** ZestSSH Cloud was restored from a backup and no longer has the newest changes to this team, among them the one that put you in it. This device keeps everything it has of the team, and its hosts connect as usual. It does not sync the team until ZestSSH Cloud has the changes back: the device of any team member who still has them sends them back by itself the next time it syncs, and so do the devices of whoever wrote items since.

**What to do.**

1. Nothing to do on this device: it syncs again by itself once the changes are back.
2. If it does not within a day, ask an owner or admin of the team to open ZestSSH: their device sends the changes back when it syncs.

**For whoever is helping.** The server holds fewer entries of the team's record than this device, and this account is not in the part it holds. A member who is sends the rest back (POST /v1/orchards/:id/record/mend), checked as the first time and only up to the server's own receipt. Key copies the server lost are sealed again by members who hold the keys. Nothing on the device is deleted while it waits.

*Since ZestSSH 3.0.*

## ZS-1404: This device stopped following a team's record

**What it means.** The record of who is in the team and what each may do, as ZestSSH Cloud shows it, does not follow the one this device has checked: it holds fewer entries and cannot take back the ones this device has, or it shows other entries in their place. That can follow a restore of ZestSSH Cloud from a backup during which someone changed the team, or it can be the server hiding a change (a removal, say). This device does not sync the team then. What it holds stays, and the team's hosts connect as usual.

**What to do.**

1. Ask an owner of the team to open ZestSSH and look at the team: if their device shows the same, contact ZestSSH support with the details (Details on the team's banner).
2. Do not leave and rejoin the team to get past it: the record is what tells a removed member from one who is still in.

**For whoever is helping.** The details name the entry where the two records part ways, or why the server would not take the entries back: record-fork (another entry in their place), record-unproven (the server gave no receipt for them; a receipt key changed, or entries this device appended were never read back), or the rule an entry broke. A server restored from a backup should be brought back to the last transaction (point-in-time recovery) where it can, so that nothing is lost in the first place.

*Since ZestSSH 3.0.*

## ZS-1405: A team page could not be loaded

**What it means.** A page of a team (its members, its roles, the Overview) could not read what it shows, on this device or from ZestSSH Cloud; the words before the code say which. Where this device holds the team, the page shows what it holds and says that it is not up to date. Nothing was changed or deleted, and the team's hosts connect as usual.

**What to do.**

1. Select Retry on the page.
2. If the message says you are signed out, sign in again, then select Retry.
3. If it stays, use Copy details on the page and send them to ZestSSH support.

**For whoever is helping.** Copy details names the page and the error the app met. A fault on the device (its team database could not be read) and an answer of ZestSSH Cloud the app did not expect both show this code; a service that could not be reached shows its own code (ZS-1101 to ZS-1107) instead.

*Since ZestSSH 3.0.*

## ZS-1406: A team host cannot open a shell on this device

**What it means.** The host is in a team, and is saved as a local shell: a terminal on the device of whoever opens it. Anyone who may add or edit hosts in a vault can write such a host, with a command for it to run, so ZestSSH never opens one from a team. Nothing was started and nothing ran. Other hosts of the team, and the terminal you open yourself on this device, work as usual.

**What to do.**

1. Ask whoever saved it to give it an address and SSH, or to delete it.
2. For a terminal on this device, use Local terminal: it is your own, whichever space is on screen.

**For whoever is helping.** New versions refuse such a record when it arrives; one seen here came before that, or from an older version on another device. The team's Activity shows who changed the host. If nobody means to have it, treat it as an account that may be someone else's.

*Since ZestSSH 3.3.*

## ZS-1407: A team's data on this computer was set aside

**What it means.** The key of a team's database on this computer could not be read, so the database could not be opened. Nothing was deleted: the file is set aside for 30 days, and the team is fetched again from ZestSSH Cloud. Changes made on this computer that never reached ZestSSH Cloud are not in what comes back.

**What to do.**

1. Wait for the team to come back: it does at its next sync, while this computer is online.
2. If something you changed here is missing, make the change again, or write to support within 30 days to get the old file back. After 30 days it is deleted.

**For whoever is helping.** The file is in the profile's orchards folder, in set_aside, named with its team and the time. A key reads as unreadable where its entry is gone, or where a database since reset sealed it.

*Since ZestSSH 3.3.*

## ZS-1408: A team's record is full

**What it means.** The record of who is in the team and what each may do holds all that ZestSSH Cloud keeps for a team of its seats, so this change to the team was not made. Nothing was lost. Hosts connect and sync goes on as usual, and what takes someone's access away (removing or suspending them, replacing the keys they held) still goes in.

**What to do.**

1. Ask an owner of the team to buy more seats on the Team page, under Seats: each one makes room.
2. If it is still full after that, contact ZestSSH support, with Copy details where the message has it.

**For whoever is helping.** ZestSSH Cloud's answer is 409 record-full. A team keeps 32 MB and 256 KB for each seat of record (lib/orchard_quota.js), which a team doing what the app does does not reach: ask what has been changing.

*Since ZestSSH 3.3.*

## ZS-1409: A change is too large for a team's record

**What it means.** One change to the team came to more than the team's record takes for one entry, so it was not made. Nothing was lost, and everything else in the team goes on as usual.

**What to do.**

1. Make the change in smaller steps: fewer vaults or people at once, say.
2. If it cannot be split, contact ZestSSH support, with Copy details where the message has it.

**For whoever is helping.** ZestSSH Cloud's answer is 413 record-entry-too-large: 64 KB for a role or a member, 8 KB for anything else. Nothing the app writes comes near it, so a version that writes more is worth looking into.

*Since ZestSSH 3.3.*

## ZS-1410: A team's vaults are full

**What it means.** The team's vaults, with the versions kept of what is in them for 30 days, hold all that ZestSSH Cloud keeps for a team of its seats, so nothing new is added. What is new waits on this device and nothing is lost. Changes to what is there go on for a while and deletions always do, and hosts connect as usual.

**What to do.**

1. Ask an owner of the team to buy more seats on the Team page, under Seats: each one makes room.
2. Deleting what the team no longer needs makes room as its old versions run out.
3. If it is still full after that, contact ZestSSH support.

**For whoever is helping.** ZestSSH Cloud's answer is 409 seats-needed with the reason storage. A team keeps 64 MB for each seat, and 256 MB at the least (lib/orchard_quota.js): about 10000 items for each person, each edited this month.

*Since ZestSSH 3.3.*

## ZS-1411: ZestSSH Cloud no longer lists a team for you

**What it means.** ZestSSH Cloud stopped listing a team for your account, as it does for someone taken out of it, but the team's signed record on this device still has you in it, and nothing this device could check says otherwise. So this device does not take ZestSSH Cloud's word for it: everything it has of the team stays, changes not yet sent included, and its hosts connect as usual. The team does not sync while it is not listed.

**What to do.**

1. If you were taken out of the team, or left it, choose Remove from this device on the team's banner.
2. If you should still be in it, ask an owner or admin of the team whether you are: once ZestSSH Cloud lists the team again, it syncs by itself.
3. If an owner says you are still in it and it stays like this, contact ZestSSH support.

**For whoever is helping.** GET /v1/orchards leaves the team out and GET /v1/orchards/:id/record/holds says it holds this device's last record entry (or has no such route), while the record this device holds and checks has the account active, and the record could not be read now to show a member.remove (ZestSSH Cloud lets no former member read it). The device keeps the team with the status unlisted and removes it only when its person says so.

*Since ZestSSH 3.3.*

## ZS-1501: A team certificate is waiting for an owner

**What it means.** The host is in a team Crate whose hosts take certificates. This device holds none that is still good, it asked for one, and no owner's device has signed the request yet. Certificates are signed by the owners' devices and never by ZestSSH Cloud, which only carries the request: it is signed the moment an owner has ZestSSH open. Nothing is wrong with the host or with the login.

**What to do.**

1. Ask an owner of the team to open ZestSSH on any of their devices, then connect again.
2. Or get one from an owner directly: choose "Certificate from an owner" where the connection failed, or in the team's Crates under the Crate. Show the code to an owner or send them the text, and enter what they give back.

**For whoever is helping.** An owner needs nobody: their own device signs their certificate. If an owner sees this, their device has not got the Crate's signing key yet, which comes with a sync.

*Since ZestSSH 3.0.*

## ZS-1502: No team certificate, and ZestSSH Cloud cannot be asked

**What it means.** The host is in a team Crate whose hosts take certificates. This device holds none that is still good, and the request for a new one could not be sent because ZestSSH Cloud is not answering (ZS-1101 to ZS-1107 say which way). The host itself is not affected, and neither are hosts that do not take certificates.

**What to do.**

1. Get one from an owner directly: choose "Certificate from an owner" where the connection failed, or in the team's Crates under the Crate. Show the code to an owner, or send them the text any way that still works.
2. The owner chooses "Sign a request" in the same place and gives back a code or a text. Enter it, then connect again.
3. Or wait: once ZestSSH Cloud answers again, connecting asks for a certificate as usual.

**For whoever is helping.** A certificate lasts as long as the owners chose for the Crate: an hour, eight hours, a day or a week. A team that wants to ride out a longer outage without handing certificates over can choose a longer time in the Crate's certificate settings. Owners are never stopped by this: their own device signs theirs.

*Since ZestSSH 3.0.*

## ZS-1601: sudo did not take the password

**What it means.** A file action the host refused (Permission denied) was tried again as root with sudo, or a file was saved as root in the editor, and sudo on the host said the password was wrong. Nothing was changed on the host. ZestSSH never stores the sudo password: it is typed each time.

**What to do.**

1. Type the password again: it is the password of the account you signed in to the host with, not the root password (unless the host is set up otherwise).
2. If you sign in with a key and do not know that password, ask whoever looks after the host.

**For whoever is helping.** The password goes to `sudo -k -S -p ''` on its standard input, one line, never on the command line. sudo said "Sorry, try again", "incorrect password" or "authentication failure". A host whose sudo asks for something besides the password (a one-time code) answers the same way.

*Since ZestSSH 3.4.*

## ZS-1602: This account may not use sudo on the host

**What it means.** sudo on the host said the account ZestSSH signed in with may not run this as root: it is not in the sudoers file, or may run only some commands. Nothing was changed on the host. The message shows what sudo said.

**What to do.**

1. Sign in to the host as an account that may use sudo, or ask whoever looks after the host to allow it.
2. Or change the file's owner or permissions on the host so that your account may do this without sudo.

**For whoever is helping.** Retry with sudo runs mv, cp, rm, mkdir, sh (for a move or a copy that must not replace what is there) and cat as root; Save as root runs cp. A sudoers rule that allows only some commands refuses the others.

*Since ZestSSH 3.4.*

## ZS-1603: sudo could not be run on the host

**What it means.** To do this as root, ZestSSH runs sudo on the host over SSH. The host has no sudo, or allows SFTP only and runs no commands. Nothing was changed on the host.

**What to do.**

1. Ask whoever looks after the host to install sudo, or to allow your account a shell.
2. Or change the file's owner or permissions on the host so that your account may do this without sudo.

**For whoever is helping.** Exit status 127 or "sudo: command not found" means no sudo in the PATH of the account's shell. A host set to ForceCommand internal-sftp refuses the exec channel. doas is not used.

*Since ZestSSH 3.4.*

## ZS-1604: sudo on the host runs only from a terminal

**What it means.** sudo on the host is set to run only from a terminal (requiretty), and ZestSSH runs it without one so that the password never shows on a screen. Nothing was changed on the host.

**What to do.**

1. Open a terminal to the host and run the command there with sudo.
2. Or ask whoever looks after the host to drop requiretty for your account (Defaults:youraccount !requiretty).

*Since ZestSSH 3.4.*

## ZS-1605: The host did not answer the sudo command

**What it means.** ZestSSH ran a command as root with sudo, and nothing came back from the host for two minutes (ten for a whole folder), so it stopped waiting and ended the command. It may or may not have done its work.

**What to do.**

1. Refresh the folder to see what is there now.
2. Try again. If it keeps happening, run the command in a terminal to the host to see what sudo asks.

**For whoever is helping.** sudo reads the password with -S and its input is closed after one line, so it cannot wait for a password. A PAM module that waits for something else (a push to a phone) can.

*Since ZestSSH 3.4.*

## ZS-1606: The FTPS server offers plain FTP only

**What it means.** The host is saved as FTPS, and its server answered no when ZestSSH asked to start TLS (AUTH TLS). ZestSSH never uses plain FTP, which sends the password and every file readable to anyone on the way, so it stopped there: nothing was sent after the refusal, not the user name and not the password. Other hosts are not affected.

**What to do.**

1. Check the port: an FTPS server with implicit TLS listens on 990, and explicit TLS is asked for on 21.
2. If it is your server, turn TLS on in its settings (vsftpd: ssl_enable=YES; ProFTPD: TLSEngine on; FileZilla Server: Require explicit FTP over TLS).
3. If the server can only do SFTP (most Linux servers with SSH can), save the host as SFTP only instead.

**For whoever is helping.** Copy details carries the reply code the server gave to AUTH TLS (often 500, 502 or 534). There is no setting to allow plain FTP: that is decided (FTP never, FTPS yes).

*Since ZestSSH 3.4.*

## ZS-1607: The FTPS server did not answer in time

**What it means.** ZestSSH waited for the FTPS server and no answer came. When signing in works but folders never list and transfers never start, the cause is nearly always the server's passive data ports: with TLS, a firewall cannot read which port the server named, so the range must be open on its own. Nothing was changed on the server, and other hosts are not affected.

**What to do.**

1. Try again: a busy server or a slow network can cause this once.
2. If it is your server, set a fixed passive port range (vsftpd: pasv_min_port and pasv_max_port) and open that range in its firewall and router.
3. If the server sits behind NAT, it is fine that it names a private address: ZestSSH connects to the address you saved.

**For whoever is helping.** ZestSSH uses passive mode only (EPSV, or PASV with the control connection's own address). Copy details says which step timed out.

*Since ZestSSH 3.4.*

## ZS-1701: Another account's program answers the SSH agent's pipe

**What it means.** On Windows, ZestSSH, ssh and git reach the SSH agent through one named pipe, whose name every account of the computer shares: the first program to take it serves it. The program serving it now is not Windows' OpenSSH Authentication Agent and not one of yours: it runs as another account of this computer, or Windows would not say which. So ZestSSH sent it nothing: no key was given to it, and no sign-in went through it. Keys in your vault, and hosts that sign in with them, work as usual.

**What to do.**

1. Restart the computer, or ask whoever else is signed in to it to sign out.
2. Then start the OpenSSH Authentication Agent service, or your password manager's agent, before anything else can take the pipe, and try again.
3. If it shows again, tell whoever looks after this computer: a program of another account is taking the agent's pipe.

**For whoever is helping.** Before it sends anything, the app asks Windows which account runs the program at the other end of the openssh-ssh-agent pipe. LocalSystem (Windows' OpenSSH agent) and the person's own account (1Password, Bitwarden) are used; any other account is refused. Where that program cannot be asked (a service's process is not open to a person's), the pipe itself must be owned by SYSTEM, as the OpenSSH agent's is. Copy details says which of the two it was. Get-Service ssh-agent shows whether the real agent runs; an administrator can see which process holds the pipe with Sysinternals handle.exe or Process Explorer.

*Since ZestSSH 3.3.*

## ZS-1702: The security key moved away before it was done

**What it means.** On a phone, ZestSSH speaks to a FIDO2 security key itself, over NFC or USB. The key left the phone's NFC field, or was unplugged, before it had signed, and it did so each time it was held to the phone again. Nothing was sent to the host, and no other way of signing in was tried in the key's place. Hosts that sign in with other keys or passwords work as usual, and so does this key on a computer through the SSH agent.

**What to do.**

1. Hold the security key flat against the phone and keep it still until the sheet closes. On most Android phones the NFC reader is in the upper half of the back; on an iPhone it is at the top edge.
2. Take the phone out of a thick case, or a case with metal or a magnet in it.
3. On an Android phone, plug the security key in instead (USB-C): a plugged-in key cannot move away.

**For whoever is helping.** The NFC exchange (ISO 7816-4 to the FIDO applet) failed with a lost tag five times in one conversation. A sign-in with a PIN takes several exchanges, so it needs the key held for a second or two. USB security keys are not supported on iPhone and iPad.

*Since ZestSSH 4.0.*

## ZS-1703: Not the security key this key was made on

**What it means.** A key that lives on a FIDO2 security key can only be used with that one security key. The security key held to the phone, or plugged in, answered that it has no such key: it is another security key, or the one it was made on has been reset since. Nothing was sent to the host, and no other way of signing in was tried. Everything else in ZestSSH works as usual.

**What to do.**

1. Use the security key this key was made on.
2. If that security key was reset or lost, its keys are gone: make a new key on a security key (Keys, Add, On a security key) and add its public key to your hosts.

**For whoever is helping.** CTAP2 authenticatorGetAssertion answered CTAP2_ERR_NO_CREDENTIALS for the identity's key handle and application ("ssh:" unless the key was made with another). A key made as a resident key with ssh-keygen -O resident still needs its key handle here: the app does not list the keys on a security key.

*Since ZestSSH 4.0.*

## ZS-1704: The security key's PIN is blocked

**What it means.** The security key counts wrong PINs itself, and after too many of them (eight on most keys) it blocks its PIN for good. That has happened to this security key: no app can unblock it. Keys on it that ask for the PIN cannot be used any more. Keys on it that do not ask for the PIN still work, and so does everything else in ZestSSH.

**What to do.**

1. Reset the security key with its maker's app (for a YubiKey: Yubico Authenticator, on a computer). A reset erases every key and passkey on it.
2. After the reset, set a new PIN, make a new key on it (Keys, Add, On a security key) and add its public key to your hosts.

**For whoever is helping.** CTAP2 clientPIN answered CTAP2_ERR_PIN_BLOCKED. Not the same as three wrong PINs in a row (CTAP2_ERR_PIN_AUTH_BLOCKED), which the app says in words and which ends when the key is taken away and presented again. The app never retries a PIN by itself and does not keep one.

*Since ZestSSH 4.0.*

## ZS-1705: The security key's answer was not trusted

**What it means.** Before ZestSSH sends a security key's signature to a host it checks it: that it is for this key and for what was to be signed, that the security key waited for the touch or the PIN this key asks for, and that it holds nothing more. This answer failed that check, or was not in a form the protocol allows. Nothing was sent to the host, and no other way of signing in was tried. Your hosts, keys and other sign-ins are not affected.

**What to do.**

1. Try again, holding the security key still or leaving it plugged in.
2. Check that it is the security key this key was made on, and that the key was not replaced in ZestSSH since.
3. If it keeps happening with one security key and not with another, choose Copy details and send them to support.

**For whoever is helping.** The assertion was refused locally: the authenticator data's application hash, flags (user presence, user verification, no extensions) or the signature did not check against the identity's public key, or the CTAP2 answer was not well-formed CBOR of the expected shape. Copy details names which.

*Since ZestSSH 4.0.*

## ZS-1706: This device cannot talk to a security key

**What it means.** On a phone, ZestSSH speaks to a FIDO2 security key over NFC (Android and iPhone) or USB-C (Android). This device has neither way: it has no NFC, or it is an iPad or an iPhone asked for a USB security key, which are not supported yet. Keys that live in the app, passwords and everything else work as usual.

**What to do.**

1. On an iPhone, use a security key with NFC and hold it near the top of the phone.
2. On an Android phone without NFC, plug the security key in (USB-C).
3. Or sign in to this host with a key kept in the app, or from a computer, where a security key works through the SSH agent.

**For whoever is helping.** The platform reported no NFC reader that can reach an ISO 7816 tag and no USB host for a FIDO HID interface. iPadOS has no NFC reader for apps; iOS gives apps no raw channel to a USB security key. On an iPhone the app also needs the NFC Tag Reading capability in its build.

*Since ZestSSH 4.0.*

## ZS-1801: Nothing answers at the remote screen's address

**What it means.** ZestSSH signed in to the SSH host this screen is reached through and asked it to connect to the screen's address and port (localhost:5900 by default for VNC, 3389 for RDP). The SSH host tried, and nothing listens there: the VNC or RDP server is not running, listens on another port or display, or listens on another address. Nothing was sent to a server there, and the SSH host was not changed.

**What to do.**

1. Start the VNC server on that machine (TigerVNC: vncserver :0, or the vncserver@ systemd unit; x11vnc; wayvnc).
2. For an RDP host: turn Remote Desktop on at the PC (Windows: Settings, System, Remote Desktop), or start xrdp.
3. Check its port: display :0 is 5900, display :1 is 5901, and so on; RDP is 3389 unless it was changed. Change the port in the screen's settings to match.
4. If the server listens only on one address, put that address in the screen's settings, as the SSH host sees it.

**For whoever is helping.** The SSH host refused the direct-tcpip channel with "connect failed" (SSH channel open failure 2). On the SSH host, ss -ltnp shows what listens on which port.

*Since ZestSSH 4.0.*

## ZS-1802: The SSH host does not allow a remote screen through it

**What it means.** A remote screen reaches its VNC server through an SSH host, the way ssh -L does, and that SSH host's server refuses to carry such connections. Signing in to it worked; terminals and files on it are not affected.

**What to do.**

1. On the SSH host, allow forwarding in /etc/ssh/sshd_config: AllowTcpForwarding yes (or local) for an address and port, AllowStreamLocalForwarding yes (or local) for a Unix socket, then reload sshd.
2. Check that no Match block, and no restrict or no-port-forwarding in authorized_keys, turns it off for your account or key.
3. If you cannot change the server, ask whoever runs it.

**For whoever is helping.** The SSH host refused the direct-tcpip or direct-streamlocal@openssh.com channel as administratively prohibited (SSH channel open failure 1), or does not know the channel type (3). sshd -T | grep -i forwarding shows the settings in force.

*Since ZestSSH 4.0.*

## ZS-1803: The VNC server refused the password

**What it means.** The VNC server was reached and asked for its password, and did not take the one given. ZestSSH does not try again by itself, so the server does not lock you out.

**What to do.**

1. Check the password in the key this screen uses, or type it again when asked.
2. VNC passwords use at most 8 characters: anything longer is ignored by the server, so type only the first 8.
3. On the server, vncpasswd sets a new password for TigerVNC and TightVNC.

**For whoever is helping.** The security type and the server's reason, where it gave one, are in Copy details. The password itself is never written there.

*Since ZestSSH 4.0.*

## ZS-1804: The VNC server offers no security this app accepts

**What it means.** The VNC server answered, and none of the ways it offers to secure the connection is one ZestSSH uses. A screen reached directly, without an SSH host, needs VeNCrypt with a certificate (X509Vnc, X509Plain or X509None), since anything else would send the picture and your keys unprotected over the network. Anonymous TLS and RA2 are not accepted. Apple's own sign-in (Apple Remote Desktop) is not used either, since it hands the server your account's user name and password: a Mac offering only that is said here too.

**What to do.**

1. Reach the screen through an SSH host instead: plain VNC is then carried inside SSH.
2. Or turn on VeNCrypt with a certificate on the server (TigerVNC: -SecurityTypes X509Vnc with -X509Cert and -X509Key).
3. On a Mac, turn on "VNC viewers may control screen with password" in Screen Sharing's settings, and use that password.

**For whoever is helping.** Copy details lists the security types the server offered, or says the server offered only Apple Remote Desktop (RFB security type 30).

*Since ZestSSH 4.0.*

## ZS-1805: The remote screen's certificate changed

**What it means.** The VNC server showed a TLS certificate other than the one trusted for it before. That happens when the server got a new certificate, and also when something else answers in its place. Nothing was sent: no password and no keys.

**What to do.**

1. Ask whoever runs the server whether its certificate was renewed, and compare the fingerprint: openssl x509 -in <certificate file> -noout -fingerprint -sha256 (TigerVNC's -X509Cert file).
2. If it matches, connect again and accept the new certificate when asked.
3. If it does not match, do not connect: tell whoever runs the network.

**For whoever is helping.** Copy details has the SHA-256 the server showed. Certificates trusted for screens are in Settings, Security, Known hosts, as TLS certificate (VNC).

*Since ZestSSH 4.0.*

## ZS-1806: The remote screen's socket is not there

**What it means.** This screen is reached through a Unix socket on its SSH host, and the SSH host found nothing at that path: the VNC server is not running, or uses another path. The SSH host was not changed.

**What to do.**

1. Start the VNC server with that socket (TigerVNC: -rfbunixpath ~/.vnc/zest.sock -rfbunixmode 0600; x11vnc: -unixsock).
2. Check the path in the screen's settings. A path starting with ~/ is in the home folder of the account the SSH host signs in as.

**For whoever is helping.** The SSH host refused the direct-streamlocal@openssh.com channel with "connect failed" (SSH channel open failure 2). On the SSH host, ls -l shows whether the socket exists and who may open it.

*Since ZestSSH 4.0.*

## ZS-1807: Screens cannot be opened in a watched vault yet

**What it means.** The screen, or the SSH host it is reached through, is in a team vault whose sessions are watched by someone who manages it. A watched session is a terminal they follow live, and a remote screen cannot be followed yet, so it is not opened. Nothing was dialled.

**What to do.**

1. Open the host's terminal instead, which is watched as usual.
2. Or ask whoever manages the vault to put the screen in a vault whose sessions are not watched.

*Since ZestSSH 4.0.*

## ZS-1808: The SSH host this remote screen is reached through is gone

**What it means.** This screen is reached through one of your SSH hosts, and that host is no longer here: it was deleted, moved to another space, or is no SSH host any more. The screen's address is as that SSH host saw it (often localhost), so ZestSSH does not dial it directly from this device instead. Nothing was dialled and nothing was sent.

**What to do.**

1. Open the screen's settings and choose the SSH host it is reached through again, under Reach through.
2. If the SSH host was moved to another space, move the screen there too, or pick another SSH host here.
3. To reach the screen without an SSH host, choose Directly on purpose: then only VeNCrypt with a certificate is taken.

**For whoever is helping.** Copy details names the id of the SSH host the screen still points at. In a team, someone who may edit the screen's vault can pick its SSH host again for everyone.

*Since ZestSSH 4.0.*

## ZS-1809: The SSH host has no Xvnc or no xauth for an X program

**What it means.** Open an X program runs the program on the SSH host in a private X server there, TigerVNC's Xvnc, with a cookie made by xauth, and shows it in a screen tab. One of the two is not installed on the host, so nothing was started. ZestSSH never installs anything on a host itself.

**What to do.**

1. Install both on the host, then open the program again. Debian and Ubuntu: sudo apt install tigervnc-standalone-server xauth. Fedora, RHEL, Rocky and Alma: sudo dnf install tigervnc-server-minimal xorg-x11-xauth. Arch: sudo pacman -S tigervnc xorg-xauth. openSUSE: sudo zypper install xorg-x11-Xvnc xauth.
2. If you cannot install software there, ask whoever runs the host.

**For whoever is helping.** The host script found no Xvnc or no xauth on the PATH of a non-interactive sign-in (command -v), and named the package manager it found (apt-get, dnf, yum, pacman or zypper), which picks the command shown. Copy details says which tool was missing.

*Since ZestSSH 4.0.*

## ZS-1810: The private X server for an X program did not start

**What it means.** ZestSSH signed in to the SSH host and ran its small script there to start a private X server (Xvnc) for the program, and it did not start: the script found no temporary folder it could write, Xvnc stopped as it started, or no answer came within 20 seconds. The host must be Linux or another Unix whose sign-in runs commands with sh. Nothing was left on the host.

**What to do.**

1. Try again: a host that was busy may answer next time.
2. Check that /tmp (or the folder in TMPDIR) exists and is writable for your account on the host.
3. Run Xvnc -version on the host in a terminal: it should print TigerVNC's version.
4. A host whose SSH sign-in runs only a fixed command, or Windows' OpenSSH server, cannot run X programs.

**For whoever is helping.** Copy details has what the script said (no-tmp, xvnc-exited with the last lines of Xvnc's own log, xvnc-timeout, xauth, no-random) or the last lines the host printed. The script runs as exec sh -c with its text as an octal printf format, so any login shell passes it on unchanged.

*Since ZestSSH 4.0.*

## ZS-1811: The X program ended as it started

**What it means.** The private X server started on the SSH host and the program ended within a moment, so there was no window to show. Exit status 127 means the host has no program by that name; others are the program's own. Some programs hand their window to a copy already running and end at once. Nothing was left on the host.

**What to do.**

1. Check the program's name and arguments: they are run as typed in a terminal on that host.
2. Install the program on the host if it is not there.
3. For a program that hands its window to a copy already running, ask for a new one (firefox --new-instance, gnome-terminal --wait).

**For whoever is helping.** Copy details has the exit status and the last lines the program printed (its output goes to the SSH channel's error stream, never into a file on the host).

*Since ZestSSH 4.0.*

## ZS-1812: The RDP server refused the sign-in

**What it means.** The server was reached, its certificate was the one you accepted, and it did not take the user name and password. With Network Level Authentication the server says only that the sign-in failed, not why: a wrong password, a wrong user name or domain, and an account that is locked, disabled or may not sign in remotely all look the same from here. ZestSSH asks again at most three times, so an account is not locked by it.

**What to do.**

1. Check the user name and the password in the key this host uses, or type the password again when asked.
2. For a domain account, write the user name as DOMAIN\user or user@domain; for an account of the PC itself, the name alone.
3. On the PC, check that the account may sign in over Remote Desktop (Settings, System, Remote Desktop, or the Remote Desktop Users group) and that it has a password: Windows refuses accounts with an empty one.
4. A Microsoft account signs in with its email address as the user name; a PC that was only ever signed in to with a PIN or Windows Hello may need one sign-in with the password at the PC first.

**For whoever is helping.** Copy details says that the sign-in was refused and whether Network Level Authentication was used. The password is never written there, and neither are the values NTLM makes from it.

*Since ZestSSH 4.0.*

## ZS-1813: The RDP server has no Network Level Authentication

**What it means.** ZestSSH signs in to an RDP host with Network Level Authentication (NLA) unless the host says otherwise: the password is then never sent, both sides prove they know it, and the sign-in belongs to the certificate you accepted. This server answered that it has TLS only and no NLA, as xrdp does. ZestSSH did not go on without it by itself, and no user name or password was sent.

**What to do.**

1. If this is a server that has no NLA, such as xrdp, open the host and turn on "Sign in without NLA". The server then shows its own sign-in screen, and you type the password into the remote picture.
2. If this is a Windows PC, NLA should be there: check that Remote Desktop is on and that nothing between you and the PC answers in its place.

**For whoever is helping.** Copy details has the server's own answer to the connection request (it required TLS where only NLA was asked for).

*Since ZestSSH 4.0.*

## ZS-1814: The RDP server requires Network Level Authentication

**What it means.** This host is set to sign in without Network Level Authentication (NLA), and the server answered that it signs people in with NLA only, as Windows does by default. Nothing was sent to it but the connection request.

**What to do.**

1. Open the host and turn off "Sign in without NLA". ZestSSH then signs in with the user name and password of the host's key before the server shows anything.

**For whoever is helping.** Copy details has the server's own answer to the connection request (it required NLA where only TLS was asked for).

*Since ZestSSH 4.0.*

## ZS-1815: The account is locked on the RDP server

**What it means.** The server answered the sign-in with "account locked out": too many wrong passwords were tried for this account, from this app or from anywhere else, and the server refuses it for a while whatever password comes now. ZestSSH asks for a password at most three times for one connection, so that it does not cause this by itself.

**What to do.**

1. Wait: most servers unlock an account by themselves after some minutes.
2. Whoever manages the server can unlock it at once (Local Users and Groups on the PC, or Active Directory Users and Computers for a domain account).
3. If you did not type wrong passwords, someone or something else did: tell whoever manages the server.

**For whoever is helping.** Copy details has the status the server gave (STATUS_ACCOUNT_LOCKED_OUT). The password is never written there.

*Since ZestSSH 4.0.*

## ZS-1816: The account is turned off on the RDP server

**What it means.** The server answered the sign-in with "account disabled". It knows the user name and the account has been turned off there; no password will do until it is turned on again.

**What to do.**

1. Check the user name in the key this host uses: a similar name of an old account may be the one that is turned off.
2. Whoever manages the server can turn the account on again.

**For whoever is helping.** Copy details has the status the server gave (STATUS_ACCOUNT_DISABLED).

*Since ZestSSH 4.0.*

## ZS-1817: The password of the account has expired

**What it means.** The server answered the sign-in with "password expired" or "password must change": it wants a new password before it lets the account in. ZestSSH cannot change a Windows password from here.

**What to do.**

1. Change the password at the PC itself, or from another computer of the same domain (Ctrl+Alt+Del, then Change a password).
2. Or ask whoever manages the server to set a new one.
3. Then put the new password into the key this host uses, or type it when asked.

**For whoever is helping.** Copy details has the status the server gave (STATUS_PASSWORD_EXPIRED or STATUS_PASSWORD_MUST_CHANGE).

*Since ZestSSH 4.0.*

## ZS-1818: The account may not sign in over Remote Desktop

**What it means.** The server knows the account and did not find its password wrong, and still refuses it for this kind of sign-in. On Windows that is one of: the account is not among those allowed to sign in over Remote Desktop, it has no password (Windows refuses those over the network), or it is outside the hours or the computers it is limited to.

**What to do.**

1. On the PC: Settings, System, Remote Desktop, Remote Desktop users, and add the account. An administrator of the PC is allowed without being added.
2. Give the account a password if it has none.
3. For a work account, ask whoever manages the server: sign-in hours and the computers an account may use are set there.

**For whoever is helping.** Copy details has what the server gave: a status at sign-in (STATUS_ACCOUNT_RESTRICTION, STATUS_INVALID_LOGON_HOURS, STATUS_INVALID_WORKSTATION, STATUS_LOGON_TYPE_NOT_GRANTED) or its reason for ending the session (insufficient access privileges).

*Since ZestSSH 4.0.*

## ZS-1819: The remote session was taken over

**What it means.** A Windows PC lets one person use an account's session at a time. Someone signed in with the same account, from another device or at the PC's own screen and keyboard, and Windows moved the session there and ended this connection. ZestSSH does not connect again by itself: the two would keep taking the session from each other.

**What to do.**

1. If that was you somewhere else, nothing is wrong: use Reconnect here when you want the session back.
2. If it was not you, someone else knows this account's password: change it.

**For whoever is helping.** Copy details has the server's reason (another user connected to the server, forcing the disconnection of the current connection).

*Since ZestSSH 4.0.*

## ZS-1820: Remote Desktop licensing refused the session

**What it means.** The server could not give this connection a Remote Desktop licence: it found no licence server, its licences are used up, or the time it runs without them is over. This is decided on the server; nothing in ZestSSH changes it.

**What to do.**

1. Whoever manages the server has to look at its Remote Desktop licensing (on a Windows Server: RD Licensing Diagnoser).

**For whoever is helping.** Copy details has the server's own licensing reason.

*Since ZestSSH 4.0.*

## ZS-1821: The team opens remote screens through an SSH host only

**What it means.** The team this remote screen belongs to has the rule "Remote screens through SSH only", and this screen is set to connect directly. Nothing was dialled. The rule is set by the team's owners in the team's rules; the screen's other settings, its key and its certificate are as they were.

**What to do.**

1. Open the screen's settings and choose an SSH host under "Reach through". The screen's address is then the one that SSH host uses to reach it (often localhost).
2. No SSH host can reach it: ask an owner of the team, who can add one to the team or turn the rule off.

**For whoever is helping.** Copy details names the rule and no address.

*Since ZestSSH 4.0.*

## ZS-1822: The RD Gateway refused the sign-in

**What it means.** This RDP host is reached through a Remote Desktop Gateway, and the gateway did not take the account it was given: the PC's own account where the host says "the same as the PC's", or the key chosen for the gateway. Nothing reached the PC.

**What to do.**

1. Check the gateway's sign-in in the host's settings, under "Reach through": its key, or the PC's key when it signs in the same.
2. A domain account is written DOMAIN\name or name@domain.
3. Whoever manages the gateway can tell whether the account is locked or its password has run out.

**For whoever is helping.** Copy details has what the gateway said, without the account's password.

*Since ZestSSH 4.0.*

## ZS-1823: The RD Gateway does not let this account through to this PC

**What it means.** The gateway signed the account in, and its own policies refused the connection: who may connect through it (its connection authorization policy) or to which computers (its resource authorization policy). These are set on the gateway; nothing in ZestSSH changes them.

**What to do.**

1. Check that the PC's address in the host's settings is the name the gateway knows it by (the gateway may allow a computer by its name and not by its address).
2. Whoever manages the gateway can add the account, or the PC, to its policies.

**For whoever is helping.** Copy details has the gateway's code (for example 0x800759da, E_PROXY_RAP_ACCESSDENIED).

*Since ZestSSH 4.0.*

## ZS-1824: The RD Gateway could not reach the PC

**What it means.** The gateway signed the account in and was allowed through, and could not connect to the PC: its name does not resolve where the gateway is, the PC is off, or nothing listens on its Remote Desktop port.

**What to do.**

1. Check the PC's address and port in the host's settings, as the gateway sees the PC (often its name in the company's network, not an address reachable from here).
2. Check that the PC is on and allows Remote Desktop connections.

**For whoever is helping.** Copy details has the gateway's code (E_PROXY_TS_CONNECTFAILED).

*Since ZestSSH 4.0.*

## ZS-1825: The RD Gateway asks for something this version does not do

**What it means.** ZestSSH signs in to a gateway with NTLM (a user name and password) over its WebSocket transport. This gateway asked for something else: another way to sign in (a smart card, Basic, its own cookie), a message to show and agree to before connecting, its older transport of two HTTP connections, or to sign in again during the session.

**What to do.**

1. Copy details says which. Whoever manages the gateway may allow NTLM (password) sign-in, or turn off the message that needs agreeing to.
2. Where an SSH host can reach the PC, "Reach through" that SSH host does what the gateway is for.

**For whoever is helping.** Copy details names what the gateway asked for.

*Since ZestSSH 4.0.*

## ZS-1826: The RD Gateway refused the connection

**What it means.** The gateway refused for a reason of its own (its code is in Copy details), or the address is not an RD Gateway (it answered as a web server without one, or sent the connection elsewhere, which is not followed).

**What to do.**

1. Check the gateway's address and port in the host's settings (a gateway usually listens on 443).
2. Whoever manages the gateway can look its code up in the gateway's own log.

**For whoever is helping.** Copy details has the gateway's code or HTTP status.

*Since ZestSSH 4.0.*

## ZS-1827: This host goes through an RD Gateway this version does not open

**What it means.** The host's settings say to reach it through a Remote Desktop Gateway, and this version of ZestSSH cannot: its gateways are not turned on yet, the settings came from a newer version in a form this one cannot read, or the host is also set to go through an SSH host. It was not connected to without the gateway.

**What to do.**

1. Update ZestSSH on this device.
2. Or, where an SSH host can reach the PC, choose that SSH host under "Reach through" instead.

**For whoever is helping.** Copy details says which of the three it was.

*Since ZestSSH 4.0.*

## ZS-1828: The remote screen did not finish connecting

**What it means.** The screen's server (or the RD Gateway in front of it) took the connection and then said nothing more, or stopped half way, for a minute (RDP) or three minutes (VNC, where a person at the remote computer may have to allow the connection first), so ZestSSH stopped waiting and closed the connection. Nothing was changed on the server, and your other sessions are not affected.

**What to do.**

1. Try again in a moment: a server that is starting, or very busy, can be slow to answer. A VNC server that asks the person at the remote computer to allow each connection waits for them: ask them to accept it.
2. Check the port in the host's settings: something other than a VNC or RDP server listening there takes the connection and never answers as one.
3. Where the screen is reached through an SSH host or a VPN, check that it is still connected.

**For whoever is helping.** Copy details says how long it waited.

*Since ZestSSH 4.0.*

## ZS-1901: The update could not be downloaded

**What it means.** ZestSSH started downloading its new version from zestssh.com and the download did not finish: the network dropped, the site did not answer, or the disk had no room. Nothing was installed and nothing was closed: the app and every session go on as they were.

**What to do.**

1. Check that this computer is online, then choose Update and restart again.
2. Or download the new version from zestssh.com/download and install it as usual.

**For whoever is helping.** The download goes to the system's temporary folder, from https://zestssh.com/downloads/ only, and follows no redirect to another site. The request carries nothing about the device. Copy details names what failed (the status the site gave, or the network's error).

*Since ZestSSH 3.0.*

## ZS-1902: The update information is not signed by ZestSSH

**What it means.** The list of the latest release on zestssh.com named a new version, but its signature was missing or did not match the release key built into the app. Something between this computer and the site may have changed it, or the release was published unsigned. ZestSSH offers nothing from it and downloads nothing.

**What to do.**

1. Try again later: a release published unsigned by mistake is signed again quickly.
2. If it keeps showing, download the new version from zestssh.com/download in your browser, check its SHA-256 against the one listed there, and tell support.

**For whoever is helping.** The manifest (https://zestssh.com/app/latest.json) carries an Ed25519 signature over its canonical JSON, made with the release key by the website's release script. A manifest that names no newer version is never refused, signed or not. Ask whether the person is behind a proxy or filter that rewrites pages.

*Since ZestSSH 3.0.*

## ZS-1903: The downloaded update is not the released file

**What it means.** The file ZestSSH downloaded for its new version is not the size, or does not have the SHA-256, that the signed release information names. It may have been cut short or changed on the way. It was deleted without being opened; nothing was installed and nothing was closed.

**What to do.**

1. Choose Update and restart again: a download cut short is fetched again whole.
2. If it keeps showing, download the new version from zestssh.com/download and check its SHA-256 against the one listed there.

**For whoever is helping.** Copy details gives the size and SHA-256 expected and found. A repeated mismatch on one network, and none on another, points at something on that network that changes downloads.

*Since ZestSSH 3.0.*

## ZS-1904: This copy of ZestSSH cannot update itself

**What it means.** ZestSSH installs its own updates only where it can replace itself: on Windows a copy installed with the ZestSSH setup, on Linux the folder unpacked from the download, on a Mac the app in a folder this account can write to. This copy is somewhere else (a folder that needs an administrator, a system package, a disk image, or a store's copy). Nothing was changed.

**What to do.**

1. Download the new version from zestssh.com/download and install it as you installed this one.
2. On a Mac, move ZestSSH into Applications (or another folder you can write to) and open it from there; then it updates itself.

**For whoever is helping.** Copy details names the reason and the folder (with the account name taken out). A Linux copy from a distribution's package, a Flatpak or a Snap is updated by that system.

*Since ZestSSH 3.0.*

## ZS-1905: The update could not be installed

**What it means.** The new version was downloaded and checked, but installing it did not finish: the installer could not start, unpacking it failed, or ZestSSH opened again still on the old version. Your hosts, keys and settings are not touched by an update and are as they were.

**What to do.**

1. Choose Update and restart again.
2. Or download the new version from zestssh.com/download and install it as usual.
3. If it fails again, choose Copy details and send it to support: it holds the installer's own log.

**For whoever is helping.** On Windows the installer runs silently (/VERYSILENT) and writes its log to the temporary folder; Copy details carries its last lines. On Linux and macOS a small helper swaps the new folder or app in after the app quits and logs to the temporary folder; where the swap fails it puts the old version back and opens it.

*Since ZestSSH 3.0.*

## ZS-1906: A change could not be saved on this device

**What it means.** ZestSSH could not write a change to its database on this device: the disk may be full, or the database may be closed or in use for a moment. Nothing was changed, what you typed is still on the screen, and everything saved before is as it was.

**What to do.**

1. Choose Save again.
2. If it fails again, check that the disk has room, then restart ZestSSH and make the change again.
3. If it keeps failing, choose Copy details and send it to support.

**For whoever is helping.** Copy details carries what the database answered. A full disk or a database locked by another copy of the app are the usual causes.

*Since ZestSSH 3.3.*

## ZS-1907: The server did not accept a ticket

**What it means.** ZestSSH sent your ticket and the server refused it for good, so it is not tried again by itself. Nothing is lost: what you wrote is still on this device, under the ticket.

**What to do.**

1. Choose Retry to send it once more.
2. If it is refused again, choose Copy and email the text to support@zestssh.com.

**For whoever is helping.** Shown for an answer in the 4xx range other than 401, 403 and 429 to POST /v1/tickets, usually a subject or a message over the limits. Copy details carries the code and no text of the ticket.

*Since ZestSSH 3.3.*

## ZS-1908: This account cannot open tickets

**What it means.** The server refused the ticket because the account signed in on this device may not open tickets. What you wrote is still on this device.

**What to do.**

1. If you think that is wrong, email support@zestssh.com. Choose Copy to take the text with you.

**For whoever is helping.** An answer of 403 to POST /v1/tickets: the account is on the feedback block list.

*Since ZestSSH 3.3.*

## ZS-1909: A ticket was to include your account, and you are signed out

**What it means.** You ticked Include my account on a ticket that had to wait for the network. When it was sent, no account was signed in on this device, so the server refused it. What you wrote is still on this device.

**What to do.**

1. Sign in and choose Retry.
2. Or choose Send without my account. The ticket is then tied to no account.

**For whoever is helping.** An answer of 401 to POST /v1/tickets with include_account set.

*Since ZestSSH 3.3.*

## ZS-1910: Moving your data to its new place stopped

**What it means.** On a computer this version keeps each account's data in a place of its own, and moves what is here at its first start. That move stopped before it was finished. Nothing is lost: the originals stay until the move is done, and the next start goes on from where it stopped.

**What to do.**

1. Choose Retry: the move goes on from where it stopped.
2. If it stops again, close what may hold the files (a backup tool, a virus scanner), check that the disk has room, and choose Retry.
3. If it keeps showing, choose Copy details and send it to support. Do not delete or move anything in the app's folder.

**For whoever is helping.** The marker is profiles/move_v1.json in the app's data folder, and names the last step finished. A copy of the database with its write-ahead file, and of the keychain's file on Windows, is kept in the profile's pre_move folder for 30 days. An older version run in between is no harm: what it made stays where it is, and is offered as data from an older version. It can also be set aside, deleting nothing (ZS-1912).

*Since ZestSSH 3.3.*

## ZS-1911: ZestSSH could not use its keychain file

**What it means.** On Windows the secrets ZestSSH keeps on this computer are in one encrypted file. Something holds it for longer than ZestSSH waits, or it is read-only, or the disk refused, or it does not decrypt at the moment. What was being written was not kept, and what is in the file stays as it was.

**What to do.**

1. If you just changed your Windows password or just signed in to Windows, wait a minute and try again.
2. Close what may hold the file (a backup tool, a virus scanner), then try again.
3. Check that flutter_secure_storage.dat in the app's data folder is not read-only, and that the disk has room.
4. If it never opens, set it aside and start fresh: nothing is deleted. What you synced comes back with sync.
5. If it keeps showing, choose Copy details and send it to support.

**For whoever is helping.** A file that does not decrypt while flutter_secure_storage.dat.good does is renamed flutter_secure_storage.dat.broken.<time>, the newest 3 are kept, and the copy takes its place. Where neither decrypts nothing is touched, as DPAPI may answer again; set aside, they become .aside.<time>.<n> beside the new file. To go back to one: close the app, rename the new file away, and rename the old one to flutter_secure_storage.dat. Another Windows login, or a restore of the Windows profile, may yet open it.

*Since ZestSSH 3.3.*

## ZS-1912: Earlier data on this computer was set aside

**What it means.** Data here did not open, and you chose to set it aside and start fresh. It was moved to a folder of its own on this computer, with its keys, and nothing was deleted. ZestSSH does not use it. What you synced comes back with sync.

**What to do.**

1. To try it again, choose Put it back on the notice. ZestSSH closes, and it is there when you open ZestSSH again. What stands in its place is set aside in turn.
2. If it does not open again, set it aside again and write to support with this code.
3. If you do not need it, choose Delete it on the notice.

**For whoever is helping.** The folder is profiles/set_aside/<id>.<time> in the app's data folder, with the move's marker in it if a move was under way. Its entries stay in the keychain under p.<id>., and a move set aside midway keeps the old names and settings until it is put back or deleted. Put it back asks for it in profiles/put_back_v1, and the next start moves the folder and the marker back, sets the state in the list to open and opens it.

*Since ZestSSH 3.3.*

## ZS-1913: macOS did not let ZestSSH read its saved keys

**What it means.** On a Mac, ZestSSH keeps your keys, passwords and its database's key in your login keychain. macOS asked whether ZestSSH may use them ("ZestSSH wants to use your confidential information stored in flutter_secure_storage_service in your keychain"), and the answer was not yes: Deny was chosen, the question was closed, the password was not taken, or macOS could not ask (the Mac was locked). Nothing was deleted, and no new key was made. ZestSSH does not ask again by itself: sync and other background work wait until you choose Try again.

**What to do.**

1. Choose Try again. When macOS asks, choose Always Allow and type your Mac login password.
2. macOS asks once for each saved key, so it may ask several times in a row: choose Always Allow each time. Allow on its own lets ZestSSH read the key only once, and macOS asks again.
3. After each update of ZestSSH this happens again, once for each saved key, until the Mac app is signed by Apple.
4. Never delete the flutter_secure_storage_service items in Keychain Access: they are your saved keys and passwords, and the data on this Mac cannot be opened without them.

**For whoever is helping.** The Mac app is signed ad-hoc, so each build is a new app to macOS, and its items are in the legacy login keychain under the service flutter_secure_storage_service. The status macOS answered is in Copy details: -128 (the question was denied or closed), -25293 (the password was not taken), -25308 (macOS could not ask) or -34018 (the build may not use that keychain). An item macOS said no to is not asked about again in the same run until Try again. Keychain Access, the item, Access Control, adding ZestSSH under Always allow access, does what Always Allow does.

*Since ZestSSH 3.3.2.*

## ZS-1914: You are not signed in on this Mac right now

**What it means.** On a Mac the sign-in to your ZestSSH account is kept in your login keychain. As ZestSSH started, it read nobody signed in there, or could not read the sign-in at all, and you had not signed out: macOS may not have let it read the sign-in after an update. Your data on this Mac stays open as it was, and nothing was locked or deleted. Sync and your teams wait until you sign in again.

**What to do.**

1. Where the notice has Try again, choose it. If macOS asks about ZestSSH and the keychain, choose Always Allow and type your Mac login password. You are signed in again as you were.
2. Where the notice has Sign in, choose it and sign in with the same account. Your data stays as it is, and sync goes on.

**For whoever is helping.** Before 3.3.3 this locked the account's data (or hid it) and opened empty guest data with no notice. From 3.3.3 a profile is locked at a start only where the person's own sign-out began (profiles/sign_out_v1 names it) or Firebase said in the same run that the account was signed in. 3.3.3 and 3.4.0 applied that only where Firebase kept the sign-in, and the Mac build has no Firebase: there a session the keychain did not show still locked, and one it refused left the person signed out with no notice but ZS-1913. From 3.4.1 both keep the data open and say so, a refused or failed read with Try again and the details to copy. A sign-out the server confirmed (another device, a password change) still locks.

*Since ZestSSH 3.3.3.*

## ZS-1915: ZestSSH could not tell whose data this is

**What it means.** At the first start after the update to profiles, an account had been signed in on this computer, but ZestSSH could not tell which: the sign-in was not there to read (on a Mac, macOS may not have let it read the keychain). So the data here is guest data for now. Nothing was lost.

**What to do.**

1. Sign in with your account. ZestSSH then asks whether to bring the guest data into it: choose to bring it in.

*Since ZestSSH 3.3.3.*

## ZS-1960: A guide could not be loaded

**What it means.** Help > Guides fetches a guide from docs.zestssh.com when you open it, and keeps a copy for offline. This time the docs site did not answer (the device is offline, the network blocks it, or the site is down), and this device has no copy of this guide yet. Everything else in ZestSSH works as before; the guide list and its search work offline.

**What to do.**

1. Check that this device is online, then choose Try again.
2. Or open the guide in the browser, or read the docs at docs.zestssh.com on another device.

**For whoever is helping.** Copy details names what failed (a timeout, a refused connection, a failed secure connection). The request is a plain GET of https://docs.zestssh.com/guides/<slug>.md with no cookies or sign-in; a firewall or filter that blocks docs.zestssh.com causes this.

*Since ZestSSH 3.0.*

## ZS-1961: A guide could not be read

**What it means.** The docs site answered, but not with the guide: the page was not found, the answer was an error page or a web page instead of the guide's Markdown, or it was not text. A copy saved earlier, where there is one, is shown instead. Nothing on this device is changed.

**What to do.**

1. Choose Try again in a little while.
2. Or open the guide in the browser.
3. If it keeps happening, choose Copy details and send it to support: the guide may have moved.

**For whoever is helping.** Copy details carries the HTTP status. A guide that moved or was renamed on the docs site is not found by an app whose index still has its old address, until the next release.

*Since ZestSSH 3.0.*

## ZS-1962: Ask Astryx is switched off for now

**What it means.** Ask Astryx, the help assistant in Help, is a preview, and it is switched off on ZestSSH's side right now (or this server does not have it yet). Everything else in ZestSSH works as before, Help's guides and support tickets included.

**What to do.**

1. Search the guides in Help, or contact support: a person answers tickets.
2. Try Ask Astryx again later.

**For whoever is helping.** The server answered assistant-off: the preview is switched off on the server or in Astryx, or Astryx is not set up for this server. A server from before 4.0 answers 404, shown the same.

*Since ZestSSH 4.0.*

## ZS-1963: Ask Astryx is a preview for paid plans

**What it means.** While it is a preview, Ask Astryx answers for accounts on a paid plan and for members of a paid team. ZestSSH Cloud checked this account and found neither. The guides, Discord and support tickets are free for everyone, and a person answers tickets.

**What to do.**

1. Search the guides in Help, or contact support.
2. If this account has a paid plan or a team seat, sign out and in again, then try again in a few minutes.

**For whoever is helping.** The server checks a paid team seat, the account's own Juiced, and Squeezed or Juiced at the store (cached ten minutes). A purchase made a moment ago may take that long to show.

*Since ZestSSH 4.0.*

## ZS-1964: Today's Ask Astryx questions are used

**What it means.** Each account has a number of Ask Astryx questions a day while it is a preview (10 to start). Only questions Astryx answered count. They come back at midnight UTC. The guides and support tickets stay open.

**What to do.**

1. Search the guides in Help, or contact support.
2. Ask again after midnight UTC.

*Since ZestSSH 4.0.*

## ZS-1965: Ask Astryx is paused until next month

**What it means.** The Ask Astryx preview has a monthly spending limit for everyone together, and it has been reached. It opens again at the start of next month (UTC). Support tickets still reach a person, and nothing else in ZestSSH is affected.

**What to do.**

1. Contact support in Help: a person answers.
2. Or search the guides.

**For whoever is helping.** Astryx answered cap_reached: the preview's budget for this month is spent.

*Since ZestSSH 4.0.*

## ZS-1966: Astryx could not answer this time

**What it means.** ZestSSH Cloud answered, but Astryx did not: it took too long, could not be reached, or its AI service failed. Where it could, it showed the docs pages closest to the question. The question was not counted toward today's.

**What to do.**

1. Choose Try again in a minute.
2. Or open a ticket with the question: a person answers.

**For whoever is helping.** The server answered assistant-unreachable, assistant-timeout or assistant-failed, or Astryx answered with the docs only (status degraded). Copy details names which.

*Since ZestSSH 4.0.*

## ZS-1967: Your plan could not be checked at the moment

**What it means.** Ask Astryx answers for paid plans, and ZestSSH Cloud could not check this account's plan at the moment (the store's service did not answer). It is not taken for a free plan. Nothing else is affected.

**What to do.**

1. Try again in a minute.

*Since ZestSSH 4.0.*

## ZS-1968: That question could not be sent

**What it means.** ZestSSH Cloud refused the question as it was: it was too long, a screenshot was too large, or a picture was not a PNG, JPEG, WebP or GIF. Nothing was counted.

**What to do.**

1. Shorten the question, or remove the screenshot, and ask again.

**For whoever is helping.** Copy details carries the HTTP status and the server's code (assistant-too-large, assistant-bad-image, assistant-bad-request).

*Since ZestSSH 4.0.*

## ZS-1969: Too many Ask Astryx questions in a few minutes

**What it means.** Questions to Astryx are limited to a few every ten minutes per account, besides the daily number. This one was not sent and not counted.

**What to do.**

1. Wait a few minutes, then ask again.

*Since ZestSSH 4.0.*
