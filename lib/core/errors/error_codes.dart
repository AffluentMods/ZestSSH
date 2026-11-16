/// The errors the app names by code (3.0).
///
/// A message in the app is in the person's language, and there are twelve.
/// A code is the same in all of them: whoever is asked for help (support, or
/// Astryx) is given "ZS-1101" and knows which situation it is, what it
/// means and what to do, whatever language the message was read in.
///
/// This file is the one place a code is given its meaning. The page of all
/// codes (docs/ERROR-CODES.md, which the help assistant's corpus is fed
/// from) is written from it by `dart tool/error_codes.dart`, and a test
/// fails when the two differ, when a code is used twice, or when a code
/// shown anywhere in the app is not in this list.
///
/// Rules a code is given by:
/// * A code names a SITUATION WITH ITS REMEDY, not a screen: "ZestSSH Cloud
///   is not responding" is one code wherever it shows.
/// * A code is never renumbered and never given a new meaning. A situation
///   that no longer occurs keeps its code, marked as retired.
/// * The text here is English and written to be read by the person who has
///   the problem: what is going on, what still works, what to do.
/// * A failure with much behind it (a connection log, a stack) does not get
///   by on a code: it carries "Copy details" (lib/utils/error_report.dart),
///   and the report names the code too.
library;

import 'package:zestssh/config/official_identity.dart';

/// One situation the app names by code.
class ErrorCode {
  const ErrorCode(
    this.code, {
    required this.title,
    required this.means,
    required this.fix,
    this.support,
    this.since = '3.0',
    this.retired = false,
  });

  /// "ZS-" and four digits.
  final String code;

  /// What is wrong, in a few words.
  final String title;

  /// What is going on, when it shows, and what still works.
  final String means;

  /// What the person can do, one step to a line.
  final List<String> fix;

  /// What whoever helps should know beyond that: likely causes, what to
  /// ask for. Left out where [means] and [fix] say it all.
  final String? support;

  /// The version the code first shipped in.
  final String since;

  /// The situation no longer occurs; the code is kept so that it is never
  /// given to another.
  final bool retired;

  @override
  String toString() => code;
}

/// The ranges, so that a new code lands beside its like:
///
/// * 10xx  connecting to a host (SSH itself)
/// * 11xx  ZestSSH Cloud: reaching the service
/// * 12xx  sync and the sync store
/// * 13xx  the account and signing in
/// * 14xx  teams (Orchards and Crates)
/// * 15xx  team certificates
/// * 16xx  files (SFTP)
/// * 17xx  keys, the vault and the app lock
/// * 18xx  purchases
/// * 19xx  the app itself (its database, its settings, an update)
abstract final class ErrorCodes {
  // ── 10xx: connecting to a host ────────────────────────────────────────
  static const moshNotInstalled = ErrorCode(
    'ZS-1001',
    title: 'Mosh is not installed on this computer',
    means: 'The host is set to connect over Mosh, and this computer is set to open Mosh sessions through the mosh '
        'program installed on it instead of the built-in client (Settings, Terminal and SSH, on a Mac or Linux), and '
        'that program is not installed here. Before 4.0 every computer used that program (on Windows through WSL). '
        'Nothing was sent to the host. Other hosts, and this one over SSH, connect as usual.',
    fix: [
      'Turn on Built-in Mosh client in Settings, Terminal and SSH: ZestSSH then needs no mosh program on this computer.',
      'Or install Mosh with the command the message shows for your system: brew install mosh on a Mac, the package manager on Linux (sudo apt install mosh, for example).',
      'Connect again. The host needs mosh-server installed as well.',
    ],
    support: 'Shown when a Mosh host is opened with the system client chosen and no mosh program is found, in the '
        'PATH or where Homebrew and the package managers put it. Versions before 4.0 showed it on Windows too, after '
        '`wsl which mosh`. A message that the connection started and then failed is a different problem (ZS-1004 to '
        'ZS-1008).',
  );

  static const etNotInstalled = ErrorCode(
    'ZS-1002',
    title: 'Eternal Terminal is not installed on this computer',
    means: 'The host is set to connect over Eternal Terminal, and ZestSSH opens such a session through the et program '
        'of the computer itself, which is not installed here (on Windows: not installed in WSL, or WSL itself is '
        'missing). Nothing was sent to the host. Other hosts, and this one over SSH, connect as usual.',
    fix: [
      'Install Eternal Terminal with the command the message shows for your system: brew install MisterTea/et/et on a Mac, the package manager on Linux.',
      'On Windows, install WSL first (wsl --install), then et inside it (wsl sudo apt install et). ZestSSH runs et through WSL by itself.',
      'Connect again. The host needs etserver installed and running as well.',
    ],
    support: 'Shown when an Eternal Terminal host is opened and no et program is found: on macOS and Linux in the PATH '
        'or where Homebrew and the package managers put it, on Windows by `wsl which et`.',
  );

  static const shellClientOnComputerOnly = ErrorCode(
    'ZS-1003',
    title: 'Eternal Terminal hosts open on a computer only',
    means: 'The host is set to connect over Eternal Terminal, which ZestSSH opens through the et program of the '
        'computer it runs on. A phone or a tablet has no such program, so the host does not open there. It often '
        'shows for a host added on a computer and synced to the phone. Nothing was sent to the host. (Before 4.0 '
        'Mosh hosts showed it too; ZestSSH now has its own Mosh client on every device.)',
    fix: [
      'Open the host on a computer with ZestSSH, where it connects as set.',
      'Or, to connect from this device, edit the host and set it to SSH or Mosh. Keep-alive and reconnecting keep an SSH session going on an unsteady network, and Mosh keeps one through changes of network.',
    ],
  );

  static const moshServerMissing = ErrorCode(
    'ZS-1004',
    title: 'mosh-server is not installed on the host',
    means: 'ZestSSH signed in to the host over SSH to start mosh-server there, which a Mosh session needs on the '
        'host, and the host has none: its shell did not find mosh-server by name, nor in the folders package '
        'managers put it in. Nothing else was changed on the host, and the host still opens over SSH.',
    fix: [
      'Install Mosh on the host with its package manager (sudo apt install mosh, sudo dnf install mosh, brew install mosh on a Mac), then connect again.',
      'Or edit the host and set it to SSH.',
    ],
    support: 'mosh-server was run over SSH by name, then as /usr/local/bin, /opt/homebrew/bin, /opt/local/bin, '
        '/usr/bin and /snap/bin/mosh-server; each ended with "command not found" or exit status 127. The connection '
        'log lists each try.',
    since: '4.0',
  );

  static const moshServerLocale = ErrorCode(
    'ZS-1005',
    title: 'mosh-server found no UTF-8 locale on the host',
    means: 'mosh-server is installed on the host but refuses to start without a UTF-8 locale, and the host has '
        'neither of the two ZestSSH asks for (en_US.UTF-8, then C.UTF-8). Nothing else was changed on the host, and '
        'the host still opens over SSH.',
    fix: [
      'On the host, make a UTF-8 locale, for example: sudo locale-gen en_US.UTF-8 (Debian and Ubuntu), or install glibc-langpack-en (Fedora and RHEL).',
      'Connect again.',
    ],
    support: 'mosh-server said "needs a UTF-8 native locale to run" for -l LANG=en_US.UTF-8 and for -l '
        'LANG=C.UTF-8. What it said is under the message, with the key of any session taken out.',
    since: '4.0',
  );

  static const moshServerDidNotStart = ErrorCode(
    'ZS-1006',
    title: 'mosh-server did not start on the host',
    means: 'ZestSSH ran mosh-server on the host over SSH, and it printed no MOSH CONNECT line with the port and key '
        'a Mosh session needs. What it said instead is under the message. The host still opens over SSH.',
    fix: [
      'Read what mosh-server said under the message: it often names the problem (no free UDP port in 60000 to 61000, a full disk, a shell that prints something at sign-in that breaks it).',
      'Try mosh-server new on the host in an SSH session to see the same.',
      'Or edit the host and set it to SSH.',
    ],
    support: 'The command was mosh-server new -s -c 256 -p 60000:61000 -l LANG=en_US.UTF-8 (without -s through a '
        'jump host), run without a terminal. The output shown has the banner and any session key taken out.',
    since: '4.0',
  );

  static const moshNoAnswer = ErrorCode(
    'ZS-1007',
    title: 'mosh-server started, and nothing answered over UDP',
    means: 'mosh-server started on the host and waits for this device on a UDP port between 60000 and 61000, and '
        'none of what ZestSSH sent there got an answer within 15 seconds. Almost always a firewall drops UDP to those '
        'ports: the host\'s own (ufw, firewalld), a cloud provider\'s security group, or a network on the way. The '
        'host still opens over SSH, which needs only its TCP port.',
    fix: [
      'Open UDP ports 60000 to 61000 to the host: sudo ufw allow 60000:61000/udp, firewall-cmd --add-port=60000-61000/udp, or the inbound rules of the cloud provider.',
      'Connect again. A host behind a jump host or a network that lets no UDP through cannot be reached over Mosh: set it to SSH.',
    ],
    support: 'The message names the port mosh-server chose. mosh-server ends by itself after 60 seconds without '
        'contact, so nothing is left running on the host. Datagrams went to each address the host name resolves '
        'to.',
    since: '4.0',
  );

  static const moshSessionFailed = ErrorCode(
    'ZS-1008',
    title: 'The Mosh session could not go on',
    means: 'The built-in Mosh client stopped: the host\'s mosh-server speaks another version of the protocol, no '
        'UDP socket could be opened on this device, or the client met something it could not handle. What it said '
        'is under the message. Other sessions are not touched, and the host still opens over SSH.',
    fix: [
      'Connect to the host again: a new session starts a new mosh-server.',
      'If it happens again, update mosh on the host (a version from 1.2 on speaks the same protocol), or set the host to SSH, and send the details to support.',
    ],
    since: '4.0',
  );

  // ── 11xx: reaching ZestSSH Cloud ──────────────────────────────────────
  static const cloudReplyTooLarge = ErrorCode(
    'ZS-1108',
    title: 'ZestSSH Cloud sent more than an answer may be',
    means: 'What came back to a request was much longer than any answer of the service, so ZestSSH stopped reading it. '
        'It may be something on this network answering in the service\'s place. Nothing of it was used. SSH to your '
        'hosts and everything on this device work as usual.',
    fix: [
      'Try again in a little while.',
      'If it keeps showing, try another network, and tell support with Copy details.',
    ],
    support: 'The limit is 16 MB for an answer of the API, and 128 MB for sync and teams, which carry records. Copy '
        'details names the host that answered.',
    since: '3.3',
  );

  static final cloudNotResponding = ErrorCode(
    'ZS-1101',
    title: 'ZestSSH Cloud is not responding',
    means: 'The app asked ZestSSH Cloud for something and got no answer, while this device has a network. '
        'Nothing on the device is affected: your hosts, saved logins and keys, sessions that are running, and '
        'team certificates the device already holds all keep working. What waits until the service answers again '
        'is whatever goes through it: sync to ZestSSH Cloud, changes to a team (members, roles, rules, '
        'invitations), new team certificates, access requests, live session sharing and support tickets. The app '
        'keeps checking by itself and catches up when the service is back.',
    fix: [
      'Open another website on this device. If nothing opens, the problem is the connection of this device, not ZestSSH Cloud.',
      'If other sites open, the service is down or cannot be reached from your network. Nothing needs doing: the app keeps checking and catches up by itself.',
      'On a company network, a firewall, VPN or proxy that blocks $kZestApiHost looks the same. Ask for it to be allowed, or try another network.',
      'To connect to a host in the meantime, connect as usual: connecting does not go through ZestSSH Cloud.',
    ],
    support: 'Shown when a request to the API host fails with no HTTP answer (refused, reset, timed out, no DNS) and '
        'the system reports a network. If only one user reports it, suspect their network (DNS filtering, TLS '
        'inspection, a blocked host). If many do at once, it is an outage. It is what one failed request can say by '
        'itself. Within seconds the app asks the ZestSSH status service, and its notice then says which of three it '
        'is: ZS-1105 (the service is down), ZS-1106 (it is up and this network blocks it) or ZS-1107 (the device '
        'reaches nothing of ZestSSH). A message shown at the very moment a request failed says ZS-1101 in any build; '
        'one that still says it a minute later came from a build with no status service set up.',
  );

  static const deviceOffline = ErrorCode(
    'ZS-1102',
    title: 'This device is offline',
    means: 'The device has no network, so ZestSSH Cloud cannot be reached from it. Everything on the device keeps '
        'working for hosts it can still reach (on the same local network, for example). Whatever goes through '
        'ZestSSH Cloud waits until the device is online again, and then catches up by itself.',
    fix: [
      'Connect the device to a network (Wi-Fi, cable or mobile data).',
      'If the system says it is connected and this still shows, turn the connection off and on, or restart the app.',
    ],
    support: 'Shown when a request to the API host fails and the system reports no network at all. On Linux without '
        'NetworkManager the system cannot say how the network stands; the app then reports ZS-1101 instead.',
  );

  static const cloudFault = ErrorCode(
    'ZS-1103',
    title: 'ZestSSH Cloud answered with a fault',
    means: 'ZestSSH Cloud, or the network in front of it, answered with a server error (an HTTP status from 500 to '
        '599). The fault is on the side of the service, not on this device and not in what you entered. Everything '
        'on the device keeps working; what goes through the service waits, and the app tries again by itself.',
    fix: [
      'Wait a few minutes and try again: these faults usually pass.',
      'If the same thing fails for more than an hour, send the details (Copy details, where the message offers it) to support with the time it happened.',
    ],
    support: 'The HTTP status is in the message and in the copied details. 502, 503, 504 and 520 to 530 mean the '
        'service could not be reached behind its front; 500 is a fault inside the service: look in its log at that time.',
  );

  static final cloudNotSecure = ErrorCode(
    'ZS-1104',
    title: 'No secure connection to ZestSSH Cloud',
    means: 'The device reached something at the address of ZestSSH Cloud but could not verify that it is ZestSSH '
        'Cloud: the certificate it was shown did not check out. The app refuses to talk to it then, so nothing was '
        'sent. The two usual causes are a wrong date or time on the device (a certificate is only valid within its '
        'dates) and a network that reads connections on the way (a company proxy or security appliance, some '
        'antivirus programs, the sign-in page of a guest Wi-Fi). Everything on the device keeps working.',
    fix: [
      'Check the date, the time and the time zone of the device, and set them to automatic.',
      'On a guest or hotel Wi-Fi, open a browser and finish the sign-in page of the network first.',
      'On a company network, ask whether connections are inspected: $kZestApiHost has to be let through unchanged.',
      'Try another network, such as the hotspot of a phone. If it works there, the first network is the cause.',
    ],
    support: 'The app checks the certificate against the trusted roots of the system and does not accept one that '
        'fails, on purpose: accepting it would let whoever is in the middle read what the account sends. There is no '
        'switch in the app to turn this off, and none should be advised.',
  );

  static const cloudDown = ErrorCode(
    'ZS-1105',
    title: 'ZestSSH Cloud is down',
    means: 'ZestSSH Cloud is down, and the app knows it for certain: when the service gave no answer, the app asked '
        'the ZestSSH status service, which runs apart from it and looks at it from outside, and the status service '
        'said, signed, that the service is down. Nothing is wrong on this device or with its network. Everything on '
        'the device keeps working: your hosts, saved logins and keys, sessions that are running, and team '
        'certificates the device already holds. What goes through the service waits (sync to ZestSSH Cloud, changes '
        'to a team, new team certificates, access requests, live session sharing, support tickets), and the app '
        'keeps checking and catches up by itself when the service is back. Where a team has set an offline limit, '
        'the time the service itself is down is not counted against a device, for up to seven days in one stretch.',
    fix: [
      'Nothing needs doing on this device, and nothing done on it would help: the fault is on the side of the service.',
      'To connect to a host in the meantime, connect as usual: connecting does not go through ZestSSH Cloud.',
      'The app checks again by itself every few minutes. On a computer, a click on the notice in the status bar checks at once.',
    ],
    support: 'Shown instead of ZS-1101 when the status service (which runs apart from the API) answered with a signed '
        '"down". The notice says since when. If a user reports ZS-1105 while the service is in fact up, look at the '
        'status service itself: it says "down" only when the health check of the API gets no answer, an HTTP status '
        'from 500 to 599, or an answer that says it is not ok, twice in a row.',
  );

  static final cloudBlockedHere = ErrorCode(
    'ZS-1106',
    title: 'ZestSSH Cloud is up, but this network does not let the device reach it',
    means: 'The app got no answer from ZestSSH Cloud, asked the ZestSSH status service (which looks at the service '
        'from outside), and was told, signed, that the service is up. So the service works, and something between '
        'this device and it is in the way: a firewall, a VPN, a proxy, a DNS filter or a security program, on the '
        'device or on the network it is on. Everything on the device keeps working; what goes through ZestSSH Cloud '
        'waits until the device can reach it.',
    fix: [
      'Try another network, such as the hotspot of a phone. If it works there, the first network is the cause.',
      'If a VPN is in use, turn it off for a moment (or on, if it was off) and see whether that changes it.',
      'On a company network, ask for $kZestApiHost to be allowed (HTTPS, port 443).',
      'If a DNS filter or an ad blocker for the whole network is in use (Pi-hole, NextDNS, a setting of the router), allow $kZestApiHost there.',
    ],
    support: 'The device reached the status service and not the API host ($kZestApiHost). Look for a rule that '
        'names the API host: DNS filtering, an allow list of a proxy, inspection of secure connections that breaks '
        'only some hosts. If many users on different networks report it at the same time, the way between the '
        'provider and the API may be at fault although the status service says "up": treat that as an incident.',
  );

  static final cloudNothingReached = ErrorCode(
    'ZS-1107',
    title: 'Nothing of ZestSSH could be reached from this device',
    means: 'The system says this device has a network, but the app reached neither ZestSSH Cloud nor the ZestSSH '
        'status service, which run apart from each other. The most likely reason by far is that the device is not '
        'reaching the internet at all: a Wi-Fi that wants a sign-in first, a router whose line is down, a network '
        'with no way out. Hosts the device can still reach (on the same local network, for example) keep working, '
        'and so does everything stored on the device.',
    fix: [
      'Open any website in a browser on this device. If none opens, the device has no internet: that is what to fix.',
      'On a guest or hotel Wi-Fi, a sign-in page usually shows in the browser: finish it.',
      'Check the date and the time of the device, and set them to automatic.',
      'If other websites open, something blocks both ZestSSH addresses (a firewall or a DNS filter): try another network, or ask for $kZestApiHost to be allowed.',
    ],
    support: 'Shown when the API gave no answer, the system reports a network, and the status service gave no '
        'statement the app could believe: no answer, or an answer that is no signed statement (the sign-in page of '
        'a guest network, for one). A wrong clock on the device lands here too, because a statement is believed '
        'only when its time is now, give or take five minutes: ask for the date and time of the device. A build '
        'with no status service set up reports this situation as ZS-1101.',
  );

  // ── 12xx: sync and the sync store ─────────────────────────────────────
  static const syncStoreUnreachable = ErrorCode(
    'ZS-1201',
    title: 'Your sync storage cannot be reached',
    means: 'Background sync could not reach the place your data syncs to (ZestSSH Cloud, or your own WebDAV, S3 or '
        'Google Drive storage). Nothing is lost: changes made on this device are kept and marked to go. The app '
        'tries again by itself, after 30 seconds at first and then at most every 15 minutes, and at once when the '
        'network of the device comes back. Sync is not paused and nothing has to be pressed.',
    fix: [
      'Nothing needs doing if the storage is only down for a while.',
      'If it is your own storage, check that it is running and that its address has not changed (Account, Sync storage).',
      'To try at once, press "Sync now" on the Account page.',
    ],
    support: 'Before 3.0 three such failures in a row stopped background sync until the app was restarted. If a user '
        'on an older version reports sync that "just stopped", that is why: a restart or "Sync now" resumes it.',
  );

  static const syncFailedHere = ErrorCode(
    'ZS-1202',
    title: 'Sync could not finish on this device',
    means: 'A step of sync failed on the device itself and not at the storage: reading what was to be sent, or '
        'taking in what was fetched. The storage was reached and is fine. Nothing was lost: what is on the device '
        'is as it was, and so is what the storage holds. After three such failures in a row background sync pauses '
        'until "Sync now" is pressed or the app is started again.',
    fix: [
      'Press "Sync now" on the Account page.',
      'If it fails again, restart the app and try once more.',
      'If it still fails, copy the details from the message and send them to support: they say what the device could not do.',
    ],
    support: 'The details name the error that was caught. A database that is locked, or a device that is out of '
        'storage, are the usual causes. Changes from other devices that this version of the app cannot read are a '
        'different message, which asks for the app to be updated.',
  );

  static const syncWrittenFirst = ErrorCode(
    'ZS-1203',
    title: 'Another device synced at the same moment',
    means: 'Two of your devices sent changes to the sync storage at the same moment, and this one came second, twice '
        'in a row. The storage takes one writer at a time, so that neither writes over the other. Nothing was lost: '
        'the changes made on this device are kept and marked to go, and the app tries again by itself, first '
        'fetching what the other device sent.',
    fix: [
      'Nothing needs doing: it passes by itself, usually within a minute.',
      'If it still shows after an hour, press "Sync now" on the Account page of this device.',
      'If "Sync now" says the same, copy the details and send them to support.',
    ],
    support: 'Versions before 3.0 showed this as "Version conflict: server is at v1, expected v3. Pull and retry." '
        'They also showed it for ever on a device whose sync storage had been restored from a backup: the storage '
        'was behind the device, and every write was refused as out of date. From 3.0 a device notices storage that '
        'went back, merges what it holds and sends what it lacks. A user on an older version who keeps seeing the '
        'old text after a restore should update.',
  );

  static const syncHostingNotIncluded = ErrorCode(
    'ZS-1204',
    title: 'ZestSSH Cloud storage comes with Juiced',
    means: 'Sync was to keep its copy on ZestSSH Cloud, the storage ZestSSH runs, and that storage comes with Juiced. '
        'The account signed in here has no Juiced, so ZestSSH Cloud keeps no copy for it. Sync itself is free: it '
        'works the same with storage of your own (WebDAV, Nextcloud, S3 or Google Drive). Nothing on this device was '
        'changed or lost.',
    fix: [
      'To sync for free, choose storage of your own: on the Account page, Storage, then WebDAV, S3 or Google Drive.',
      'To keep the copy on ZestSSH Cloud, get Juiced, then set up sync again.',
      'If Juiced was bought with another account, sign out and sign in with that one: a purchase belongs to the '
          'account that made it.',
    ],
    support: 'ZestSSH Cloud answers any sync request of an account without Cloud Sync (Juiced) with 403 and the code '
        'ENTITLEMENT_REQUIRED. Versions before 3.0 said "Couldn\'t reach the sync server" for it while sync was being '
        'set up, which reads as an outage: ask whether ZestSSH Cloud was the storage chosen and whether the account '
        'has Juiced.',
  );

  static const syncCloudDeviceLimit = ErrorCode(
    'ZS-1205',
    title: 'ZestSSH Cloud syncs up to 7 devices for one person',
    means: 'ZestSSH Cloud syncs one person\'s hosts and keys on up to 7 devices (Juiced, and each seat of a team; a '
        'member of a Business team has no limit). The account signed in here already syncs on 7 that signed in '
        'before this one, so this device was refused. Nothing on this device was changed or lost, and sync to storage '
        'of your own is never limited.',
    fix: [
      'On a device you still use: Profile & Sync, Devices, then sign out a device you no longer use. This one then '
          'syncs at its next try.',
      'Or sign this device out instead, if it is the one you no longer need.',
    ],
    support: 'ZestSSH Cloud answers a sync request from a device past the cap with 403 and the code '
        'cloud-device-limit (from 22 October 2026). The first 7 signed-in devices, oldest first, keep syncing; '
        'devices signed out, or signed out by "Sign out everywhere", do not count; a request that does not say which '
        'device it is (an app from before 3.0) is not counted. A team vault\'s items answer the same way.',
  );

  static const syncKeySecretUnread = ErrorCode(
    'ZS-1206',
    title: 'This device cannot read a key\'s saved secret',
    means: 'One of your SSH keys has a secret saved on this device (its private key, passphrase, password or '
        'certificate) that the device cannot open. So that the key is not passed on as one with no secret, sync and '
        'backups stop on this device until the secret reads again. Nothing was lost: nothing was sent or written, '
        'your other devices and your sync storage keep their copy of the key, and connecting from this device with '
        'your other keys still works.',
    fix: [
      'If the app is locked, unlock it and press "Sync now".',
      'Open the key the message names, on this device, and save its private key, passphrase or password again.',
      'If you do not have the private key at hand, export the key on another of your devices and import it on this one.',
      'Do not delete the key on this device to get sync going: a deletion syncs to your other devices.',
    ],
    support: 'With Encrypt data at rest on, secrets in the system storage are sealed with a key kept in the app\'s '
        'database. One sealed by another database (a restored or moved profile, a storage copied from another '
        'install) or damaged does not open. Before 4.0 it read as "no secret" and was synced as that, and every '
        'other device deleted its readable copy. The details name the storage slot, never the secret. Saving the '
        'secret again writes it under this database\'s seal.',
    since: '4.0',
  );

  static const recoveryKeyNotChecked = ErrorCode(
    'ZS-1210',
    title: 'The recovery key could not be checked',
    means: 'While restoring with a recovery key, the sync server did not answer the question whether the key is the '
        'right one (it was not reached, or it answered with a fault). Nothing was said about the key: it may be '
        'perfectly right.',
    fix: [
      'Do not throw the key away and do not assume it is wrong.',
      'Try again in a few minutes.',
      'If it keeps failing, check the connection of the device (see ZS-1101 and ZS-1102).',
    ],
    support: 'Before 3.0 every failure of a restore said "That recovery key didn\'t work", a network failure '
        'included. A user who was told so on an older version may hold a good key.',
  );

  static const recoveryKeyRefused = ErrorCode(
    'ZS-1211',
    title: 'The recovery key is not the one for this vault',
    means: 'The store was asked and answered: this recovery key does not open the synced data. Either it was typed '
        'with a mistake, or it is an older key (a recovery key that was replaced no longer works), or it belongs to '
        'another account.',
    fix: [
      'Type it again, slowly. A key begins with ZEST, and the letters I, L and O and the digits 0 and 1 are never part of one.',
      'If the key was replaced at some point (Account, Recovery key, Replace), only the newest one works.',
      'Check that you are signed in to the account the key was made for.',
      'If you remember the sync password after all, you do not need the key: go back and enter the password.',
    ],
    support: 'There is no way to recover synced data without the sync password or the current recovery key: the '
        'service never holds either. Say so plainly.',
  );

  // ── 13xx: the account and signing in ──────────────────────────────────
  static const signInNoPort = ErrorCode(
    'ZS-1301',
    title: 'No port for the browser to come back to',
    means: 'Signing in on a computer happens in the browser, which then comes back to ZestSSH on a port of this '
        'computer alone (never reachable from outside it). ZestSSH asked for one at 32768 or above, the ones the '
        'website sends a sign-in back to, and could not have one. Nothing was sent anywhere. Your hosts connect as '
        'usual; this concerns only signing in.',
    fix: [
      'Try again: a port that was taken may be free now.',
      'If it keeps showing, something on this computer holds or blocks those ports (a firewall, a security tool, or a '
          'setting that moved the range of ports the system hands out). Allow ZestSSH to listen on 127.0.0.1.',
    ],
    support: 'Copy details gives what the system said. `netsh int ipv4 show dynamicport tcp` on Windows, or '
        '`sysctl net.ipv4.ip_local_port_range` on Linux, shows the range the system hands out. The website refuses a '
        'loopback callback below 32768, so a lower port is not used.',
    since: '3.3',
  );

  static const profileDidNotOpen = ErrorCode(
    'ZS-1302',
    title: 'This account\'s data on this computer did not open',
    means: 'You signed in, and the hosts, keys and settings this account keeps on this computer did not open. Nothing '
        'was changed and nothing was deleted, and the app stays where it was, so what is on screen still works.',
    fix: [
      'Choose Retry, or sign in again.',
      'If it keeps showing, write to support with this code. Your data stays on this computer as it is.',
    ],
    support: 'The account is known on this computer and its database did not open with its key: a full disk, a file '
        'another program holds, or a damaged database. Never ask the person to delete anything: every profile has its '
        'own folder and keys, and what did not open is still there.',
    since: '3.3',
  );

  static const profileCopyDoesNotOpen = ErrorCode(
    'ZS-1303',
    title: 'What ZestSSH Cloud holds does not open this account\'s data here',
    means: 'While an account is signed out, its data on a computer is locked with a secret that ZestSSH Cloud keeps. '
        'ZestSSH Cloud handed one back, and it does not open the copy on this computer. Nothing was changed, and the '
        'data on this computer is still there, locked.',
    fix: [
      'Try signing in again.',
      'If it keeps showing, write to support with this code. Do not remove anything from this computer in the meantime.',
    ],
    support: 'This should not happen: the device checks that a secret opens its copy before it forgets it, and the copy '
        'is bound to its profile and its id. Ask whether the app\'s files or this OS user\'s keychain were restored from '
        'elsewhere.',
    since: '3.3',
  );

  static const profileCopyLost = ErrorCode(
    'ZS-1304',
    title: 'This account\'s old data on this computer can no longer be opened',
    means: 'The secret that opened this account\'s locked data on this computer was deleted, in Settings, Account, '
        'so that copy can never be opened again. The app made a new, empty profile for the account. What you synced '
        'comes back with sync. The old files stay on this computer, and nothing uses them.',
    fix: [
      'Turn sync on with your sync password to bring back what you synced.',
      'Hosts and keys that were never synced cannot be recovered from the old copy: add them again.',
    ],
    since: '3.3',
  );

  static const profileHiddenNotLocked = ErrorCode(
    'ZS-1305',
    title: 'Your data is hidden, not locked',
    means: 'You signed out, and the app did not lock this account\'s data, because it could not be sure ZestSSH '
        'Cloud holds the secret that locks it: this computer had never been able to tell ZestSSH Cloud the secret, '
        'the secret was deleted under Locked copies on your computers, or this computer could not ask ZestSSH Cloud '
        'as you signed out (it was offline, or ZestSSH Cloud did not answer). The app no longer shows the data and '
        'nothing is lost, but its key is still on this computer, so someone who can read this OS user\'s keychain '
        'could open it.',
    fix: [
      'Sign in again, then sign out while online: the sign-in tells ZestSSH Cloud the secret where it does not hold '
          'it, and a sign-out that finds it there locks the data.',
    ],
    since: '3.3',
  );

  static const profileNeedsFreshSignIn = ErrorCode(
    'ZS-1306',
    title: 'Opening this account\'s data takes a recent sign-in',
    means: 'ZestSSH Cloud hands back what opens a signed-out account\'s data only after a sign-in from the last ten '
        'minutes, so a session copied off this computer cannot fetch it. This sign-in is older than that. Nothing was '
        'changed, and the data on this computer is still there, locked.',
    fix: ['Sign in again, and open it right away.', 'If it keeps showing, check that this computer\'s clock is right.'],
    since: '3.3',
  );

  static const passwordLinkNotSent = ErrorCode(
    'ZS-1307',
    title: 'The link to choose a password could not be sent',
    means: 'ZestSSH Cloud did not send the email: it is busy, or out of reach. Nothing about the account or '
        'its password changed.',
    fix: [
      'On a computer, open the sign-in page on zestssh.com and choose Forgot password? there: it reaches the email '
          'service another way.',
      'Or try again in a moment.',
    ],
    support: 'ZestSSH Cloud\'s answer was 429 (too many asked for this address or from this network) or 503 (its mail is '
        'not configured or down), or none came. A computer holds no Firebase of its own, so the website is what it '
        'goes to.',
    since: '3.3',
  );

  static const tooManyAccounts = ErrorCode(
    'ZS-1308',
    title: 'This computer holds as many accounts as it can',
    means: 'A computer keeps the data of five accounts at most, and guest data does not count. This account would be the '
        'sixth, so nothing was made for it, and nothing on this computer changed.',
    fix: [
      'Open the account row at the bottom left and choose Remove from this computer beside an account you no longer use '
          'here. Then sign in again.',
    ],
    support: 'Removing an account deletes its folder and its keys on this computer. What it synced stays at ZestSSH Cloud, '
        'and it comes back when that account signs in here again.',
    since: '3.3',
  );

  static const accountSwitchFailed = ErrorCode(
    'ZS-1309',
    title: 'The other account could not be opened',
    means: 'The data of the account you picked did not open, or the browser signed in to another account than that one, '
        'so the app stayed where it was. Nothing of either account was changed or lost.',
    fix: [
      'Try again, and sign in to the account you picked.',
      'If it keeps showing, restart ZestSSH. Copy details gives what went wrong.',
    ],
    support: 'Its database did not open or its settings could not be read before anything else changed. ZS-1302 is the '
        'same at a sign-in.',
    since: '3.3',
  );

  static const accountNotRemoved = ErrorCode(
    'ZS-1310',
    title: 'An account could not be removed from this computer',
    means: 'Its folder would not go, as something holds a file in it. Nothing opens it now, and the removal is tried '
        'again each time the app starts.',
    fix: ['Restart ZestSSH.', 'If it stays, close whatever may have the folder open, such as a backup tool.'],
    since: '3.3',
  );

  static const lockedCopyNotDeleted = ErrorCode(
    'ZS-1311',
    title: 'A locked copy could not be listed or deleted',
    means: 'ZestSSH Cloud could not be asked, or would not do it this time. Hosts on this computer connect as usual, and '
        'nothing else depends on this.',
    fix: ['Check the connection and try again.'],
    support: 'Deleting one takes a sign-in or a confirmation from the last ten minutes (recent-sign-in-required); the app '
        'asks for one first.',
    since: '3.3',
  );

  static const twoStepLeftOff = ErrorCode(
    'ZS-1312',
    title: 'Two-step sign-in went off while switching to the other kind',
    means: 'An account uses passkeys or an authenticator app for two-step sign-in, not both, so switching from one to '
        'the other removes the old one first. The old one was removed, and the new one could not be set up, so two-step '
        'sign-in is off now and the backup codes stopped working: signing in needs only the password, or Google, Apple, '
        'Microsoft or the company sign-in. Nothing else of the account changed, and the hosts and keys stay on every device.',
    fix: [
      'Open Settings, Account and add the passkey again, or set up the authenticator app: either turns two-step '
          'sign-in on again.',
      'Save the new backup codes it gives you.',
    ],
    support: 'ZestSSH Cloud answered authenticator-removed-passkey-failed (the authenticator app went, and the bridge of '
        'the passkey was not enrolled or kept), or the setup of the authenticator app stopped after DELETE '
        '/v1/account/two-step/passkeys. The account was emailed. Firebase holds one TOTP factor per account, which is why '
        'the old one goes before the new one comes.',
    since: '3.3',
  );

  static const twoStepOtherKind = ErrorCode(
    'ZS-1313',
    title: 'This account uses the other kind of second step',
    means: 'An account uses passkeys or an authenticator app for two-step sign-in, not both: the sign-in service keeps '
        'one of the two for each account. This account has the other kind, so nothing was added and nothing changed. '
        'Signing in works as before.',
    fix: [
      'Add it again and choose Replace when ZestSSH asks: the one the account has goes as the new one comes.',
      'Or keep the one the account has. Your backup codes work with either.',
    ],
    support: 'ZestSSH Cloud answered authenticator-app-on, or Firebase answered maximum-second-factor-count-exceeded '
        '(SECOND_FACTOR_LIMIT_EXCEEDED). The app asks before it replaces one with the other; this shows where what it knew '
        'of the account was out of date.',
    since: '3.3',
  );

  // ── 14xx: teams ───────────────────────────────────────────────────────
  static const watchedNobodyToAsk = ErrorCode(
    'ZS-1401',
    title: 'A watched Crate, and nobody can be asked to watch',
    means: 'The host is in a team Crate whose sessions are watched: a session starts once someone else who manages '
        'the Crate has joined to watch it. Asking someone goes through ZestSSH Cloud, which this device cannot '
        'reach right now (ZS-1101 to ZS-1107 say which way), so nobody can be asked. An owner of the team may then '
        'connect after giving a reason; everyone else may only where the owners allowed that for this Crate, and '
        'here they have not. Nothing is wrong with the host. Hosts in Crates that are not watched connect as ever.',
    fix: [
      'Ask an owner of the team to connect, if it cannot wait: an owner is asked for a reason and let through, and '
          'the other owners are told afterwards.',
      'Or wait: once ZestSSH Cloud answers again, connecting asks someone to watch as usual.',
      'An owner who wants the team to get through an outage by itself can allow it for the Crate: under Team, '
          'Crates, in the watched Crate\'s row. Each such session is then reported to the owners with its reason.',
    ],
    support: 'This is the team\'s own rule and is kept by the app on the device. It is never shown to an owner. '
        'A session that goes on with nobody watching is reported in the team\'s record once the device is back '
        'online: who connected, to which host, when and why.',
  );

  static const joinCodeTooManyTries = ErrorCode(
    'ZS-1402',
    title: 'Too many tries with invite codes',
    means: 'Joining a team with an invite code was tried too often with codes that did not work, from this '
        'account or from this network, so ZestSSH Cloud takes no more tries for now. The code itself may be '
        'fine. Nothing else is held up: hosts, sync and the teams you are in work as ever.',
    fix: [
      'Wait an hour, then enter the code again.',
      'Check the code with whoever sent it, or ask them for a new one: a code works once, and stops working when '
          'it lapses or is cancelled.',
    ],
    support: 'Only tries that found no live code count: ten an hour for each account and thirty an hour for each '
        'network address. Looking at a live code and joining with it do not count.',
  );

  static const teamServerBehind = ErrorCode(
    'ZS-1403',
    title: 'ZestSSH Cloud lost recent changes to a team',
    means: 'ZestSSH Cloud was restored from a backup and no longer has the newest changes to this team, among them '
        'the one that put you in it. This device keeps everything it has of the team, and its hosts connect as '
        'usual. It does not sync the team until ZestSSH Cloud has the changes back: the device of any team member '
        'who still has them sends them back by itself the next time it syncs, and so do the devices of whoever '
        'wrote items since.',
    fix: [
      'Nothing to do on this device: it syncs again by itself once the changes are back.',
      'If it does not within a day, ask an owner or admin of the team to open ZestSSH: their device sends the '
          'changes back when it syncs.',
    ],
    support: 'The server holds fewer entries of the team\'s record than this device, and this account is not in the '
        'part it holds. A member who is sends the rest back (POST /v1/orchards/:id/record/mend), checked as the first '
        'time and only up to the server\'s own receipt. Key copies the server lost are sealed again by members who '
        'hold the keys. Nothing on the device is deleted while it waits.',
  );

  static const teamRecordParted = ErrorCode(
    'ZS-1404',
    title: 'This device stopped following a team\'s record',
    means: 'The record of who is in the team and what each may do, as ZestSSH Cloud shows it, does not follow the one '
        'this device has checked: it holds fewer entries and cannot take back the ones this device has, or it '
        'shows other entries in their place. That can follow a restore of ZestSSH Cloud from a backup during which '
        'someone changed the team, or it can be the server hiding a change (a removal, say). This device does not '
        'sync the team then. What it holds stays, and the team\'s hosts connect as usual.',
    fix: [
      'Ask an owner of the team to open ZestSSH and look at the team: if their device shows the same, contact '
          'ZestSSH support with the details (Details on the team\'s banner).',
      'Do not leave and rejoin the team to get past it: the record is what tells a removed member from one who is '
          'still in.',
    ],
    support: 'The details name the entry where the two records part ways, or why the server would not take the '
        'entries back: record-fork (another entry in their place), record-unproven (the server gave no receipt for '
        'them; a receipt key changed, or entries this device appended were never read back), or the rule an entry '
        'broke. A server restored from a backup should be brought back to the last transaction (point-in-time '
        'recovery) where it can, so that nothing is lost in the first place.',
  );

  static const teamPageNotLoaded = ErrorCode(
    'ZS-1405',
    title: 'A team page could not be loaded',
    means: 'A page of a team (its members, its roles, the Overview) could not read what it shows, on this device or '
        'from ZestSSH Cloud; the words before the code say which. Where this device holds the team, the page shows '
        'what it holds and says that it is not up to date. Nothing was changed or deleted, and the team\'s hosts '
        'connect as usual.',
    fix: [
      'Select Retry on the page.',
      'If the message says you are signed out, sign in again, then select Retry.',
      'If it stays, use Copy details on the page and send them to ZestSSH support.',
    ],
    support: 'Copy details names the page and the error the app met. A fault on the device (its team database '
        'could not be read) and an answer of ZestSSH Cloud the app did not expect both show this code; a service that '
        'could not be reached shows its own code (ZS-1101 to ZS-1107) instead.',
  );

  static const teamHostLocalShell = ErrorCode(
    'ZS-1406',
    title: 'A team host cannot open a shell on this device',
    means: 'The host is in a team, and is saved as a local shell: a terminal on the device of whoever opens it. '
        'Anyone who may add or edit hosts in a vault can write such a host, with a command for it to run, so ZestSSH '
        'never opens one from a team. Nothing was started and nothing ran. Other hosts of the team, and the terminal '
        'you open yourself on this device, work as usual.',
    fix: [
      'Ask whoever saved it to give it an address and SSH, or to delete it.',
      'For a terminal on this device, use Local terminal: it is your own, whichever space is on screen.',
    ],
    support: 'New versions refuse such a record when it arrives; one seen here came before that, or from an older '
        'version on another device. The team\'s Activity shows who changed the host. If nobody means to have it, '
        'treat it as an account that may be someone else\'s.',
    since: '3.3',
  );

  static const teamSetAside = ErrorCode(
    'ZS-1407',
    title: 'A team\'s data on this computer was set aside',
    means: 'The key of a team\'s database on this computer could not be read, so the database could not be opened. '
        'Nothing was deleted: the file is set aside for 30 days, and the team is fetched again from ZestSSH Cloud. '
        'Changes made on this computer that never reached ZestSSH Cloud are not in what comes back.',
    fix: [
      'Wait for the team to come back: it does at its next sync, while this computer is online.',
      'If something you changed here is missing, make the change again, or write to support within 30 days to get the '
          'old file back. After 30 days it is deleted.',
    ],
    support: 'The file is in the profile\'s orchards folder, in set_aside, named with its team and the time. A key '
        'reads as unreadable where its entry is gone, or where a database since reset sealed it.',
    since: '3.3',
  );

  static const teamRecordFull = ErrorCode(
    'ZS-1408',
    title: 'A team\'s record is full',
    means: 'The record of who is in the team and what each may do holds all that ZestSSH Cloud keeps for a team of its '
        'seats, so this change to the team was not made. Nothing was lost. Hosts connect and sync goes on as usual, and '
        'what takes someone\'s access away (removing or suspending them, replacing the keys they held) still goes in.',
    fix: [
      'Ask an owner of the team to buy more seats on the Team page, under Seats: each one makes room.',
      'If it is still full after that, contact ZestSSH support, with Copy details where the message has it.',
    ],
    support: 'ZestSSH Cloud\'s answer is 409 record-full. A team keeps 32 MB and 256 KB for each seat of record '
        '(lib/orchard_quota.js), which a team doing what the app does does not reach: ask what has been changing.',
    since: '3.3',
  );

  static const teamRecordEntryTooLarge = ErrorCode(
    'ZS-1409',
    title: 'A change is too large for a team\'s record',
    means: 'One change to the team came to more than the team\'s record takes for one entry, so it was not made. '
        'Nothing was lost, and everything else in the team goes on as usual.',
    fix: [
      'Make the change in smaller steps: fewer vaults or people at once, say.',
      'If it cannot be split, contact ZestSSH support, with Copy details where the message has it.',
    ],
    support: 'ZestSSH Cloud\'s answer is 413 record-entry-too-large: 64 KB for a role or a member, 8 KB for anything '
        'else. Nothing the app writes comes near it, so a version that writes more is worth looking into.',
    since: '3.3',
  );

  static const teamVaultsFull = ErrorCode(
    'ZS-1410',
    title: 'A team\'s vaults are full',
    means: 'The team\'s vaults, with the versions kept of what is in them for 30 days, hold all that ZestSSH Cloud keeps '
        'for a team of its seats, so nothing new is added. What is new waits on this device and nothing is lost. Changes '
        'to what is there go on for a while and deletions always do, and hosts connect as usual.',
    fix: [
      'Ask an owner of the team to buy more seats on the Team page, under Seats: each one makes room.',
      'Deleting what the team no longer needs makes room as its old versions run out.',
      'If it is still full after that, contact ZestSSH support.',
    ],
    support: 'ZestSSH Cloud\'s answer is 409 seats-needed with the reason storage. A team keeps 64 MB for each seat, and '
        '256 MB at the least (lib/orchard_quota.js): about 10000 items for each person, each edited this month.',
    since: '3.3',
  );

  static const teamUnlisted = ErrorCode(
    'ZS-1411',
    title: 'ZestSSH Cloud no longer lists a team for you',
    means: 'ZestSSH Cloud stopped listing a team for your account, as it does for someone taken out of it, but the '
        'team\'s signed record on this device still has you in it, and nothing this device could check says otherwise. '
        'So this device does not take ZestSSH Cloud\'s word for it: everything it has of the team stays, changes not '
        'yet sent included, and its hosts connect as usual. The team does not sync while it is not listed.',
    fix: [
      'If you were taken out of the team, or left it, choose Remove from this device on the team\'s banner.',
      'If you should still be in it, ask an owner or admin of the team whether you are: once ZestSSH Cloud lists the '
          'team again, it syncs by itself.',
      'If an owner says you are still in it and it stays like this, contact ZestSSH support.',
    ],
    support: 'GET /v1/orchards leaves the team out and GET /v1/orchards/:id/record/holds says it holds this device\'s last '
        'record entry (or has no such route), while the record this device holds and checks has the account active, '
        'and the record could not be read now to show a member.remove (ZestSSH Cloud lets no former member read it). '
        'The device keeps the team with the status unlisted and removes it only when its person says so.',
    since: '3.3',
  );

  // ── 15xx: team certificates ───────────────────────────────────────────
  static const teamCertWaiting = ErrorCode(
    'ZS-1501',
    title: 'A team certificate is waiting for an owner',
    means: 'The host is in a team Crate whose hosts take certificates. This device holds none that is still good, '
        'it asked for one, and no owner\'s device has signed the request yet. Certificates are signed by the '
        'owners\' devices and never by ZestSSH Cloud, which only carries the request: it is signed the moment an '
        'owner has ZestSSH open. Nothing is wrong with the host or with the login.',
    fix: [
      'Ask an owner of the team to open ZestSSH on any of their devices, then connect again.',
      'Or get one from an owner directly: choose "Certificate from an owner" where the connection failed, or in '
          'the team\'s Crates under the Crate. Show the code to an owner or send them the text, and enter what '
          'they give back.',
    ],
    support: 'An owner needs nobody: their own device signs their certificate. If an owner sees this, their device '
        'has not got the Crate\'s signing key yet, which comes with a sync.',
  );

  static const teamCertNotAsked = ErrorCode(
    'ZS-1502',
    title: 'No team certificate, and ZestSSH Cloud cannot be asked',
    means: 'The host is in a team Crate whose hosts take certificates. This device holds none that is still good, '
        'and the request for a new one could not be sent because ZestSSH Cloud is not answering (ZS-1101 to '
        'ZS-1107 say which way). The host itself is not affected, and neither are hosts that do not take '
        'certificates.',
    fix: [
      'Get one from an owner directly: choose "Certificate from an owner" where the connection failed, or in the '
          'team\'s Crates under the Crate. Show the code to an owner, or send them the text any way that still works.',
      'The owner chooses "Sign a request" in the same place and gives back a code or a text. Enter it, then '
          'connect again.',
      'Or wait: once ZestSSH Cloud answers again, connecting asks for a certificate as usual.',
    ],
    support: 'A certificate lasts as long as the owners chose for the Crate: an hour, eight hours, a day or a week. '
        'A team that wants to ride out a longer outage without handing certificates over can choose a longer time '
        'in the Crate\'s certificate settings. Owners are never stopped by this: their own device signs theirs.',
  );

  // ── 16xx: files (SFTP and FTPS) ───────────────────────────────────────
  static const sudoWrongPassword = ErrorCode(
    'ZS-1601',
    title: 'sudo did not take the password',
    means: 'A file action the host refused (Permission denied) was tried again as root with sudo, or a file was saved '
        'as root in the editor, and sudo on the host said the password was wrong. Nothing was changed on the host. '
        'ZestSSH never stores the sudo password: it is typed each time.',
    fix: [
      'Type the password again: it is the password of the account you signed in to the host with, not the root '
          'password (unless the host is set up otherwise).',
      'If you sign in with a key and do not know that password, ask whoever looks after the host.',
    ],
    support: 'The password goes to `sudo -k -S -p \'\'` on its standard input, one line, never on the command line. '
        'sudo said "Sorry, try again", "incorrect password" or "authentication failure". A host whose sudo asks for '
        'something besides the password (a one-time code) answers the same way.',
    since: '3.4',
  );

  static const sudoNotAllowed = ErrorCode(
    'ZS-1602',
    title: 'This account may not use sudo on the host',
    means: 'sudo on the host said the account ZestSSH signed in with may not run this as root: it is not in the '
        'sudoers file, or may run only some commands. Nothing was changed on the host. The message shows what sudo '
        'said.',
    fix: [
      'Sign in to the host as an account that may use sudo, or ask whoever looks after the host to allow it.',
      'Or change the file\'s owner or permissions on the host so that your account may do this without sudo.',
    ],
    support: 'Retry with sudo runs mv, cp, rm, mkdir, sh (for a move or a copy that must not replace what is there) '
        'and cat as root; Save as root runs cp. A sudoers rule that allows only some commands refuses the others.',
    since: '3.4',
  );

  static const sudoUnavailable = ErrorCode(
    'ZS-1603',
    title: 'sudo could not be run on the host',
    means: 'To do this as root, ZestSSH runs sudo on the host over SSH. The host has no sudo, or allows SFTP only and '
        'runs no commands. Nothing was changed on the host.',
    fix: [
      'Ask whoever looks after the host to install sudo, or to allow your account a shell.',
      'Or change the file\'s owner or permissions on the host so that your account may do this without sudo.',
    ],
    support: 'Exit status 127 or "sudo: command not found" means no sudo in the PATH of the account\'s shell. A host '
        'set to ForceCommand internal-sftp refuses the exec channel. doas is not used.',
    since: '3.4',
  );

  static const sudoNeedsTerminal = ErrorCode(
    'ZS-1604',
    title: 'sudo on the host runs only from a terminal',
    means: 'sudo on the host is set to run only from a terminal (requiretty), and ZestSSH runs it without one so '
        'that the password never shows on a screen. Nothing was changed on the host.',
    fix: [
      'Open a terminal to the host and run the command there with sudo.',
      'Or ask whoever looks after the host to drop requiretty for your account (Defaults:youraccount !requiretty).',
    ],
    since: '3.4',
  );

  static const sudoNoAnswer = ErrorCode(
    'ZS-1605',
    title: 'The host did not answer the sudo command',
    means: 'ZestSSH ran a command as root with sudo, and nothing came back from the host for two minutes (ten '
        'for a whole folder), so it stopped waiting and ended the command. It may or may not have done its work.',
    fix: [
      'Refresh the folder to see what is there now.',
      'Try again. If it keeps happening, run the command in a terminal to the host to see what sudo asks.',
    ],
    support: 'sudo reads the password with -S and its input is closed after one line, so it cannot wait for a '
        'password. A PAM module that waits for something else (a push to a phone) can.',
    since: '3.4',
  );

  static const ftpsNoTls = ErrorCode(
    'ZS-1606',
    title: 'The FTPS server offers plain FTP only',
    means: 'The host is saved as FTPS, and its server answered no when ZestSSH asked to start TLS (AUTH TLS). ZestSSH '
        'never uses plain FTP, which sends the password and every file readable to anyone on the way, so it stopped '
        'there: nothing was sent after the refusal, not the user name and not the password. Other hosts are not '
        'affected.',
    fix: [
      'Check the port: an FTPS server with implicit TLS listens on 990, and explicit TLS is asked for on 21.',
      'If it is your server, turn TLS on in its settings (vsftpd: ssl_enable=YES; ProFTPD: TLSEngine on; FileZilla '
          'Server: Require explicit FTP over TLS).',
      'If the server can only do SFTP (most Linux servers with SSH can), save the host as SFTP only instead.',
    ],
    support: 'Copy details carries the reply code the server gave to AUTH TLS (often 500, 502 or 534). There is no '
        'setting to allow plain FTP: that is decided (FTP never, FTPS yes).',
    since: '3.4',
  );

  static const ftpsTimedOut = ErrorCode(
    'ZS-1607',
    title: 'The FTPS server did not answer in time',
    means: 'ZestSSH waited for the FTPS server and no answer came. When signing in works but folders never list and '
        'transfers never start, the cause is nearly always the server\'s passive data ports: with TLS, a firewall '
        'cannot read which port the server named, so the range must be open on its own. Nothing was changed on the '
        'server, and other hosts are not affected.',
    fix: [
      'Try again: a busy server or a slow network can cause this once.',
      'If it is your server, set a fixed passive port range (vsftpd: pasv_min_port and pasv_max_port) and open that '
          'range in its firewall and router.',
      'If the server sits behind NAT, it is fine that it names a private address: ZestSSH connects to the address '
          'you saved.',
    ],
    support: 'ZestSSH uses passive mode only (EPSV, or PASV with the control connection\'s own address). Copy details '
        'says which step timed out.',
    since: '3.4',
  );

  // ── 17xx: keys, the vault and the app lock ────────────────────────────
  static const agentPipeNotYours = ErrorCode(
    'ZS-1701',
    title: 'Another account\'s program answers the SSH agent\'s pipe',
    means: 'On Windows, ZestSSH, ssh and git reach the SSH agent through one named pipe, whose name every account of '
        'the computer shares: the first program to take it serves it. The program serving it now is not Windows\' '
        'OpenSSH Authentication Agent and not one of yours: it runs as another account of this computer, or Windows '
        'would not say which. So ZestSSH sent it nothing: no key was given to it, and no sign-in went through it. Keys '
        'in your vault, and hosts that sign in with them, work as usual.',
    fix: [
      'Restart the computer, or ask whoever else is signed in to it to sign out.',
      'Then start the OpenSSH Authentication Agent service, or your password manager\'s agent, before anything else '
          'can take the pipe, and try again.',
      'If it shows again, tell whoever looks after this computer: a program of another account is taking the agent\'s '
          'pipe.',
    ],
    support: 'Before it sends anything, the app asks Windows which account runs the program at the other end of the '
        'openssh-ssh-agent pipe. LocalSystem (Windows\' OpenSSH agent) and the person\'s own account (1Password, '
        'Bitwarden) are used; any other account is refused. Where that program cannot be asked (a service\'s process is '
        'not open to a person\'s), the pipe itself must be owned by SYSTEM, as the OpenSSH agent\'s is. Copy details '
        'says which of the two it was. Get-Service ssh-agent shows whether the real agent runs; an administrator can '
        'see which process holds the pipe with Sysinternals handle.exe or Process Explorer.',
    since: '3.3',
  );

  static const fidoKeyLeft = ErrorCode(
    'ZS-1702',
    title: 'The security key moved away before it was done',
    means: 'On a phone, ZestSSH speaks to a FIDO2 security key itself, over NFC or USB. The key left the phone\'s NFC '
        'field, or was unplugged, before it had signed, and it did so each time it was held to the phone again. Nothing '
        'was sent to the host, and no other way of signing in was tried in the key\'s place. Hosts that sign in with '
        'other keys or passwords work as usual, and so does this key on a computer through the SSH agent.',
    fix: [
      'Hold the security key flat against the phone and keep it still until the sheet closes. On most Android phones the '
          'NFC reader is in the upper half of the back; on an iPhone it is at the top edge.',
      'Take the phone out of a thick case, or a case with metal or a magnet in it.',
      'On an Android phone, plug the security key in instead (USB-C): a plugged-in key cannot move away.',
    ],
    support: 'The NFC exchange (ISO 7816-4 to the FIDO applet) failed with a lost tag five times in one conversation. '
        'A sign-in with a PIN takes several exchanges, so it needs the key held for a second or two. USB security keys '
        'are not supported on iPhone and iPad.',
    since: '4.0',
  );

  static const fidoWrongKey = ErrorCode(
    'ZS-1703',
    title: 'Not the security key this key was made on',
    means: 'A key that lives on a FIDO2 security key can only be used with that one security key. The security key held '
        'to the phone, or plugged in, answered that it has no such key: it is another security key, or the one it was '
        'made on has been reset since. Nothing was sent to the host, and no other way of signing in was tried. '
        'Everything else in ZestSSH works as usual.',
    fix: [
      'Use the security key this key was made on.',
      'If that security key was reset or lost, its keys are gone: make a new key on a security key (Keys, Add, On a '
          'security key) and add its public key to your hosts.',
    ],
    support: 'CTAP2 authenticatorGetAssertion answered CTAP2_ERR_NO_CREDENTIALS for the identity\'s key handle and '
        'application ("ssh:" unless the key was made with another). A key made as a resident key with ssh-keygen -O '
        'resident still needs its key handle here: the app does not list the keys on a security key.',
    since: '4.0',
  );

  static const fidoPinBlocked = ErrorCode(
    'ZS-1704',
    title: 'The security key\'s PIN is blocked',
    means: 'The security key counts wrong PINs itself, and after too many of them (eight on most keys) it blocks its PIN '
        'for good. That has happened to this security key: no app can unblock it. Keys on it that ask for the PIN cannot '
        'be used any more. Keys on it that do not ask for the PIN still work, and so does everything else in ZestSSH.',
    fix: [
      'Reset the security key with its maker\'s app (for a YubiKey: Yubico Authenticator, on a computer). A reset erases '
          'every key and passkey on it.',
      'After the reset, set a new PIN, make a new key on it (Keys, Add, On a security key) and add its public key to '
          'your hosts.',
    ],
    support: 'CTAP2 clientPIN answered CTAP2_ERR_PIN_BLOCKED. Not the same as three wrong PINs in a row '
        '(CTAP2_ERR_PIN_AUTH_BLOCKED), which the app says in words and which ends when the key is taken away and '
        'presented again. The app never retries a PIN by itself and does not keep one.',
    since: '4.0',
  );

  static const fidoAnswerNotTrusted = ErrorCode(
    'ZS-1705',
    title: 'The security key\'s answer was not trusted',
    means: 'Before ZestSSH sends a security key\'s signature to a host it checks it: that it is for this key and for '
        'what was to be signed, that the security key waited for the touch or the PIN this key asks for, and that it '
        'holds nothing more. This answer failed that check, or was not in a form the protocol allows. Nothing was sent '
        'to the host, and no other way of signing in was tried. Your hosts, keys and other sign-ins are not affected.',
    fix: [
      'Try again, holding the security key still or leaving it plugged in.',
      'Check that it is the security key this key was made on, and that the key was not replaced in ZestSSH since.',
      'If it keeps happening with one security key and not with another, choose Copy details and send them to support.',
    ],
    support: 'The assertion was refused locally: the authenticator data\'s application hash, flags (user presence, '
        'user verification, no extensions) or the signature did not check against the identity\'s public key, or the '
        'CTAP2 answer was not well-formed CBOR of the expected shape. Copy details names which.',
    since: '4.0',
  );

  static const fidoNoWay = ErrorCode(
    'ZS-1706',
    title: 'This device cannot talk to a security key',
    means: 'On a phone, ZestSSH speaks to a FIDO2 security key over NFC (Android and iPhone) or USB-C (Android). This '
        'device has neither way: it has no NFC, or it is an iPad or an iPhone asked for a USB security key, which are not '
        'supported yet. Keys that live in the app, passwords and everything else work as usual.',
    fix: [
      'On an iPhone, use a security key with NFC and hold it near the top of the phone.',
      'On an Android phone without NFC, plug the security key in (USB-C).',
      'Or sign in to this host with a key kept in the app, or from a computer, where a security key works through the '
          'SSH agent.',
    ],
    support: 'The platform reported no NFC reader that can reach an ISO 7816 tag and no USB host for a FIDO HID '
        'interface. iPadOS has no NFC reader for apps; iOS gives apps no raw channel to a USB security key. On an '
        'iPhone the app also needs the NFC Tag Reading capability in its build.',
    since: '4.0',
  );

  // ── 18xx: remote screens (VNC) ────────────────────────────────────────
  static const screenNothingAnswers = ErrorCode(
    'ZS-1801',
    title: 'Nothing answers at the remote screen\'s address',
    means: 'ZestSSH signed in to the SSH host this screen is reached through and asked it to connect to the screen\'s '
        'address and port (localhost:5900 by default for VNC, 3389 for RDP). The SSH host tried, and nothing listens '
        'there: the VNC or RDP server is not running, listens on another port or display, or listens on another '
        'address. Nothing was sent to a server there, and the SSH host was not changed.',
    fix: [
      'Start the VNC server on that machine (TigerVNC: vncserver :0, or the vncserver@ systemd unit; x11vnc; wayvnc).',
      'For an RDP host: turn Remote Desktop on at the PC (Windows: Settings, System, Remote Desktop), or start xrdp.',
      'Check its port: display :0 is 5900, display :1 is 5901, and so on; RDP is 3389 unless it was changed. Change '
          'the port in the screen\'s settings to match.',
      'If the server listens only on one address, put that address in the screen\'s settings, as the SSH host sees it.',
    ],
    support: 'The SSH host refused the direct-tcpip channel with "connect failed" (SSH channel open failure 2). On the '
        'SSH host, ss -ltnp shows what listens on which port.',
    since: '4.0',
  );

  static const screenForwardingRefused = ErrorCode(
    'ZS-1802',
    title: 'The SSH host does not allow a remote screen through it',
    means: 'A remote screen reaches its VNC server through an SSH host, the way ssh -L does, and that SSH host\'s server '
        'refuses to carry such connections. Signing in to it worked; terminals and files on it are not affected.',
    fix: [
      'On the SSH host, allow forwarding in /etc/ssh/sshd_config: AllowTcpForwarding yes (or local) for an address and '
          'port, AllowStreamLocalForwarding yes (or local) for a Unix socket, then reload sshd.',
      'Check that no Match block, and no restrict or no-port-forwarding in authorized_keys, turns it off for your '
          'account or key.',
      'If you cannot change the server, ask whoever runs it.',
    ],
    support: 'The SSH host refused the direct-tcpip or direct-streamlocal@openssh.com channel as administratively '
        'prohibited (SSH channel open failure 1), or does not know the channel type (3). sshd -T | grep -i forwarding '
        'shows the settings in force.',
    since: '4.0',
  );

  static const screenPasswordRefused = ErrorCode(
    'ZS-1803',
    title: 'The VNC server refused the password',
    means: 'The VNC server was reached and asked for its password, and did not take the one given. ZestSSH does not '
        'try again by itself, so the server does not lock you out.',
    fix: [
      'Check the password in the key this screen uses, or type it again when asked.',
      'VNC passwords use at most 8 characters: anything longer is ignored by the server, so type only the first 8.',
      'On the server, vncpasswd sets a new password for TigerVNC and TightVNC.',
    ],
    support: 'The security type and the server\'s reason, where it gave one, are in Copy details. The password itself '
        'is never written there.',
    since: '4.0',
  );

  static const screenNoSecurity = ErrorCode(
    'ZS-1804',
    title: 'The VNC server offers no security this app accepts',
    means: 'The VNC server answered, and none of the ways it offers to secure the connection is one ZestSSH uses. A '
        'screen reached directly, without an SSH host, needs VeNCrypt with a certificate (X509Vnc, X509Plain or '
        'X509None), since anything else would send the picture and your keys unprotected over the network. Anonymous '
        'TLS and RA2 are not accepted. Apple\'s own sign-in (Apple Remote Desktop) is not used either, since it hands '
        'the server your account\'s user name and password: a Mac offering only that is said here too.',
    fix: [
      'Reach the screen through an SSH host instead: plain VNC is then carried inside SSH.',
      'Or turn on VeNCrypt with a certificate on the server (TigerVNC: -SecurityTypes X509Vnc with -X509Cert and '
          '-X509Key).',
      'On a Mac, turn on "VNC viewers may control screen with password" in Screen Sharing\'s settings, and use '
          'that password.',
    ],
    support: 'Copy details lists the security types the server offered, or says the server offered only Apple Remote '
        'Desktop (RFB security type 30).',
    since: '4.0',
  );

  static const screenCertificateChanged = ErrorCode(
    'ZS-1805',
    title: 'The remote screen\'s certificate changed',
    means: 'The VNC server showed a TLS certificate other than the one trusted for it before. That happens when the '
        'server got a new certificate, and also when something else answers in its place. Nothing was sent: no '
        'password and no keys.',
    fix: [
      'Ask whoever runs the server whether its certificate was renewed, and compare the fingerprint: openssl x509 -in '
          '<certificate file> -noout -fingerprint -sha256 (TigerVNC\'s -X509Cert file).',
      'If it matches, connect again and accept the new certificate when asked.',
      'If it does not match, do not connect: tell whoever runs the network.',
    ],
    support: 'Copy details has the SHA-256 the server showed. Certificates trusted for screens are in Settings, '
        'Security, Known hosts, as TLS certificate (VNC).',
    since: '4.0',
  );

  static const screenSocketMissing = ErrorCode(
    'ZS-1806',
    title: 'The remote screen\'s socket is not there',
    means: 'This screen is reached through a Unix socket on its SSH host, and the SSH host found nothing at that path: '
        'the VNC server is not running, or uses another path. The SSH host was not changed.',
    fix: [
      'Start the VNC server with that socket (TigerVNC: -rfbunixpath ~/.vnc/zest.sock -rfbunixmode 0600; x11vnc: '
          '-unixsock).',
      'Check the path in the screen\'s settings. A path starting with ~/ is in the home folder of the account the SSH '
          'host signs in as.',
    ],
    support: 'The SSH host refused the direct-streamlocal@openssh.com channel with "connect failed" (SSH channel open '
        'failure 2). On the SSH host, ls -l shows whether the socket exists and who may open it.',
    since: '4.0',
  );

  static const screenWatched = ErrorCode(
    'ZS-1807',
    title: 'Screens cannot be opened in a watched vault yet',
    means: 'The screen, or the SSH host it is reached through, is in a team vault whose sessions are watched by '
        'someone who manages it. A watched session is a terminal they follow live, and a remote screen cannot be '
        'followed yet, so it is not opened. Nothing was dialled.',
    fix: [
      'Open the host\'s terminal instead, which is watched as usual.',
      'Or ask whoever manages the vault to put the screen in a vault whose sessions are not watched.',
    ],
    since: '4.0',
  );

  static const screenCarrierGone = ErrorCode(
    'ZS-1808',
    title: 'The SSH host this remote screen is reached through is gone',
    means: 'This screen is reached through one of your SSH hosts, and that host is no longer here: it was deleted, '
        'moved to another space, or is no SSH host any more. The screen\'s address is as that SSH host saw it '
        '(often localhost), so ZestSSH does not dial it directly from this device instead. Nothing was dialled and '
        'nothing was sent.',
    fix: [
      'Open the screen\'s settings and choose the SSH host it is reached through again, under Reach through.',
      'If the SSH host was moved to another space, move the screen there too, or pick another SSH host here.',
      'To reach the screen without an SSH host, choose Directly on purpose: then only VeNCrypt with a certificate is '
          'taken.',
    ],
    support: 'Copy details names the id of the SSH host the screen still points at. In a team, someone who may edit '
        'the screen\'s vault can pick its SSH host again for everyone.',
    since: '4.0',
  );

  static const screenRdpSignInRefused = ErrorCode(
    'ZS-1812',
    title: 'The RDP server refused the sign-in',
    means: 'The server was reached, its certificate was the one you accepted, and it did not take the user name and '
        'password. With Network Level Authentication the server says only that the sign-in failed, not why: a wrong '
        'password, a wrong user name or domain, and an account that is locked, disabled or may not sign in remotely '
        'all look the same from here. ZestSSH asks again at most three times, so an account is not locked by it.',
    fix: [
      'Check the user name and the password in the key this host uses, or type the password again when asked.',
      'For a domain account, write the user name as DOMAIN\\user or user@domain; for an account of the PC itself, '
          'the name alone.',
      'On the PC, check that the account may sign in over Remote Desktop (Settings, System, Remote Desktop, or the '
          'Remote Desktop Users group) and that it has a password: Windows refuses accounts with an empty one.',
      'A Microsoft account signs in with its email address as the user name; a PC that was only ever signed in to '
          'with a PIN or Windows Hello may need one sign-in with the password at the PC first.',
    ],
    support: 'Copy details says that the sign-in was refused and whether Network Level Authentication was used. The '
        'password is never written there, and neither are the values NTLM makes from it.',
    since: '4.0',
  );

  static const screenRdpNlaMissing = ErrorCode(
    'ZS-1813',
    title: 'The RDP server has no Network Level Authentication',
    means: 'ZestSSH signs in to an RDP host with Network Level Authentication (NLA) unless the host says otherwise: '
        'the password is then never sent, both sides prove they know it, and the sign-in belongs to the '
        'certificate you accepted. This server answered that it has TLS only and no NLA, as xrdp does. ZestSSH did '
        'not go on without it by itself, and no user name or password was sent.',
    fix: [
      'If this is a server that has no NLA, such as xrdp, open the host and turn on "Sign in without NLA". The '
          'server then shows its own sign-in screen, and you type the password into the remote picture.',
      'If this is a Windows PC, NLA should be there: check that Remote Desktop is on and that nothing between you '
          'and the PC answers in its place.',
    ],
    support: 'Copy details has the server\'s own answer to the connection request (it required TLS where only NLA '
        'was asked for).',
    since: '4.0',
  );

  static const screenRdpNlaRequired = ErrorCode(
    'ZS-1814',
    title: 'The RDP server requires Network Level Authentication',
    means: 'This host is set to sign in without Network Level Authentication (NLA), and the server answered that it '
        'signs people in with NLA only, as Windows does by default. Nothing was sent to it but the connection '
        'request.',
    fix: [
      'Open the host and turn off "Sign in without NLA". ZestSSH then signs in with the user name and password of '
          'the host\'s key before the server shows anything.',
    ],
    support: 'Copy details has the server\'s own answer to the connection request (it required NLA where only TLS was '
        'asked for).',
    since: '4.0',
  );

  static const screenRdpAccountLocked = ErrorCode(
    'ZS-1815',
    title: 'The account is locked on the RDP server',
    means: 'The server answered the sign-in with "account locked out": too many wrong passwords were tried for this '
        'account, from this app or from anywhere else, and the server refuses it for a while whatever password comes '
        'now. ZestSSH asks for a password at most three times for one connection, so that it does not cause this by '
        'itself.',
    fix: [
      'Wait: most servers unlock an account by themselves after some minutes.',
      'Whoever manages the server can unlock it at once (Local Users and Groups on the PC, or Active Directory Users '
          'and Computers for a domain account).',
      'If you did not type wrong passwords, someone or something else did: tell whoever manages the server.',
    ],
    support: 'Copy details has the status the server gave (STATUS_ACCOUNT_LOCKED_OUT). The password is never written '
        'there.',
    since: '4.0',
  );

  static const screenRdpAccountDisabled = ErrorCode(
    'ZS-1816',
    title: 'The account is turned off on the RDP server',
    means: 'The server answered the sign-in with "account disabled". It knows the user name and the account has been '
        'turned off there; no password will do until it is turned on again.',
    fix: [
      'Check the user name in the key this host uses: a similar name of an old account may be the one that is '
          'turned off.',
      'Whoever manages the server can turn the account on again.',
    ],
    support: 'Copy details has the status the server gave (STATUS_ACCOUNT_DISABLED).',
    since: '4.0',
  );

  static const screenRdpPasswordExpired = ErrorCode(
    'ZS-1817',
    title: 'The password of the account has expired',
    means: 'The server answered the sign-in with "password expired" or "password must change": it wants a new '
        'password before it lets the account in. ZestSSH cannot change a Windows password from here.',
    fix: [
      'Change the password at the PC itself, or from another computer of the same domain (Ctrl+Alt+Del, then Change '
          'a password).',
      'Or ask whoever manages the server to set a new one.',
      'Then put the new password into the key this host uses, or type it when asked.',
    ],
    support: 'Copy details has the status the server gave (STATUS_PASSWORD_EXPIRED or STATUS_PASSWORD_MUST_CHANGE).',
    since: '4.0',
  );

  static const screenRdpAccountNotAllowed = ErrorCode(
    'ZS-1818',
    title: 'The account may not sign in over Remote Desktop',
    means: 'The server knows the account and did not find its password wrong, and still refuses it for this kind of '
        'sign-in. On Windows that is one of: the account is not among those allowed to sign in over Remote Desktop, '
        'it has no password (Windows refuses those over the network), or it is outside the hours or the computers it '
        'is limited to.',
    fix: [
      'On the PC: Settings, System, Remote Desktop, Remote Desktop users, and add the account. An administrator of '
          'the PC is allowed without being added.',
      'Give the account a password if it has none.',
      'For a work account, ask whoever manages the server: sign-in hours and the computers an account may use are '
          'set there.',
    ],
    support: 'Copy details has what the server gave: a status at sign-in (STATUS_ACCOUNT_RESTRICTION, '
        'STATUS_INVALID_LOGON_HOURS, STATUS_INVALID_WORKSTATION, STATUS_LOGON_TYPE_NOT_GRANTED) or its reason for '
        'ending the session (insufficient access privileges).',
    since: '4.0',
  );

  static const screenRdpTakenOver = ErrorCode(
    'ZS-1819',
    title: 'The remote session was taken over',
    means: 'A Windows PC lets one person use an account\'s session at a time. Someone signed in with the same '
        'account, from another device or at the PC\'s own screen and keyboard, and Windows moved the session there '
        'and ended this connection. ZestSSH does not connect again by itself: the two would keep taking the session '
        'from each other.',
    fix: [
      'If that was you somewhere else, nothing is wrong: use Reconnect here when you want the session back.',
      'If it was not you, someone else knows this account\'s password: change it.',
    ],
    support: 'Copy details has the server\'s reason (another user connected to the server, forcing the disconnection '
        'of the current connection).',
    since: '4.0',
  );

  static const screenRdpLicence = ErrorCode(
    'ZS-1820',
    title: 'Remote Desktop licensing refused the session',
    means: 'The server could not give this connection a Remote Desktop licence: it found no licence server, its '
        'licences are used up, or the time it runs without them is over. This is decided on the server; nothing in '
        'ZestSSH changes it.',
    fix: [
      'Whoever manages the server has to look at its Remote Desktop licensing (on a Windows Server: RD Licensing '
          'Diagnoser).',
    ],
    support: 'Copy details has the server\'s own licensing reason.',
    since: '4.0',
  );

  static const screenTeamSshOnly = ErrorCode(
    'ZS-1821',
    title: 'The team opens remote screens through an SSH host only',
    means: 'The team this remote screen belongs to has the rule "Remote screens through SSH only", and this screen is '
        'set to connect directly. Nothing was dialled. The rule is set by the team\'s owners in the team\'s rules; '
        'the screen\'s other settings, its key and its certificate are as they were.',
    fix: [
      'Open the screen\'s settings and choose an SSH host under "Reach through". The screen\'s address is then the '
          'one that SSH host uses to reach it (often localhost).',
      'No SSH host can reach it: ask an owner of the team, who can add one to the team or turn the rule off.',
    ],
    support: 'Copy details names the rule and no address.',
    since: '4.0',
  );

  static const screenGatewaySignIn = ErrorCode(
    'ZS-1822',
    title: 'The RD Gateway refused the sign-in',
    means: 'This RDP host is reached through a Remote Desktop Gateway, and the gateway did not take the account it '
        'was given: the PC\'s own account where the host says "the same as the PC\'s", or the key chosen for the '
        'gateway. Nothing reached the PC.',
    fix: [
      'Check the gateway\'s sign-in in the host\'s settings, under "Reach through": its key, or the PC\'s key when it '
          'signs in the same.',
      'A domain account is written DOMAIN\\name or name@domain.',
      'Whoever manages the gateway can tell whether the account is locked or its password has run out.',
    ],
    support: 'Copy details has what the gateway said, without the account\'s password.',
    since: '4.0',
  );

  static const screenGatewayNotAllowed = ErrorCode(
    'ZS-1823',
    title: 'The RD Gateway does not let this account through to this PC',
    means: 'The gateway signed the account in, and its own policies refused the connection: who may connect through '
        'it (its connection authorization policy) or to which computers (its resource authorization policy). These '
        'are set on the gateway; nothing in ZestSSH changes them.',
    fix: [
      'Check that the PC\'s address in the host\'s settings is the name the gateway knows it by (the gateway may '
          'allow a computer by its name and not by its address).',
      'Whoever manages the gateway can add the account, or the PC, to its policies.',
    ],
    support: 'Copy details has the gateway\'s code (for example 0x800759da, E_PROXY_RAP_ACCESSDENIED).',
    since: '4.0',
  );

  static const screenGatewayTarget = ErrorCode(
    'ZS-1824',
    title: 'The RD Gateway could not reach the PC',
    means: 'The gateway signed the account in and was allowed through, and could not connect to the PC: its name does '
        'not resolve where the gateway is, the PC is off, or nothing listens on its Remote Desktop port.',
    fix: [
      'Check the PC\'s address and port in the host\'s settings, as the gateway sees the PC (often its name in the '
          'company\'s network, not an address reachable from here).',
      'Check that the PC is on and allows Remote Desktop connections.',
    ],
    support: 'Copy details has the gateway\'s code (E_PROXY_TS_CONNECTFAILED).',
    since: '4.0',
  );

  static const screenGatewayUnsupported = ErrorCode(
    'ZS-1825',
    title: 'The RD Gateway asks for something this version does not do',
    means: 'ZestSSH signs in to a gateway with NTLM (a user name and password) over its WebSocket transport. This '
        'gateway asked for something else: another way to sign in (a smart card, Basic, its own cookie), a message to '
        'show and agree to before connecting, its older transport of two HTTP connections, or to sign in again during '
        'the session.',
    fix: [
      'Copy details says which. Whoever manages the gateway may allow NTLM (password) sign-in, or turn off the '
          'message that needs agreeing to.',
      'Where an SSH host can reach the PC, "Reach through" that SSH host does what the gateway is for.',
    ],
    support: 'Copy details names what the gateway asked for.',
    since: '4.0',
  );

  static const screenGatewayRefused = ErrorCode(
    'ZS-1826',
    title: 'The RD Gateway refused the connection',
    means: 'The gateway refused for a reason of its own (its code is in Copy details), or the address is not an RD '
        'Gateway (it answered as a web server without one, or sent the connection elsewhere, which is not followed).',
    fix: [
      'Check the gateway\'s address and port in the host\'s settings (a gateway usually listens on 443).',
      'Whoever manages the gateway can look its code up in the gateway\'s own log.',
    ],
    support: 'Copy details has the gateway\'s code or HTTP status.',
    since: '4.0',
  );

  static const screenGatewayUnavailable = ErrorCode(
    'ZS-1827',
    title: 'This host goes through an RD Gateway this version does not open',
    means: 'The host\'s settings say to reach it through a Remote Desktop Gateway, and this version of ZestSSH cannot: '
        'its gateways are not turned on yet, the settings came from a newer version in a form this one cannot read, '
        'or the host is also set to go through an SSH host. It was not connected to without the gateway.',
    fix: [
      'Update ZestSSH on this device.',
      'Or, where an SSH host can reach the PC, choose that SSH host under "Reach through" instead.',
    ],
    support: 'Copy details says which of the three it was.',
    since: '4.0',
  );

  static const xProgramToolsMissing = ErrorCode(
    'ZS-1809',
    title: 'The SSH host has no Xvnc or no xauth for an X program',
    means: 'Open an X program runs the program on the SSH host in a private X server there, TigerVNC\'s Xvnc, with a '
        'cookie made by xauth, and shows it in a screen tab. One of the two is not installed on the host, so nothing '
        'was started. ZestSSH never installs anything on a host itself.',
    fix: [
      'Install both on the host, then open the program again. Debian and Ubuntu: sudo apt install '
          'tigervnc-standalone-server xauth. Fedora, RHEL, Rocky and Alma: sudo dnf install tigervnc-server-minimal '
          'xorg-x11-xauth. Arch: sudo pacman -S tigervnc xorg-xauth. openSUSE: sudo zypper install xorg-x11-Xvnc '
          'xauth.',
      'If you cannot install software there, ask whoever runs the host.',
    ],
    support: 'The host script found no Xvnc or no xauth on the PATH of a non-interactive sign-in (command -v), and '
        'named the package manager it found (apt-get, dnf, yum, pacman or zypper), which picks the command shown. '
        'Copy details says which tool was missing.',
    since: '4.0',
  );

  static const xProgramFailed = ErrorCode(
    'ZS-1810',
    title: 'The private X server for an X program did not start',
    means: 'ZestSSH signed in to the SSH host and ran its small script there to start a private X server (Xvnc) for '
        'the program, and it did not start: the script found no temporary folder it could write, Xvnc stopped as it '
        'started, or no answer came within 20 seconds. The host must be Linux or another Unix whose sign-in runs '
        'commands with sh. Nothing was left on the host.',
    fix: [
      'Try again: a host that was busy may answer next time.',
      'Check that /tmp (or the folder in TMPDIR) exists and is writable for your account on the host.',
      'Run Xvnc -version on the host in a terminal: it should print TigerVNC\'s version.',
      'A host whose SSH sign-in runs only a fixed command, or Windows\' OpenSSH server, cannot run X programs.',
    ],
    support: 'Copy details has what the script said (no-tmp, xvnc-exited with the last lines of Xvnc\'s own log, '
        'xvnc-timeout, xauth, no-random) or the last lines the host printed. The script runs as exec sh -c with '
        'its text as an octal printf format, so any login shell passes it on unchanged.',
    since: '4.0',
  );

  static const xProgramEnded = ErrorCode(
    'ZS-1811',
    title: 'The X program ended as it started',
    means: 'The private X server started on the SSH host and the program ended within a moment, so there was no '
        'window to show. Exit status 127 means the host has no program by that name; others are the program\'s own. '
        'Some programs hand their window to a copy already running and end at once. Nothing was left on the host.',
    fix: [
      'Check the program\'s name and arguments: they are run as typed in a terminal on that host.',
      'Install the program on the host if it is not there.',
      'For a program that hands its window to a copy already running, ask for a new one (firefox --new-instance, '
          'gnome-terminal --wait).',
    ],
    support: 'Copy details has the exit status and the last lines the program printed (its output goes to the SSH '
        'channel\'s error stream, never into a file on the host).',
    since: '4.0',
  );

  // ── 19xx: the app itself ──────────────────────────────────────────────
  static final updateDownloadFailed = ErrorCode(
    'ZS-1901',
    title: 'The update could not be downloaded',
    means: 'ZestSSH started downloading its new version from zestssh.com and the download did not finish: the '
        'network dropped, the site did not answer, or the disk had no room. Nothing was installed and nothing was '
        'closed: the app and every session go on as they were.',
    fix: [
      'Check that this computer is online, then choose Update and restart again.',
      'Or download the new version from zestssh.com/download and install it as usual.',
    ],
    support: 'The download goes to the system\'s temporary folder, from https://$kZestUpdateHost/downloads/ only, and '
        'follows no redirect to another site. The request carries nothing about the device. Copy details names '
        'what failed (the status the site gave, or the network\'s error).',
  );

  static final updateNotSigned = ErrorCode(
    'ZS-1902',
    title: 'The update information is not signed by ZestSSH',
    means: 'The list of the latest release on zestssh.com named a new version, but its signature was missing or '
        'did not match the release key built into the app. Something between this computer and the site may have '
        'changed it, or the release was published unsigned. ZestSSH offers nothing from it and downloads nothing.',
    fix: [
      'Try again later: a release published unsigned by mistake is signed again quickly.',
      'If it keeps showing, download the new version from zestssh.com/download in your browser, check its '
          'SHA-256 against the one listed there, and tell support.',
    ],
    support: 'The manifest (https://$kZestUpdateHost/app/latest.json) carries an Ed25519 signature over its canonical '
        'JSON, made with the release key by the website\'s release script. A manifest that names no newer version '
        'is never refused, signed or not. Ask whether the person is behind a proxy or filter that rewrites pages.',
  );

  static const updateFileMismatch = ErrorCode(
    'ZS-1903',
    title: 'The downloaded update is not the released file',
    means: 'The file ZestSSH downloaded for its new version is not the size, or does not have the SHA-256, that the '
        'signed release information names. It may have been cut short or changed on the way. It was deleted '
        'without being opened; nothing was installed and nothing was closed.',
    fix: [
      'Choose Update and restart again: a download cut short is fetched again whole.',
      'If it keeps showing, download the new version from zestssh.com/download and check its SHA-256 against the '
          'one listed there.',
    ],
    support: 'Copy details gives the size and SHA-256 expected and found. A repeated mismatch on one network, and '
        'none on another, points at something on that network that changes downloads.',
  );

  static const updateCannotInstallHere = ErrorCode(
    'ZS-1904',
    title: 'This copy of ZestSSH cannot update itself',
    means: 'ZestSSH installs its own updates only where it can replace itself: on Windows a copy installed with the '
        'ZestSSH setup, on Linux the folder unpacked from the download, on a Mac the app in a folder this account '
        'can write to. This copy is somewhere else (a folder that needs an administrator, a system package, a disk '
        'image, or a store\'s copy). Nothing was changed.',
    fix: [
      'Download the new version from zestssh.com/download and install it as you installed this one.',
      'On a Mac, move ZestSSH into Applications (or another folder you can write to) and open it from there; then '
          'it updates itself.',
    ],
    support: 'Copy details names the reason and the folder (with the account name taken out). A Linux copy from a '
        'distribution\'s package, a Flatpak or a Snap is updated by that system.',
  );

  static const updateInstallFailed = ErrorCode(
    'ZS-1905',
    title: 'The update could not be installed',
    means: 'The new version was downloaded and checked, but installing it did not finish: the installer could not '
        'start, unpacking it failed, or ZestSSH opened again still on the old version. Your hosts, keys and '
        'settings are not touched by an update and are as they were.',
    fix: [
      'Choose Update and restart again.',
      'Or download the new version from zestssh.com/download and install it as usual.',
      'If it fails again, choose Copy details and send it to support: it holds the installer\'s own log.',
    ],
    support: 'On Windows the installer runs silently (/VERYSILENT) and writes its log to the temporary folder; Copy '
        'details carries its last lines. On Linux and macOS a small helper swaps the new folder or app in after '
        'the app quits and logs to the temporary folder; where the swap fails it puts the old version back and '
        'opens it.',
  );

  static const localSaveFailed = ErrorCode(
    'ZS-1906',
    title: 'A change could not be saved on this device',
    means: 'ZestSSH could not write a change to its database on this device: the disk may be full, or the database '
        'may be closed or in use for a moment. Nothing was changed, what you typed is still on the screen, and '
        'everything saved before is as it was.',
    fix: [
      'Choose Save again.',
      'If it fails again, check that the disk has room, then restart ZestSSH and make the change again.',
      'If it keeps failing, choose Copy details and send it to support.',
    ],
    support: 'Copy details carries what the database answered. A full disk or a database locked by another copy of '
        'the app are the usual causes.',
    since: '3.3',
  );

  static final ticketRefused = ErrorCode(
    'ZS-1907',
    title: 'The server did not accept a ticket',
    means: 'ZestSSH sent your ticket and the server refused it for good, so it is not tried again by itself. '
        'Nothing is lost: what you wrote is still on this device, under the ticket.',
    fix: [
      'Choose Retry to send it once more.',
      'If it is refused again, choose Copy and email the text to $kZestSupportAddress.',
    ],
    support: 'Shown for an answer in the 4xx range other than 401, 403 and 429 to POST /v1/tickets, usually a subject '
        'or a message over the limits. Copy details carries the code and no text of the ticket.',
    since: '3.3',
  );

  static final ticketBlocked = ErrorCode(
    'ZS-1908',
    title: 'This account cannot open tickets',
    means: 'The server refused the ticket because the account signed in on this device may not open tickets. What '
        'you wrote is still on this device.',
    fix: [
      'If you think that is wrong, email $kZestSupportAddress. Choose Copy to take the text with you.',
    ],
    support: 'An answer of 403 to POST /v1/tickets: the account is on the feedback block list.',
    since: '3.3',
  );

  static const ticketNeedsAccount = ErrorCode(
    'ZS-1909',
    title: 'A ticket was to include your account, and you are signed out',
    means: 'You ticked Include my account on a ticket that had to wait for the network. When it was sent, no account '
        'was signed in on this device, so the server refused it. What you wrote is still on this device.',
    fix: [
      'Sign in and choose Retry.',
      'Or choose Send without my account. The ticket is then tied to no account.',
    ],
    support: 'An answer of 401 to POST /v1/tickets with include_account set.',
    since: '3.3',
  );

  static const profileMoveStopped = ErrorCode(
    'ZS-1910',
    title: 'Moving your data to its new place stopped',
    means: 'On a computer this version keeps each account\'s data in a place of its own, and moves what is here at its '
        'first start. That move stopped before it was finished. Nothing is lost: the originals stay until the move is '
        'done, and the next start goes on from where it stopped.',
    fix: [
      'Choose Retry: the move goes on from where it stopped.',
      'If it stops again, close what may hold the files (a backup tool, a virus scanner), check that the disk has room, '
          'and choose Retry.',
      'If it keeps showing, choose Copy details and send it to support. Do not delete or move anything in the app\'s '
          'folder.',
    ],
    support: 'The marker is profiles/move_v1.json in the app\'s data folder, and names the last step finished. A copy of '
        'the database with its write-ahead file, and of the keychain\'s file on Windows, is kept in the profile\'s pre_move '
        'folder for 30 days. An older version run in between is no harm: what it made stays where it is, and is offered '
        'as data from an older version. It can also be set aside, deleting nothing (ZS-1912).',
    since: '3.3',
  );

  static const keychainFile = ErrorCode(
    'ZS-1911',
    title: 'ZestSSH could not use its keychain file',
    means: 'On Windows the secrets ZestSSH keeps on this computer are in one encrypted file. Something holds it for '
        'longer than ZestSSH waits, or it is read-only, or the disk refused, or it does not decrypt at the moment. '
        'What was being written was not kept, and what is in the file stays as it was.',
    fix: [
      'If you just changed your Windows password or just signed in to Windows, wait a minute and try again.',
      'Close what may hold the file (a backup tool, a virus scanner), then try again.',
      'Check that flutter_secure_storage.dat in the app\'s data folder is not read-only, and that the disk has room.',
      'If it never opens, set it aside and start fresh: nothing is deleted. What you synced comes back with sync.',
      'If it keeps showing, choose Copy details and send it to support.',
    ],
    support: 'A file that does not decrypt while flutter_secure_storage.dat.good does is renamed '
        'flutter_secure_storage.dat.broken.<time>, the newest 3 are kept, and the copy takes its place. Where neither '
        'decrypts nothing is touched, as DPAPI may answer again; set aside, they become .aside.<time>.<n> beside the new '
        'file. To go back to one: close the app, rename the new file away, and rename the old one to '
        'flutter_secure_storage.dat. Another Windows login, or a restore of the Windows profile, may yet open it.',
    since: '3.3',
  );

  static const profileSetAside = ErrorCode(
    'ZS-1912',
    title: 'Earlier data on this computer was set aside',
    means: 'Data here did not open, and you chose to set it aside and start fresh. It was moved to a folder of its own '
        'on this computer, with its keys, and nothing was deleted. ZestSSH does not use it. What you synced comes back '
        'with sync.',
    fix: [
      'To try it again, choose Put it back on the notice. ZestSSH closes, and it is there when you open ZestSSH again. '
          'What stands in its place is set aside in turn.',
      'If it does not open again, set it aside again and write to support with this code.',
      'If you do not need it, choose Delete it on the notice.',
    ],
    support: 'The folder is profiles/set_aside/<id>.<time> in the app\'s data folder, with the move\'s marker in it if a '
        'move was under way. Its entries stay in the keychain under p.<id>., and a move set aside midway keeps the old '
        'names and settings until it is put back or deleted. Put it back asks for it in profiles/put_back_v1, and the next '
        'start moves the folder and the marker back, sets the state in the list to open and opens it.',
    since: '3.3',
  );

  static const macKeychainDenied = ErrorCode(
    'ZS-1913',
    title: 'macOS did not let ZestSSH read its saved keys',
    means: 'On a Mac, ZestSSH keeps your keys, passwords and its database\'s key in your login keychain. macOS asked '
        'whether ZestSSH may use them ("ZestSSH wants to use your confidential information stored in '
        'flutter_secure_storage_service in your keychain"), and the answer was not yes: Deny was chosen, the question was '
        'closed, the password was not taken, or macOS could not ask (the Mac was locked). Nothing was deleted, and no new '
        'key was made. ZestSSH does not ask again by itself: sync and other background work wait until you choose Try '
        'again.',
    fix: [
      'Choose Try again. When macOS asks, choose Always Allow and type your Mac login password.',
      'macOS asks once for each saved key, so it may ask several times in a row: choose Always Allow each time. Allow on '
          'its own lets ZestSSH read the key only once, and macOS asks again.',
      'After each update of ZestSSH this happens again, once for each saved key, until the Mac app is signed by Apple.',
      'Never delete the flutter_secure_storage_service items in Keychain Access: they are your saved keys and '
          'passwords, and the data on this Mac cannot be opened without them.',
    ],
    support: 'The Mac app is signed ad-hoc, so each build is a new app to macOS, and its items are in the legacy login '
        'keychain under the service flutter_secure_storage_service. The status macOS answered is in Copy details: -128 '
        '(the question was denied or closed), -25293 (the password was not taken), -25308 (macOS could not ask) or -34018 '
        '(the build may not use that keychain). An item macOS said no to is not asked about again in the same run until '
        'Try again. Keychain Access, the item, Access Control, adding ZestSSH under Always allow access, does what Always '
        'Allow does.',
    since: '3.3.2',
  );

  static const macSignInNotRead = ErrorCode(
    'ZS-1914',
    title: 'You are not signed in on this Mac right now',
    means: 'On a Mac the sign-in to your ZestSSH account is kept in your login keychain. As ZestSSH started, it read '
        'nobody signed in there, or could not read the sign-in at all, and you had not signed out: macOS may not have '
        'let it read the sign-in after an update. Your data on this Mac stays open as it was, and nothing was locked '
        'or deleted. Sync and your teams wait until you sign in again.',
    fix: [
      'Where the notice has Try again, choose it. If macOS asks about ZestSSH and the keychain, choose Always Allow '
          'and type your Mac login password. You are signed in again as you were.',
      'Where the notice has Sign in, choose it and sign in with the same account. Your data stays as it is, and sync '
          'goes on.',
    ],
    support: 'Before 3.3.3 this locked the account\'s data (or hid it) and opened empty guest data with no notice. '
        'From 3.3.3 a profile is locked at a start only where the person\'s own sign-out began (profiles/sign_out_v1 '
        'names it) or Firebase said in the same run that the account was signed in. 3.3.3 and 3.4.0 applied that only where Firebase kept the '
        'sign-in, and the Mac build has no Firebase: there a session the keychain did not show still locked, and one '
        'it refused left the person signed out with no notice but ZS-1913. From 3.4.1 both keep the data open and say '
        'so, a refused or failed read with Try again and the details to copy. A sign-out the server confirmed '
        '(another device, a password change) still locks.',
    since: '3.3.3',
  );

  static const profileWhoseUnknown = ErrorCode(
    'ZS-1915',
    title: 'ZestSSH could not tell whose data this is',
    means: 'At the first start after the update to profiles, an account had been signed in on this computer, but '
        'ZestSSH could not tell which: the sign-in was not there to read (on a Mac, macOS may not have let it read the '
        'keychain). So the data here is guest data for now. Nothing was lost.',
    fix: [
      'Sign in with your account. ZestSSH then asks whether to bring the guest data into it: choose to bring it in.',
    ],
    since: '3.3.3',
  );

  // Help > Guides: a guide's words come from docs.zestssh.com when it is
  // opened, and a copy is kept for offline.
  static final guideNotReached = ErrorCode(
    'ZS-1960',
    title: 'A guide could not be loaded',
    means: 'Help > Guides fetches a guide from $kZestDocsHost when you open it, and keeps a copy for offline. '
        'This time the docs site did not answer (the device is offline, the network blocks it, or the site is '
        'down), and this device has no copy of this guide yet. Everything else in ZestSSH works as before; the '
        'guide list and its search work offline.',
    fix: [
      'Check that this device is online, then choose Try again.',
      'Or open the guide in the browser, or read the docs at $kZestDocsHost on another device.',
    ],
    support: 'Copy details names what failed (a timeout, a refused connection, a failed secure connection). The '
        'request is a plain GET of $kZestDocsOrigin/guides/<slug>.md with no cookies or sign-in; a '
        'firewall or filter that blocks $kZestDocsHost causes this.',
  );

  static const guideUnreadable = ErrorCode(
    'ZS-1961',
    title: 'A guide could not be read',
    means: 'The docs site answered, but not with the guide: the page was not found, the answer was an error page '
        'or a web page instead of the guide\'s Markdown, or it was not text. A copy saved earlier, where there is '
        'one, is shown instead. Nothing on this device is changed.',
    fix: [
      'Choose Try again in a little while.',
      'Or open the guide in the browser.',
      'If it keeps happening, choose Copy details and send it to support: the guide may have moved.',
    ],
    support: 'Copy details carries the HTTP status. A guide that moved or was renamed on the docs site is not found '
        'by an app whose index still has its old address, until the next release.',
  );

  // Ask Astryx (4.0, a named preview): a question to Astryx through ZestSSH
  // Cloud, for paid accounts. Nothing else in ZestSSH depends on it.
  static const assistantOff = ErrorCode(
    'ZS-1962',
    title: 'Ask Astryx is switched off for now',
    means: 'Ask Astryx, the help assistant in Help, is a preview, and it is switched off on ZestSSH\'s side right '
        'now (or this server does not have it yet). Everything else in ZestSSH works as before, Help\'s guides '
        'and support tickets included.',
    fix: [
      'Search the guides in Help, or contact support: a person answers tickets.',
      'Try Ask Astryx again later.',
    ],
    support: 'The server answered assistant-off: the preview is switched off on the server or in Astryx, or '
        'Astryx is not set up for this server. A server from before 4.0 answers 404, shown the same.',
    since: '4.0',
  );

  static const assistantPaidOnly = ErrorCode(
    'ZS-1963',
    title: 'Ask Astryx is a preview for paid plans',
    means: 'While it is a preview, Ask Astryx answers for accounts on a paid plan and for members of a paid team. '
        'ZestSSH Cloud checked this account and found neither. The guides, Discord and support tickets are free '
        'for everyone, and a person answers tickets.',
    fix: [
      'Search the guides in Help, or contact support.',
      'If this account has a paid plan or a team seat, sign out and in again, then try again in a few minutes.',
    ],
    support: 'The server checks a paid team seat, the account\'s own Juiced, and Squeezed or Juiced at the store '
        '(cached ten minutes). A purchase made a moment ago may take that long to show.',
    since: '4.0',
  );

  static const assistantDailyLimit = ErrorCode(
    'ZS-1964',
    title: 'Today\'s Ask Astryx questions are used',
    means: 'Each account has a number of Ask Astryx questions a day while it is a preview (10 to start). Only '
        'questions Astryx answered count. They come back at midnight UTC. The guides and support tickets stay open.',
    fix: [
      'Search the guides in Help, or contact support.',
      'Ask again after midnight UTC.',
    ],
    since: '4.0',
  );

  static const assistantCapReached = ErrorCode(
    'ZS-1965',
    title: 'Ask Astryx is paused until next month',
    means: 'The Ask Astryx preview has a monthly spending limit for everyone together, and it has been reached. '
        'It opens again at the start of next month (UTC). Support tickets still reach a person, and nothing else '
        'in ZestSSH is affected.',
    fix: [
      'Contact support in Help: a person answers.',
      'Or search the guides.',
    ],
    support: 'Astryx answered cap_reached: the preview\'s budget for this month is spent.',
    since: '4.0',
  );

  static const assistantNotAnswering = ErrorCode(
    'ZS-1966',
    title: 'Astryx could not answer this time',
    means: 'ZestSSH Cloud answered, but Astryx did not: it took too long, could not be reached, or its AI service '
        'failed. Where it could, it showed the docs pages closest to the question. The question was not counted '
        'toward today\'s.',
    fix: [
      'Choose Try again in a minute.',
      'Or open a ticket with the question: a person answers.',
    ],
    support: 'The server answered assistant-unreachable, assistant-timeout or assistant-failed, or Astryx answered '
        'with the docs only (status degraded). Copy details names which.',
    since: '4.0',
  );

  static const assistantPlanUnknown = ErrorCode(
    'ZS-1967',
    title: 'Your plan could not be checked at the moment',
    means: 'Ask Astryx answers for paid plans, and ZestSSH Cloud could not check this account\'s plan at the moment '
        '(the store\'s service did not answer). It is not taken for a free plan. Nothing else is affected.',
    fix: [
      'Try again in a minute.',
    ],
    since: '4.0',
  );

  static const assistantRefused = ErrorCode(
    'ZS-1968',
    title: 'That question could not be sent',
    means: 'ZestSSH Cloud refused the question as it was: it was too long, a screenshot was too large, or a '
        'picture was not a PNG, JPEG, WebP or GIF. Nothing was counted.',
    fix: [
      'Shorten the question, or remove the screenshot, and ask again.',
    ],
    support: 'Copy details carries the HTTP status and the server\'s code (assistant-too-large, assistant-bad-image, '
        'assistant-bad-request).',
    since: '4.0',
  );

  static const assistantBusy = ErrorCode(
    'ZS-1969',
    title: 'Too many Ask Astryx questions in a few minutes',
    means: 'Questions to Astryx are limited to a few every ten minutes per account, besides the daily number. '
        'This one was not sent and not counted.',
    fix: [
      'Wait a few minutes, then ask again.',
    ],
    since: '4.0',
  );

  /// Every code, in the order of the page.
  static final List<ErrorCode> all = [
    moshNotInstalled,
    etNotInstalled,
    shellClientOnComputerOnly,
    moshServerMissing,
    moshServerLocale,
    moshServerDidNotStart,
    moshNoAnswer,
    moshSessionFailed,
    cloudNotResponding,
    deviceOffline,
    cloudFault,
    cloudNotSecure,
    cloudDown,
    cloudBlockedHere,
    cloudNothingReached,
    cloudReplyTooLarge,
    syncStoreUnreachable,
    syncFailedHere,
    syncWrittenFirst,
    syncHostingNotIncluded,
    syncCloudDeviceLimit,
    syncKeySecretUnread,
    recoveryKeyNotChecked,
    recoveryKeyRefused,
    signInNoPort,
    profileDidNotOpen,
    profileCopyDoesNotOpen,
    profileCopyLost,
    profileHiddenNotLocked,
    profileNeedsFreshSignIn,
    passwordLinkNotSent,
    tooManyAccounts,
    accountSwitchFailed,
    accountNotRemoved,
    lockedCopyNotDeleted,
    twoStepLeftOff,
    twoStepOtherKind,
    watchedNobodyToAsk,
    joinCodeTooManyTries,
    teamServerBehind,
    teamRecordParted,
    teamPageNotLoaded,
    teamHostLocalShell,
    teamSetAside,
    teamRecordFull,
    teamRecordEntryTooLarge,
    teamVaultsFull,
    teamUnlisted,
    teamCertWaiting,
    teamCertNotAsked,
    sudoWrongPassword,
    sudoNotAllowed,
    sudoUnavailable,
    sudoNeedsTerminal,
    sudoNoAnswer,
    ftpsNoTls,
    ftpsTimedOut,
    agentPipeNotYours,
    fidoKeyLeft,
    fidoWrongKey,
    fidoPinBlocked,
    fidoAnswerNotTrusted,
    fidoNoWay,
    screenNothingAnswers,
    screenForwardingRefused,
    screenPasswordRefused,
    screenNoSecurity,
    screenCertificateChanged,
    screenSocketMissing,
    screenWatched,
    screenCarrierGone,
    xProgramToolsMissing,
    xProgramFailed,
    xProgramEnded,
    screenRdpSignInRefused,
    screenRdpNlaMissing,
    screenRdpNlaRequired,
    screenRdpAccountLocked,
    screenRdpAccountDisabled,
    screenRdpPasswordExpired,
    screenRdpAccountNotAllowed,
    screenRdpTakenOver,
    screenRdpLicence,
    screenTeamSshOnly,
    screenGatewaySignIn,
    screenGatewayNotAllowed,
    screenGatewayTarget,
    screenGatewayUnsupported,
    screenGatewayRefused,
    screenGatewayUnavailable,
    updateDownloadFailed,
    updateNotSigned,
    updateFileMismatch,
    updateCannotInstallHere,
    updateInstallFailed,
    localSaveFailed,
    ticketRefused,
    ticketBlocked,
    ticketNeedsAccount,
    profileMoveStopped,
    keychainFile,
    profileSetAside,
    macKeychainDenied,
    macSignInNotRead,
    profileWhoseUnknown,
    guideNotReached,
    guideUnreadable,
    assistantOff,
    assistantPaidOnly,
    assistantDailyLimit,
    assistantCapReached,
    assistantNotAnswering,
    assistantPlanUnknown,
    assistantRefused,
    assistantBusy,
  ];

  /// The entry of [code], or null when it is none of ours.
  static ErrorCode? find(String code) {
    for (final e in all) {
      if (e.code == code) return e;
    }
    return null;
  }

  /// [message] with [code] after it, as every surface shows it: in
  /// parentheses at the end, where it can be read out and copied. A message
  /// that already ends in that code is left as it is.
  static String withCode(String message, ErrorCode code) {
    final text = message.trimRight();
    final ending = '(${code.code})';
    return text.endsWith(ending) ? text : '$text $ending';
  }

  /// [message] without the code it ends in, and that code; [message] as it
  /// is, and null, where it ends in none of ours. For whoever adds to a
  /// message and wants its code to stay at the end.
  static (String, ErrorCode?) withoutCode(String message) {
    final text = message.trimRight();
    for (final code in all) {
      final ending = '(${code.code})';
      if (text.endsWith(ending)) return (text.substring(0, text.length - ending.length).trimRight(), code);
    }
    return (message, null);
  }

  /// The code [message] names (the first, where it names several), or null
  /// when it names none of ours.
  static ErrorCode? codeIn(String message) {
    for (final m in _written.allMatches(message)) {
      final found = find(m.group(0)!);
      if (found != null) return found;
    }
    return null;
  }

  static final _written = RegExp('ZS-[0-9]{4}');
}
