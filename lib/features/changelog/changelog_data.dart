// Mirrors ZestSSH-Website/src/lib/releases.js RELEASES: the same
// user-facing release notes shown at zestssh.com/changelog, rendered
// in-app by the What's new dialog. Regenerate when a release is cut
// (keep newest first). En/em dashes are normalized to '-' on import.
//
// ignore_for_file: lines_longer_than_80_chars, prefer_single_quotes

enum ChangelogCategory { breaking, security, features, improvements, fixes }

/// Tier badge on a single note. Squeezed = Pro unlock, Juiced = Cloud
/// hosting. Rendered as brand pills, not translated.
enum ChangelogTier { pro, sync }

class ChangelogNote {
  const ChangelogNote(this.text, [this.tier]);
  final String text;
  final ChangelogTier? tier;
}

class ChangelogSection {
  const ChangelogSection(this.category, this.notes);
  final ChangelogCategory category;
  final List<ChangelogNote> notes;
}

/// One released version. [sections] are already in render order
/// (breaking, security, features, improvements, fixes), empties dropped.
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.date,
    this.tag,
    required this.sections,
  });
  final String version;
  final String date;
  final String? tag;
  final List<ChangelogSection> sections;
}

/// Every release, newest first. The first entry is the current version.
const List<ChangelogEntry> kChangelog = [
  ChangelogEntry(
    version: "4.1.1",
    date: "November 2026",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Tablets: Settings > General > Layout on a large screen chooses between the computer layout and the phone's tabs, however the tablet is held. A tablet with a keyboard is kept on its side, where 4.0 always showed the computer layout"),
        ChangelogNote("Terminal: hold Shift and right-click (or middle-click) to paste while a program on the host has the mouse (tmux with its mouse on, vim, mc), as Shift and a drag selects there"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("tmux: the panes take the keyboard when they open, and the terminal takes it back when they close (detached or ended). After a detach nothing typed arrived until a click or a tap, on computers and on tablets in the computer layout"),
        ChangelogNote("Tablets in the computer layout: with a keyboard attached, the on-screen keyboard no longer comes up at every tap"),
        ChangelogNote("tmux: a new session started from ZestSSH shows its prompt at once. Its pane could stay blank, the prompt above what the pane showed, until more was typed"),
        ChangelogNote("tmux on phones and tablets with a keyboard: letters keep arriving after Resync panes. Enter arrived and letters did not until a tap"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "4.1.0",
    date: "November 2026",
    tag: "Bring Your Own AI",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Your own AI app can use ZestSSH (preview, computers): turn on Settings > AI apps and paste the setup into Claude Code, Cursor, VS Code or another app that speaks MCP. It can list the hosts of your own list and open sessions on them; it reads a session only once you allow it, and every command it wants to run waits for you to allow that command in ZestSSH, where you see it typed. Passwords and keys are never given out, team hosts are not offered, and nothing listens on your network: only on this computer, with a token. Settings shows what AI apps did", ChangelogTier.pro),
        ChangelogNote("Remote access to this PC (Windows): Settings > Remote screens says whether another device can reach this PC's desktop over Remote Desktop (the edition, Remote Desktop, the sign-in before the desktop, the firewall), turns it on after Windows' administrator question, changing only what Windows' own switch changes, and lists the addresses to add from your other devices"),
        ChangelogNote("Remote screens on Windows: in full screen the Windows key, Alt+Tab, Alt+Esc, Ctrl+Esc, Alt+Space, Alt+F4, Print Screen and the menu key go to the remote instead of this PC, as in Windows' own Remote Desktop (Settings > Remote screens > Send system keys in full screen). Another program in front, or the screen losing the keyboard, gives them back at once"),
        ChangelogNote("Remote screens on Windows: Full screen on all monitors (in the screen's menu, for RDP on a PC with two or more monitors) asks the remote for one display per monitor, each at that monitor's size, place and scaling, and covers them all, as Remote Desktop's own Use all my monitors does. Ctrl+Alt+Break or the menu puts the window and the remote's displays back"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "4.0.1",
    date: "November 2026",
    tag: "Room to Work",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The file editor on a computer no longer covers the whole window: it opens where your terminals are, with the sidebar and the session tabs beside it, and has a tab of its own after the session tabs. Go to a terminal and back without losing a file, its unsaved text or where you were"),
        ChangelogNote("Edit for several hosts has a Where field: where the hosts are, with Move to and Copy to, to Personal or any team vault you can add to, with the same team rules as moving one host"),
        ChangelogNote("The lock screen can show nothing, how many sessions are still connected, or how many and their names (Settings > Security and privacy)"),
        ChangelogNote("A VNC server has three minutes to finish connecting, enough for a person at that computer to allow the connection; an RDP server still has one"),
        ChangelogNote("Ask Astryx is no longer offered on an iPhone or iPad whose App Store account is in mainland China, so ZestSSH can be offered on the App Store there again. The guides and support tickets work as always"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Remote screens: the mouse moves freely over the bars beside a picture smaller than its view, so in full screen the handle that opens the session panel can be reached; the pointer showed as held at the picture's sides, and a click on a bar clicked the remote's edge"),
        ChangelogNote("RDP to a Windows Server 2022 Remote Desktop Session Host with RDS licensing connects instead of ending with invalid security header flags"),
        ChangelogNote("Remote screens: a paste waits no longer than 2 seconds for this device's clipboard before its keys go"),
        ChangelogNote("SFTP: replacing a file with a very long name on a server without the one-step rename no longer fails"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "4.0.0",
    date: "November 20, 2026",
    tag: "The Everything Update",
    sections: [
      ChangelogSection(ChangelogCategory.breaking, [
        ChangelogNote("Once 4.0 has opened your data, going back to a 3.x version is not supported: 3.x cannot read what 4.0 adds. Devices still on 3.4 or older keep syncing your other hosts and lose nothing, but do not show remote screens, so update every device to 4.0"),
      ]),
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Teams: Test in the host editor, on a team's SSH host, checks the host key the team pinned. Before, a member who had never connected to that host was asked about whatever key answered, as for a new host, and on a yes the test signed in to that server with the host's key or the team's password"),
        ChangelogNote("Teams: a member who may edit a team's host can no longer turn it into another kind (an SSH host into FTPS or a remote screen) from a modified app. Every device now refuses such a change from another device, as each already refused its own"),
        ChangelogNote("A team's invite code or link leaves the clipboard by itself after 3 minutes, and a shared host's link, a certificate's hand-over value and a directory's sign-in token after 45 seconds, as copied passwords already did. Before, they stayed on the clipboard"),
        ChangelogNote("Telnet, which nothing encrypts, is asked about everywhere it opens: a saved workspace and the tabs brought back from last time (naming the hosts), Broadcast to hosts, an empty split pane and View on a monitored host's failed units now ask first. SFTP, the Files host pickers and starting a saved port forward refuse a Telnet host before anything connects, since Telnet carries neither files nor forwards. Another app asking to open a Telnet host with nobody there is refused"),
        ChangelogNote("Automation with nobody there (a scheduled task, an API or intent request) no longer stops to ask on screen for a key's password kept in a password manager: the run stops with the same error as any other question it cannot ask"),
        ChangelogNote("Sync: whoever can write to your sync store (ZestSSH Cloud, or your own WebDAV, S3 or Google Drive) can no longer take a device back to an old copy of your data made before copies were counted. A device that has seen a counted copy keeps what is newer on it and sends it back"),
        ChangelogNote("A server's host key that reached this device by sync or from a backup is now always pointed out at your first session with that server. Before, Server Monitor, Test or an automation run could meet the key first and use up the notice, so a key planted in a sync store or a backup was trusted with nothing said"),
        ChangelogNote("A WebDAV password, a sync server's token, a Prometheus login or a team's export token goes over plain http only when the server's name leads to your own network. Before, a short name like nas or nas.lan was trusted by how it is written, so a search domain or split DNS could send the login across the internet unencrypted"),
        ChangelogNote("A sync server, ZestSSH Cloud or your own, can no longer use up the device's memory with an oversized answer: every answer, not only the pull, is read under a size limit"),
        ChangelogNote("A port forward that listens beyond this device (0.0.0.0 or a LAN address), which lets anyone who reaches the device through your SSH connection, is asked about when it is added from a host's panel or from Home too, not only on the Port forwarding page"),
        ChangelogNote("An FTPS server can no longer make the app use memory without limit with an endless folder listing (a listing stops at 32 MiB or 200,000 lines), and Cancel or closing the tab now stops a listing"),
        ChangelogNote("Save as root and Retry with sudo write the new file beside the old one and put it in place only once all of it has arrived: a full disk no longer leaves the server's file empty or cut short, and a link another account puts in the folder cannot redirect the write as root"),
        ChangelogNote("Mac and Linux: a new plain session log, which holds what was typed and shown in the session, can be read by your own account only. Before, other accounts on the same computer could usually read it"),
        ChangelogNote("A file name a server sends can no longer pass for another: direction overrides and invisible characters are shown as codes in a phone's file browser and taken out of downloaded file names, so a name that reads as a .png cannot be an .exe"),
        ChangelogNote("An imported host's address (from a CSV file, a pasted list or another app's file) can no longer hold invisible or text-reversing characters, or characters a shell would read, so an address cannot look like another one on screen"),
        ChangelogNote("An automation request's output filter (grep) can no longer freeze the app and every open session with a pattern built to run forever: such a pattern is searched for as plain text"),
        ChangelogNote("Android: the home screen widget shows no host names while the app lock is on, only that the app is locked"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Remote screens: see and use another computer's desktop in a ZestSSH tab, over VNC or Remote Desktop (RDP), on Windows, macOS, Linux, Android and iOS. A screen can be reached through one of your SSH hosts, so nothing listens on a port on your device; a VNC screen reached directly needs VeNCrypt, and RDP always runs inside TLS, with the server's certificate trusted on first use like a host key. An SSH host keeps its screens with it: a screen button on its card, a Screens section in its panel, Open screen in its menu and in the Inspector's Tools while you are connected, and Add a screen (VNC or RDP, filled in) everywhere; Test the screen is in its editor. Free on every plan: a screen's tab counts as one session"),
        ChangelogNote("RDP signs in with Network Level Authentication unless the host says otherwise, and Test in the editor says which sign-in a server fits. On a computer the remote can be resized to fit its tab, sharp on a monitor scaled above 100 percent, the remote's text size can be set from 100 to 200 percent, also during a session, and Modern graphics uses H.264 on Windows with one display"),
        ChangelogNote("RDP: use up to four of the remote's displays. On a computer pick one or All from the bar or from a strip of live pictures down the left, or with Alt+1 to Alt+4 (Control+Option on a Mac; changeable in Keyboard shortcuts); in full screen a button for each sits beside the picture. On a phone or tablet one is shown at a time, switched with the 2 of 3 button or a three-finger swipe"),
        ChangelogNote("On a computer, Open in its own window moves a remote screen into a window you can drag to another monitor and make full screen there, while the main window keeps your terminals; Bring it back returns it to its tab"),
        ChangelogNote("RD Gateway: reach Windows PCs behind a company's Remote Desktop Gateway over HTTPS. In an RDP host's editor, Reach through, An RD Gateway, with its address and its sign-in (the same as the PC's, or a key of its own). Its certificate is asked about as a host's is, the sign-in uses NTLM with channel binding, and a gateway that refuses says why"),
        ChangelogNote("Relative mouse for RDP hosts, for games and 3D programs that turn the view with the mouse: the pointer is held for the remote until you press the menu key (F8 unless changed). On Windows, macOS, Linux (X11 and Wayland) and in a phone's Mouse pointer mode, where the server supports it"),
        ChangelogNote("RDP sessions play the remote computer's sound: on by default on a computer and off on a phone, with a switch per host, and one in the session where the host plays sound. Silent while recording mode covers the picture, while the app is locked, and on a phone in the background"),
        ChangelogNote("A remote screen's session panel (the menu key or the bar's menu button) holds everything a session can do, each with a line on what it does: view only, smooth scaling, a frame rate limit of 60, 30 or 15, Files over the screen's own SSH connection, Send text on a phone or tablet, and Session details with live graphs of traffic, the frames a second, and the round trip where the screen is on the SSH host it goes through"),
        ChangelogNote("Remote screens share the clipboard as text both ways, on by default for your own hosts and off for a team's, and on a Mac the Command key can go to the remote as Ctrl, so Cmd+C copies there"),
        ChangelogNote("Imports bring in remote desktops: VNC and RDP from MobaXterm and CSV files, Remote Desktop (.rdp) files, and two new sources, mRemoteNG and Remmina. Saved passwords in those files are never read. A .rdp file set to use an RD Gateway comes in with its gateway"),
        ChangelogNote("Open an X program on an SSH host's menu runs one graphical program on the host (xterm, gedit, virt-manager) and shows it in a screen tab, in a private X server that ends with the tab. The host needs TigerVNC's Xvnc and xauth; nothing is installed or left there"),
        ChangelogNote("Proxmox: Open console, on a VM or container imported from Proxmox (Import hosts, From the cloud), shows its console in a screen tab, through the Proxmox account kept on this device; the certificate of your Proxmox server is checked as for a host, and a team's rule of screens through an SSH host only keeps it closed"),
        ChangelogNote("Teams can hold their remote screens to two rules on the Rules page: through an SSH host only, and no clipboard shared with them"),
        ChangelogNote("Mosh is built in: Mosh hosts now open on Android, iPhone, iPad and Windows with no mosh program or WSL on the device, and on a Mac and Linux too unless Settings > Terminal and SSH > Built-in Mosh client is off. The host needs mosh-server and UDP ports 60000 to 61000 open, and the terminal shows Last contact while the host has gone quiet"),
        ChangelogNote("Security keys on phones: sign in with an SSH key that lives on a FIDO2 security key, held to the phone (NFC, Android and iPhone) or plugged in (USB-C, Android). Make one from the key editor, or paste or import its key file (id_ed25519_sk, id_ecdsa_sk). An iPad cannot, as iPadOS gives apps no NFC reader"),
        ChangelogNote("Ask Astryx in Help (preview, for paid plans and paid team seats): ask a question and get an answer from the ZestSSH docs, with links to the pages it used. See exactly what will be sent first: secrets, host names, addresses, user names and folders are taken out, then the question goes through ZestSSH Cloud to Anthropic's Claude. Open a ticket with this hands the question and answer to private support, for you to edit before sending"),
        ChangelogNote("Accessibility: ZestSSH works with screen readers, the keyboard alone and larger text. The terminal is one item a screen reader can enter, new output is read out as it arrives, and Read the screen lists every line; sessions are announced as they connect and drop; controls are at least 48 to a finger and 32 to a mouse, with a visible focus ring; reduced motion is followed; and every built-in theme's text reads at WCAG AA contrast"),
        ChangelogNote("Nerd Font icons in every terminal font: powerline prompts and file icons (Starship, Powerlevel10k, oh-my-posh, eza, lsd) show on every platform with whatever font you use, with nothing to install"),
        ChangelogNote("The SFTP panel beside a terminal can go to the terminal's folder once, or follow it every time it changes (Follow the terminal), on every plan; a phone's file browser opened from a session can go there once. Where the shell does not report its folder, the app gives the line to add for bash or zsh"),
        ChangelogNote("Terminals hide the cursor when a program asks (vim, htop and other full-screen programs), and Settings > Terminal and SSH > Show the cursor offers Always, Not while output arrives, or Never"),
        ChangelogNote("Large tablets get the computer's layout at touch size: an iPad Pro 12.9, a 10 inch tablet held sideways or an open foldable has the sidebar, the Hosts page with its host panel, session tabs, splits and the computer's shortcuts. Every right-click menu also opens with a long press, Settings > Appearance > Control size sets how big controls are, and on an iPad Cmd works in place of Ctrl"),
        ChangelogNote("Lock ZestSSH with Ctrl+Shift+L (unless changed in Settings) or from the command palette while the app lock is on, also with Settings or a dialog open, and if you like, show how many sessions are open on the lock screen (a count, never a name)"),
        ChangelogNote("Speech to text in the terminal on Windows and macOS: Speech to text in the Inspector's Tools, with what it hears and its language, or Ctrl+Shift+Space. It listens until you turn it off (the microphone that shows in the session header while it listens, the shortcut or Esc). Heard on the device only, typed at the prompt and never sent with Enter", ChangelogTier.pro),
        ChangelogNote("Scheduled tasks run on Windows, macOS and Linux while ZestSSH is open or in the tray, from Automation's Runs; a run missed while the app was closed runs once when it opens", ChangelogTier.pro),
        ChangelogNote("Windows, macOS and Linux: Settings > Notifications > Also show as system notifications (off at first) shows a lost connection, a workflow's notice, an alert that plays a sound or a support answer as a system notification while ZestSSH is not in front"),
        ChangelogNote("iPhone: a home screen widget with up to four of your hosts, hidden while the app lock is on, and Shortcuts actions, in all 12 languages"),
        ChangelogNote("Mac: hardware-backed encryption with the Secure Enclave in Settings > Security and privacy, off until you turn it on, as Windows has with its TPM, so your data copied to another Mac stays locked there"),
        ChangelogNote("A phone adds an OpenSSH certificate to a key from the key's own editor (Add certificate), where before only a computer could"),
        ChangelogNote("Backup places can be added on a computer (Settings > Backups and data > Backup places), and Google Drive can be added as one on a phone"),
        ChangelogNote("Drop a key file on a computer's Keys page to add it, and Create new key at the end of Add another key in the host editor makes a key and adds it to the host"),
        ChangelogNote("Snippets: Run on starts with Local terminal on computers and Android tablets: the snippet runs in a new terminal on this device, its variables and confirmation asked first"),
        ChangelogNote("Open in split from the command palette: Ctrl+Enter opens the host in hand as a pane beside the tab in front"),
        ChangelogNote("Tap a plan's name anywhere in the app (Squeezed, Juiced, Bundle) to see what each plan is and what you have. A Squeezed page you have not bought (History, Workflows, Scheduled tasks) shows itself with made-up examples, and on a computer its price"),
        ChangelogNote("Team settings, a page of its own with the team's name and Delete team, with 7 days to undo"),
        ChangelogNote("Teams: Move or copy at the top right of a saved host's, key's, snippet's or port forward's editor moves or copies it to Personal or to any team vault you may add to"),
        ChangelogNote("Session tabs say what they hold at a glance: a terminal, a remote screen (its tab a cooler blue), files only, this computer or a split of several, with the status on that mark. The tabs a workspace opened sit behind its named chip, which folds them away and back"),
        ChangelogNote("Teams: folder bookmarks shared with the team. On a team host's file pane, Add bookmark for the team puts a folder under Shared with the team for everyone who can see the vault; members who may edit the host add, rename and remove them, and your own bookmarks stay yours"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The free plan opens 5 sessions at once on a computer and 3 on a phone or tablet (was 4 and 2)"),
        ChangelogNote("A session's scrollback takes about a seventh of the memory it did: 50,000 lines at 80 columns hold about 15 MB instead of about 98 MB"),
        ChangelogNote("Busy sessions and large syncs no longer hold the app still: a session's output is handled once a frame instead of once a network chunk, a large sync is decrypted in the background, and a computer's status bar no longer ticks with nothing to count"),
        ChangelogNote("A new lock screen: why it locked, one PIN box, a phone's own number pad, on a computer Windows Hello or Touch ID as a button that never opens by itself, and how many wrong PINs are left before a wait"),
        ChangelogNote("Settings has one structure on every device: Account, Plan, General, Appearance, Keyboard and mouse, Notifications, Terminal and SSH, Files, Remote screens, Security and privacy, Backups and data, About. Each setting is one line, with More for its help"),
        ChangelogNote("Host cards show the system icon, name and address, with at most Open and one health chip; tags and the colored stripe are off by default. Active first is in the Sort menu, New host is always the last card, and the right-click menu is grouped"),
        ChangelogNote("A phone's Hosts tab: a search, one row of group chips, and each host a row that connects at a tap. A phone's New host form has the protocols as tiles, field names above the fields, and Save in a bar that says why it is off"),
        ChangelogNote("The first connection to a server names it, groups the fingerprint in fours with Copy fingerprint, gives the ssh-keygen command to check it, and its button says Trust and connect. FTPS and screen certificates ask the same way"),
        ChangelogNote("The command palette sorts what it finds under Hosts, Actions and Snippets, marks what matched, and starts with your recent hosts"),
        ChangelogNote("Import hosts opens on a drop zone for a file, with the apps and clouds as tiles, and a computer's app theme is picked from a gallery drawn in each theme's colors"),
        ChangelogNote("The SFTP panel beside a session has the path bar on one row with Up, Refresh, Upload and New folder, opens with two panes side by side, and can show the host's files alone (turn off More > Two panes side by side), and says so when the session drops, with Reconnect"),
        ChangelogNote("When a file already exists, Replace is chosen first, also where the server's copy could not be read (it says so); Skip and Keep both are a click away"),
        ChangelogNote("Team pages: the Overview starts with Needs attention, the Roles table says each level in words, and the Vaults window shows one vault at a time with its settings under tabs. Business says more than 25 seats"),
        ChangelogNote("The welcome puts Start using ZestSSH, with no account, first, and the Sign in sheet says what an account is for: joining a team or using ZestSSH Cloud. Syncing through your own storage needs no account"),
        ChangelogNote("On a phone, deleting a key names the hosts that sign in with it"),
        ChangelogNote("A phone's terminal bar shows a stopwatch before the session's time (tap it for Connected for 12m 7s), and the Server monitor's cards read larger on phones and tablets"),
        ChangelogNote("Unsaved edits in Port forwarding, Keys, Networks, Snippets, Automation workflows and Alerts survive going to a terminal and back (kept in memory only, never on disk), and Port forwarding's Simple and Advanced keep what you typed when you switch between them"),
        ChangelogNote("More error messages can be copied with Copy details, also ones that had no details before"),
        ChangelogNote("Numbers, dates, times and counts read as your language writes them (0,52 in German, 1 file and 2 files), and sentences with a name or a number in them read whole in every language"),
        ChangelogNote("Keep screen awake has its row on a computer too, and with Close to tray on, closing the window minimises it where no tray icon can bring it back"),
        ChangelogNote("Session recordings are written to disk as they run, so a closed or killed app keeps what was recorded, and a recording that outgrew its limit says how much of its start was left out"),
        ChangelogNote("Automatic backups keep the last backup that held your data when the ones after it are much smaller, so a week of backups of emptied data no longer replaces every good one"),
        ChangelogNote("The file transfer list keeps the last 1,000 finished files instead of every file ever sent (a larger folder keeps its file count), and failed ones stay for Retry"),
        ChangelogNote("About > Open source licenses lists every bundled font's licence, the notices of code the app includes, and on Windows and Linux the native libraries the build carries"),
        ChangelogNote("Help's Is my data safe? and How are passwords stored? now say exactly which connections are encrypted (Telnet is not) and when a password can be written in plain text"),
        ChangelogNote("iPhone and iPad: a downloaded file says where it went (the ZestSSH folder in Files)"),
        ChangelogNote("Linux packages recommend what the file dialogs and the tray need: zenity or kdialog, gdbus and gio"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Editing a saved alert is saved again: every edit failed with ZS-1906 since 2.0"),
        ChangelogNote("An SSH server that asks for a new password, because the old one has expired, no longer ends the connection with an internal error: ZestSSH goes on to the next way of signing in it offers"),
        ChangelogNote("Bright white in the terminal is bright white again: programs that use it showed plain white"),
        ChangelogNote("A link longer than a terminal row is one link: it is underlined on every row it covers, and a click on any of them opens the whole address, so a sign-in link no longer opens cut off after its first row"),
        ChangelogNote("Phone or tablet with Encrypt data at rest on: a team's data on the device is no longer deleted, with the changes it had not sent yet, when the app locks while a team sync is under way; the team opens again once you unlock"),
        ChangelogNote("When a device cannot read a key's saved secret, its sync and backups stop with an error that names the key (ZS-1206), instead of syncing the key as one without a secret, which made your other devices delete their own copy of it"),
        ChangelogNote("Phone or tablet with Encrypt data at rest on: Delete all local data turns the app lock off and keeps the app's data readable; before, what you added after the wipe could not be opened after a restart"),
        ChangelogNote("A host, key or snippet saved on this device while a sync was being received is no longer written over by another device's older change"),
        ChangelogNote("The host, key, snippet and group editors keep what a sync changed while they were open: a name, an address, a command and the other main fields you did not touch are no longer written back"),
        ChangelogNote("An item deleted on a device whose clock was ahead is no longer deleted again at every sync after you restore or make it again"),
        ChangelogNote("One record with a name that is too long, or empty, no longer stops a whole sync or restore"),
        ChangelogNote("Data written by a newer ZestSSH no longer opens in this version without a word: the start says to update ZestSSH and changes nothing"),
        ChangelogNote("Putting back the copy made before an update is one step, so a stop in the middle no longer leaves a cut database"),
        ChangelogNote("Downloading a folder between the panes on a computer: two server files whose names come to one local name (a:b and a_b on Windows, Makefile and makefile) are both kept, instead of one overwriting or mixing with the other"),
        ChangelogNote("Cancel all on a folder transfer stops the whole folder: files still waiting their turn no longer start one after another"),
        ChangelogNote("An upload or a download no longer loses the file it replaces when its last step fails"),
        ChangelogNote("A download that broke off is continued only from the same server, so a file can no longer be made of two servers' halves"),
        ChangelogNote("Copying onto a file that is already on the server compares size and time, so identical files are skipped and the overwrite question shows its details"),
        ChangelogNote("Exporting a key on a computer saves through the system's save dialog: on Linux export works again, and on Windows the files are no longer deleted before Share could use them"),
        ChangelogNote("A WebDAV backup, Check connection, redeeming a code, the profile picture, Prometheus and Google Drive backups no longer wait forever on a server that never answers"),
        ChangelogNote("Server Monitor and the reachability checks on a computer go on while another window is in front"),
        ChangelogNote("FTPS on a phone: the phone's side of the file screen opens in a folder it can list, where downloads go"),
        ChangelogNote("Update on the banner for a newer team version, Show in folder on a saved transcript, and Wake on LAN now say so when they fail"),
        ChangelogNote("Running zestssh admin while ZestSSH is open says to close ZestSSH first, instead of starting a second app"),
        ChangelogNote("Voice input on Android 11 and later can find the phone's speech recognizer"),
        ChangelogNote("Mac: Wi-Fi name rules are no longer offered, as macOS gives the Wi-Fi name only to apps with location access, so they could never match"),
        ChangelogNote("Two-step sign-in: where your passkeys cannot be used on this device, it now says your authenticator app's code works too"),
        ChangelogNote("Teams: a team whose name does not read on this device can be deleted from it, and the only owner who hands the team to someone else before leaving compares safety words with them first"),
        ChangelogNote("Teams: a group change your role does not allow is said instead of failing silently, and New group from a selection leaves no empty group behind"),
        ChangelogNote("Team, Members: a member's row no longer runs past its edge when what they hold for a set time is long"),
        ChangelogNote("A scheduled task's switch shows its knob, a session's replay is titled in your language, and the PIN confirm step opens empty"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.4.2",
    date: "November 8, 2026",
    tag: "Backups Keep Their History",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("A server can no longer open X11 connections to ZestSSH that you never asked for, and X11 cookies and environment values are kept out of the connection log"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Automatic backups keep a real history again: daily and weekly backups are kept apart from the ones made after a change, those are made at most once an hour, and connecting to a host no longer counts as a change, so a few app switches can no longer replace every good backup"),
        ChangelogNote("Mac: when macOS will not let ZestSSH read where you sync to (WebDAV, S3, Google Drive or your own server), sync waits and says why instead of treating it as ZestSSH Cloud; signing out or setting up sync again then deletes and overwrites nothing"),
        ChangelogNote("Restoring a backup says why it did not open (not a backup, made by a newer version, cut short, too large or damaged) instead of always saying the password is wrong, with details to copy"),
        ChangelogNote("Backups are written to a temporary file first, so two at once or a crash mid-write never leave a broken one, and copies sent to WebDAV or Google Drive no longer pile up"),
        ChangelogNote("Sync now never stays stuck on running, changes made while sync was manual go out when it is automatic again, and Try again after signing a device out works the first time"),
        ChangelogNote("The terminal handles two more character set escape codes, so some programs no longer print stray characters"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.4.1",
    date: "November 7, 2026",
    tag: "Your Mac Stays Signed In",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Editor windows of their own close when you sign out or switch account, and their unsaved drafts never land in another account"),
        ChangelogNote("Recording mode now masks host names and paths in editor windows of their own too, and follows every change at once"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("File editor on a computer: minimize it and bring it back from the status bar with every tab as you left it; a second file opens as a tab in the editor already open, and a file already open comes to the front"),
        ChangelogNote("File editor on a computer: move a tab to another editor window from its menu, or on Windows drag it onto the other window; editor windows of their own keep unsaved drafts too"),
        ChangelogNote("Team setup files can describe FTPS hosts"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Mac: when ZestSSH cannot read your saved sign-in after an update, your data stays open with a Sign in again notice instead of locking and showing an empty space; Try again asks macOS again and signs you back in (ZS-1914)"),
        ChangelogNote("File editor: putting a second editor in a window of its own no longer shows Something went wrong"),
        ChangelogNote("A sign-in link like Tailscale SSH's check mode also shows when connections run in the background connection worker"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.4.0",
    date: "November 7, 2026",
    tag: "FTPS, Tabs and a New Support Hub",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("A public bug report or idea shows you exactly what everyone will read before it goes, with host names, addresses, user names and secrets it recognises replaced, and Include diagnostics starts off for public posts"),
        ChangelogNote("Writing a file as root refuses a symbolic link at the destination, and password fields, sudo's included, turn off keyboard suggestions and learning"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("FTPS: connect to FTP servers over TLS, explicit on port 21 or implicit on 990, and browse, upload and download in the file panes. Plain FTP is never used. A server's certificate is trusted on first use with its fingerprint, like an SSH host key, and on Windows a certificate Windows trusts is accepted too"),
        ChangelogNote("FTPS transfers resume where they broke off, even after a restart, and are checked after transfer where the server can say a file's SHA-256"),
        ChangelogNote("Teams share FTPS hosts under the same rules as SSH hosts, with the server's certificate pinned for the whole vault. Versions before 3.4 do not see them"),
        ChangelogNote("Imports bring FTP and FTPS sites in from FileZilla, WinSCP, MobaXterm, SecureFX and CSV as FTPS hosts. Saved passwords in those files are never read"),
        ChangelogNote("A new file editor: tabs with files from several hosts at once, find and replace with match case, whole word and regex, go to line, a status bar with the encoding and line endings, the terminal's look, a minimap on computers and a new phone layout"),
        ChangelogNote("Save as root in the file editor: it asks first, and the sudo password is typed each time and never kept. Unsaved changes are kept encrypted on the device for 7 days and come back when you open the file again"),
        ChangelogNote("Retry with sudo in Files: when the server says permission denied on a rename, move, new folder, delete, upload or download, the notice offers to do it again as root"),
        ChangelogNote("A new Support Hub: My tickets grouped by what waits on whom, Known issues and Ideas boards anyone can +1, signed in or not, together with the +1 button in our Discord, possible duplicates as you type, a redacted screenshot, and diagnostics shown in full before they go"),
        ChangelogNote("Select many hosts, keys, snippets or port forwards at once: edit many hosts together, delete many, and Move to or Copy to between your own space and a team. On a phone a long press starts selecting"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("When a server's sign-in waits on a link, like Tailscale SSH in check mode, the link shows while connecting with Open link and Copy link, on every platform and on jump hosts, runs and the connection test too, and you get 5 minutes to approve"),
        ChangelogNote("Every dialog follows one design: clear titles, the safe choice first, and Enter never confirms a delete"),
        ChangelogNote("Mac: ZestSSH is signed and notarized by Apple, so it opens without the right-click Open step. macOS may ask for your login password for saved keys one last time after this update, then stops asking at each update"),
        ChangelogNote("Italian says Spazio personale for your own space, and Portuguese reads as Brazilian Portuguese throughout"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Two hosts with the same name no longer share a file editor tab, so Save always writes to the right host"),
        ChangelogNote("Deleting a host or a network also removes its per-network settings"),
        ChangelogNote("In a YAML file Tab types spaces, and line numbers stay beside their own lines when long lines wrap"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.3.3",
    date: "November 6, 2026",
    tag: "Your Data Stays Put",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Mac: when ZestSSH cannot read your sign-in after an update, it no longer locks your account's data without a word. The data stays open as it was, and a notice says Sign in again to keep syncing (ZS-1914)"),
        ChangelogNote("Reset never deletes your data: it sets the data aside instead, and on a computer Put it back restores it"),
        ChangelogNote("The first start after an update from 3.2 keeps each account's data with that account, or says plainly when it cannot tell whose data it is (ZS-1915)"),
        ChangelogNote("When the data on screen is empty but an earlier copy is on this computer, ZestSSH offers to bring it back"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.3.2",
    date: "November 6, 2026",
    tag: "A Quieter Keychain on Mac",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Mac: ZestSSH asks macOS for its saved keys far less often. A sync no longer reads every saved key only to list them, each is read once at start, and a key macOS refused is not asked for again until you choose Try again"),
        ChangelogNote("Mac: after an update, ZestSSH first says that macOS will ask for your login password for its saved keys, one box per key, and to choose Always Allow. A refused key shows one notice with Try again (ZS-1913), and the start-up screen no longer offers Reset for it"),
        ChangelogNote("A delete that a team's vault refuses changes nothing: a host could keep its row but lose its tags, port forwards and other accounts, and keys, snippets, groups and networks could change the hosts that used them"),
        ChangelogNote("Automation API keys, the accounts a recovery knows and a device's team owners are kept when they cannot be read, instead of being saved again as empty"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.3.1",
    date: "November 5, 2026",
    tag: "Settings Opens, Updates Stay Fresh",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Account recovery keeps your synced data in more cases: typing your sync password anywhere the app checks it now sets up the recovery check, and where your account has none yet, Security asks once: Keep your data in a recovery"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("On a computer, Settings opens every time again: after a link, a team join or a lock it could stay lit in the sidebar and do nothing, with the keyboard shortcuts gone too, until ZestSSH was restarted"),
        ChangelogNote("An app left open checks for updates again every 6 hours, and Update and restart or Update and close installs the newest release, not the one it found first"),
        ChangelogNote("Signing out of an account on a computer without internet says what happened: its data is hidden, not locked, and signing in and out again while online locks it"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.3.0",
    date: "November 5, 2026",
    tag: "Passkeys, Accounts on One Computer and Safer Teams",
    sections: [
      ChangelogSection(ChangelogCategory.breaking, [
        ChangelogNote("Update every device in a team. Changing the Admin role, limiting one person's vault access and deleting a team are new kinds of change to a team's record: they turn on once 3.3.0 is out on computers and phones alike and an owner makes the first one, and a device on an older version then says it stopped following that team's record and stops syncing it until it is updated"),
        ChangelogNote("Windows, macOS and Linux: the first start moves your data into a profile of its own for your account, with \"Moving your data to its new place\" on screen. Nothing is lost if it stops, and it goes on at the next start. An older version run afterwards starts empty"),
        ChangelogNote("SSH: a host whose RSA host key is shorter than 2048 bits is refused (the floor was 1024), and the message says both lengths. Compatibility mode, for old devices that cannot make a longer key, still takes it"),
      ]),
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("A team's host never opens a shell on your own device, and what it types as a session starts (a start-up command, a snippet on connect, its variables) is shown and asked first, text by text, and asked again when the text changes"),
        ChangelogNote("Signing in through the browser on a computer shows a six-character sign-in code in the app, and zestssh.com asks for it before it signs you in, so a sign-in link someone else made cannot sign you in to their program. Type only the code your own app shows, never one someone sent you. A ZestSSH before 3.3 on a computer is asked to update before it signs in through the browser"),
        ChangelogNote("On a computer two people share, neither can make it theirs alone by removing their own account, and Delete all local data no longer takes another person's accounts: where one is here, it offers only the profile on screen and says why"),
        ChangelogNote("A host this device confirmed keeps its key: a sync, a backup or guest data brought into an account can no longer add another key for it, an older MD5 record from elsewhere is asked about as a new host, and a host trusted on a direct connection keeps its key when it is reached through a jump host"),
        ChangelogNote("A file or folder name a server lists can no longer run a command on that host through Open terminal here or a download's checksum: a name any shell could read as a command is never put into one. An escape code any program can print no longer freezes a session's screen until a reconnect"),
        ChangelogNote("SSH: a reply the app did not ask for is dropped, a server that starts new keys and never finishes is disconnected instead of filling memory, and the server's version line is shown filtered; on a phone a downloaded file gets a safe name, as on a computer"),
        ChangelogNote("Teams: ZestSSH Cloud alone can no longer remove a team or a vault from your device or approve a member's lost device again, and an offer it changed (a role, vault access, an end date) lets nobody in from the inviter's device and is shown first on others. A team it stops listing is held, with Remove from this device"),
        ChangelogNote("In a team, a copy of an item in another vault counts only as a move by someone allowed to make it, so a member who may add in one vault can no longer replace a host in a vault they cannot change. Where neither copy could have moved it, owners and admins choose which one to keep"),
        ChangelogNote("Sync notices a store that went back to an older copy of your data, says so and keeps this device's settings"),
        ChangelogNote("Windows, macOS and Linux: an update unpacks in a private folder and is checked again just before it runs, and a path in an imported file that is really a network share is refused before anything reads it"),
        ChangelogNote("Windows: your SSH agent is used only when Windows says the OpenSSH Authentication Agent or one of your own programs serves it, and a second start hands its zestssh:// link only to ZestSSH's own window"),
        ChangelogNote("On a computer, the SSH keys an account gave your system's SSH agent are taken back however that account's data leaves the computer, and Delete all local data asks first where the agent cannot be reached. A port forward or proxy with no bind address listens on this device only unless Allow other devices on my network is on (on Windows it listened on a network address)"),
        ChangelogNote("A team's alert rules can no longer freeze the app with output made for them: each rule has a share of time for each burst of output, all of them together have one too, and no more than 100 run"),
        ChangelogNote("In a team, one member's item can no longer stop or freeze everyone else's sync: an item that cannot be read is set aside, and the rest syncs"),
        ChangelogNote("Command history leaves out more commands that carry a password: sshpass -p, a login with -p (docker, podman, oc, az, cf), curl with user:password, and a password in an address such as https://user:token@host"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Accounts on one computer: on Windows, macOS and Linux each account that signs in keeps its own hosts, keys, settings and teams, apart from every other account and from guest data. Signing out locks them until that account signs in again. Switch accounts, add one (yours or someone else's, five at most) or remove one from the computer at the bottom left. Phones and tablets do not change"),
        ChangelogNote("Passkeys for two-step sign-in, instead of an authenticator app: your face or fingerprint or a security key. Add one in the app on Android, iPhone, iPad and Windows, or on zestssh.com from a Mac or Linux, and sign in with it in the app on a phone or tablet, or in the browser on a computer. An account uses passkeys or an authenticator app, not both: adding a passkey replaces the app, after asking, and backup codes work with either. On Android, iPhone, iPad and Windows, Confirm it's you offers Use your passkey in place of a whole sign-in for a team's changes, approving a device and signing devices out"),
        ChangelogNote("Lost your second step and every backup code? Recover your account at sign-in on a phone or tablet, or on the Account page on a computer: a code by email, then seven days' wait that every signed-in device is told of; with your sync password (typed once in 3.3, as you set up or unlock sync) your data comes with you, and without it a reset says first what it loses"),
        ChangelogNote("Delete a team, with seven days to undo it, once 3.3.0 is out on computers and phones alike: owners find Delete team under the Overview's Danger zone, the confirmation lists what goes, every member is told and held back, and any owner or admin can choose Undo until the day comes. No payment is refunded automatically"),
        ChangelogNote("Vault access for one person: give a member more than their role in a vault from the vault table in their panel and, once 3.3.0 is out on computers and phones alike, a lower level or No access, which they alone are told of. The Trust page says who set it"),
        ChangelogNote("Hosts that are SFTP only, for servers that give files and no shell: they open straight into the file browser. A normal SSH host whose server refuses a shell says so, with Open its files and Make this host SFTP only"),
        ChangelogNote("Owners buy team seats in the app on a computer: Buy seats opens Seats and billing, to pay by card on Stripe's page in your browser or by invoice, with no second sign-in"),
        ChangelogNote("The Support Hub on a computer: tickets, bug reports and suggestions in one page, opened with F1 outside a terminal, showing exactly what will be posted as you type"),
        ChangelogNote("Invite many people at once: paste a list of addresses or Import CSV..., and each is checked before anything is sent. A team code lets up to 25 people ask to join with one code, and nothing is made until Make code"),
        ChangelogNote("Roles: Duplicate any role the owners made, let directory groups become roles, and let company sign-in count as two-step sign-in where an owner turns that on. Once 3.3.0 is out on computers and phones alike, the Admin role changes like any other, and Give Admin everything again puts it back"),
        ChangelogNote("Tabs on a computer say where a host comes from: while tabs from more than one place are open, each shows its team, vault and group, or Personal, under the host's name. Settings, Appearance chooses when"),
        ChangelogNote("Update and close, beside Update and restart, for an update that should leave ZestSSH closed"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("A computer's sign-in is renewed about once a week while you use it, so it is no longer signed out every 30 days, and a device signed out without you asking finds sync as it was when you sign in again"),
        ChangelogNote("Check your browser waits up to 15 minutes for a sign-in in the browser, with Open again, Copy link and Cancel"),
        ChangelogNote("Team changes take a sign-in from the last two hours instead of ten minutes. The team rule Sign in again is now Sign-in lasts, with what the short choices cost, and it warns before it runs out"),
        ChangelogNote("Members on a computer: each person's name and picture first, with the address under it; Owner is one of the roles in Change role; Suspend and Remove from the team sit under a Danger zone that says what each does; tick invitations to withdraw them, or Withdraw all unused codes"),
        ChangelogNote("Directory sync: a group opens to its people, Directory changes has Invite all and Set aside all, and a switch lets the directory lower roles too, off by default"),
        ChangelogNote("Team rules: a bar keeps unsaved changes in sight with Discard and Save rules, and a list of address domains says who it would leave out before saving. When access ends, for a member or an invitation, takes a time as well as a day"),
        ChangelogNote("Host lists: one row for a host everywhere, an Active first switch in every picker, and on a computer a remade Broadcast to hosts, Server monitor columns you can resize, thresholds in two panes, and workflow steps that run on many hosts with a result for each"),
        ChangelogNote("The paste and run warnings explain themselves in two levels: what can do lasting harm keeps the red question, and what only needs a look says Check this command"),
        ChangelogNote("Importing detects the file you give it, reads PuTTY sessions from a .reg file, and can turn on Compatibility mode for every host it brings in"),
        ChangelogNote("Updates on computers pick up a download that drops where it stopped"),
        ChangelogNote("Phones: the app lock is offered once, after your first private key or saved password; it stays off unless you turn it on"),
        ChangelogNote("A personal host saved while sync is off says it is on this device only, with Set up sync"),
        ChangelogNote("Windows, macOS and Linux: double-clicking empty space on the title bar zooms the window again (on a Mac, as System Settings says), and the lock screen and welcome have the window's controls, so a locked app can be closed"),
        ChangelogNote("Windows: once ZestSSH from the Microsoft Store is on the PC, the installer from zestssh.com opens it instead, and the zestssh.com copy hands its hosts, keys and settings over to it and goes. Where both hold some it asks which to keep, says when each was last used, and sets aside what you do not keep for 30 days. An older Store copy waits until it is updated, and a silent install, as winget makes, installs as usual"),
        ChangelogNote("Phones and tablets: the keys list follows your theme, a port forward's page and Snippets look like the rest of the app, Hosts and Networks keep one column on a tablet, and a button that is turned off shows on a dark sheet"),
        ChangelogNote("21 terminal themes: Midnight and Catppuccin Mocha have their own, so Match terminal to app theme works for them. The Inspector's font size can be typed, and Save layout as workspace asks which tabs to save"),
        ChangelogNote("On a computer, sixteen fixes from a design review: the Hosts toolbar keeps one row with a side panel open, a workspace's name is whole in the drawer, every disk in the host panel has its alert, and a fingerprint is whole where it fits"),
        ChangelogNote("Times read one short way everywhere (4m ago, 2h ago, 1h 59m left), in each language's own short form"),
        ChangelogNote("A phone's Sessions tab groups sessions under the host's name with its address, numbers two to one host with when each started, and greys one that is disconnected"),
        ChangelogNote("Every Danger zone but a vault's has the same red header, This device is a grey chip, team recovery is set up from the card's head, a pick-one choice is a dot, and on a tablet Keys, Port forwarding, Settings, Snippets and More keep the centred column"),
        ChangelogNote("A saved entry is a host everywhere, in all 12 languages: Save host, Delete host, All hosts, No hosts yet. A live link is still a connection or a session"),
        ChangelogNote("Phones: the terminal bar names the host by its name, as the tabs under it do; SFTP's folder and file count sit above the gesture bar; and a port forward's Web preset has a browser window's icon"),
        ChangelogNote("A support ticket that went says so with its number, Sent: ticket #N, the number the server gave it"),
        ChangelogNote("On a computer the idle lock counts input anywhere on the computer (on Linux, with GNOME), so working in another app beside ZestSSH no longer locks it, and Lock when the computer locks, on with the app lock, locks ZestSSH when the computer locks or sleeps"),
        ChangelogNote("A team that lets in approved devices only can approve the device someone joined on as they are let in, with a ticked Also approve their device, so they use the team on it at once with no pairing words to compare"),
        ChangelogNote("One word for each idea: the sync password, backup codes for two-step sign-in, safety words to compare a teammate's keys, pairing words to approve a device, the app lock, face or fingerprint, and Confirm it's you only for your account"),
        ChangelogNote("Saving a snippet says so, with its name, as saving a host does"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Sync to Cloudflare R2 takes every update again: after the first upload each one was refused as another device syncing at the same moment (ZS-1203)"),
        ChangelogNote("A server behind a provider's filter that never answered ZestSSH, while other SSH clients connected, now connects: ZestSSH waits for the server's greeting before it offers a key exchange, as OpenSSH does"),
        ChangelogNote("Phones: the file editor's Save sat under the status bar and could not be tapped, and the snippet editor's Cancel and Save sat under the navigation bar"),
        ChangelogNote("On a computer, a terminal tab you pick takes the keyboard at once, without a second click; on a phone in tmux mode, the key row, a snippet and a paste reach the pane in front"),
        ChangelogNote("ZestSSH no longer copies its whole database at every start: a copy is made only before an upgrade, and the three newest are kept"),
        ChangelogNote("Alerts on a computer: a colour just picked no longer reverts after Save, and a save that fails says so"),
        ChangelogNote("Linux: a locked login keyring no longer reads as ZestSSH could not start; it says how to unlock it and goes on once it is"),
        ChangelogNote("Phones and tablets also get what 3.2.6 and 3.2.7 fixed on computers: a host behind a firewall that inspects SSH is said so in about ten seconds, confirming it's you no longer signs you out right after, and a team code that is not taken says why"),
        ChangelogNote("Phones and tablets: back and a swipe back ask before the file editor drops unsaved changes, and the keyboard no longer turns quotes, dashes and words into others in it"),
        ChangelogNote("Test full connection in the host editor no longer fails while you check a new host's key, and on a phone every action of a file in SFTP is in reach and a link to a folder opens it"),
        ChangelogNote("Android: Delete all local data also stops the scheduled tasks it deletes, which kept coming up with no way to stop them; tasks an older version left behind stop at the next start"),
        ChangelogNote("Sync: a change saved while a sync is under way is sent too (it waited for the next change), and Set as default on a key no longer brings back a key deleted on another device"),
        ChangelogNote("Joining sync on a device, with the sync password, a recovery key, a device's approval or Restore from cloud, keeps a host or snippet changed on it later than the synced copy, where the synced copy wrote over it"),
        ChangelogNote("Restoring a backup deletes nothing on this device, and brings back what was deleted since the backup was made"),
        ChangelogNote("Clear all data clears this device only: it turns sync off here first and deletes the keys' passwords and passphrases too, so nothing comes back at the next sync"),
        ChangelogNote("A password taken off a key on one device, or moved into a password manager, is taken off it on your other devices too"),
        ChangelogNote("On a computer, signing out no longer locks away for good an account whose copy on ZestSSH Cloud is gone (deleted from another device, or under Locked copies on your computers)"),
        ChangelogNote("The terminal shows a character the host's output splits between two reads whole, where it showed replacement marks"),
        ChangelogNote("SFTP: a file or folder whose name is not UTF-8 (Latin-1, for example) opens, renames and deletes, and a server that floods replies no longer grows the app's memory without end"),
        ChangelogNote("Copying a local file over 8 MB, and the session log, no longer fail partway"),
        ChangelogNote("SSH: a channel the server refuses is no longer kept counted, and a forwarded agent's channel closes when the host is done with it"),
        ChangelogNote("Session sharing: a share that drops with the network comes back with it instead of ending as if you signed out, and someone joining gets the right scroll region. A host whose name has a quote in it can be shared as a link or QR code"),
        ChangelogNote("Android automations: a deleted or turned off scheduled task's notification runs nothing, and with Encrypt data at rest on, a task tapped while ZestSSH is locked runs once it is unlocked and a Tasker request is told ZestSSH is locked"),
        ChangelogNote("A saved workspace with two terminal panes on one host opens two sessions, not one session shown twice"),
        ChangelogNote("Networks: a VPN coming up over Wi-Fi counts as a network change, for the banner and the port forwards that start by network"),
        ChangelogNote("Cloud import: Check now during a timed check no longer adds machines twice, Headscale machines are told apart by their server, and SecureCRT ports are read by protocol"),
        ChangelogNote("Server Monitor shows a Mac's memory in use right on Apple silicon, where it showed a quarter of it"),
        ChangelogNote("The file editor's pop-out no longer asks you to discard the text that moved to the new window, and in a pick-one list a tap on the chosen dot closes it and the arrow keys move between rows"),
        ChangelogNote("On a phone, two files of one batch download or upload that share a name each keep their own, where the second replaced the first"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.7",
    date: "October 28, 2026",
    tag: "Closes Clean",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Windows: closing ZestSSH no longer crashes on the way out. 3.2.6 still did, at a later step, and left a crash report each time; it now closes straight away"),
        ChangelogNote("Confirming it's you by signing in again no longer signs you out right after, so you no longer have to sign in twice"),
        ChangelogNote("A code entered under Team, Seats, Redeem a code that is not taken now says why (the team had its free Business months already, has Business now, or would pass its seat limit) instead of an HTTP error"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.6",
    date: "October 28, 2026",
    tag: "Clearer Through Firewalls",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("A host behind a firewall that inspects SSH (such as a SonicWall with DPI-SSH on) that stops answering during the key exchange is now said so in about ten seconds, with what to do (Compatibility mode, or an exclusion on the firewall), instead of \"Sign-in timed out\" after the full wait"),
        ChangelogNote("Windows: closing ZestSSH no longer crashes on the way out, which made closing pause for a few seconds and left a crash report behind each time"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.5",
    date: "October 27, 2026",
    tag: "A Welcome for New People",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("A welcome on first launch: sign in, create an account, or continue without one, which keeps everything on this device"),
        ChangelogNote("Join a team without an account yet: Join a team and Create a team let you sign in or create an account right there, keep your invite code, and then show the team"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The team's Members page shows who is waiting for you as a banner at the top, with Review, and Review on the Seats page opens that person's review directly"),
        ChangelogNote("Windows, macOS and Linux: Upgrade has a button of its own above Join Discord, so a click on your name never opens pricing; not signed in, a Sign in button is there instead. On phones and tablets, Sign in is at the top of More"),
        ChangelogNote("Settings search finds the Account and security page, and Connections as SSH config is on a computer's account page"),
        ChangelogNote("Phones and tablets also get what 3.2.4 brought to computers: make or join a team on a new account without setting up sync first, team seat codes under Redeem a code, and your email's first letter on your account picture"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("The Members page could show a used invite code as unused, with nothing to review, until ZestSSH was reopened: it now reads who is waiting when it opens and every 30 seconds while it is open"),
        ChangelogNote("An invitation that was accepted now stays open at least a week for you to review, even when its code was made to last an hour"),
        ChangelogNote("Windows, macOS and Linux: Switch to session on the Hosts page brings the session on screen (it did nothing), and selecting hosts shows one bulk bar instead of two"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.4",
    date: "October 27, 2026",
    tag: "Teams on New Accounts",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Windows, macOS and Linux: make or join a team on a new account without setting up sync first. Your team keys are made on this computer, and once the team has a seat it includes ZestSSH Cloud sync, which ZestSSH offers to turn on"),
        ChangelogNote("A code for team seats entered under Account, Redeem a code now goes to a team: one you own, or a new team you name there"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Resizing the SFTP panel is smooth again, and its edge stays under the pointer; dragging the line between split panes is smoother too"),
        ChangelogNote("Copy redacted screenshot: Save as PNG opens in your Downloads folder"),
        ChangelogNote("Your account picture shows your email's first letter instead of a question mark when your account has no name"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.3",
    date: "October 26, 2026",
    tag: "Google Drive Sync on Computers",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Windows, macOS and Linux: Google Drive sync works on computers. It said it was not available on this computer; now Test connection opens Google's sign-in in your browser, and ZestSSH sees only its own hidden sync file in your Drive"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.2",
    date: "October 25, 2026",
    tag: "Copy the Last Lines, Linux on Older Systems and Old Servers",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Copy from screen opens at the newest output and shows the last 100, 250, 500 or 1,000 lines, all of them, or a number you type (Custom). Your choice is kept, and Copy copies the lines shown"),
        ChangelogNote("Linux: the packages now run on older systems too: Ubuntu 20.04 and later, Debian 11 and later, and RHEL and Rocky 9"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Copy from screen has a scrollbar you can drag through long output, and buttons to jump to the top or the bottom"),
        ChangelogNote("Compatibility mode is labelled for old servers only and says it is not recommended. For a server that cannot be updated it now also connects with 1,024-bit key exchange groups, and a host refused for an outdated key exchange says where to find the switch"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Windows, macOS and Linux: Manage in Account and security opened a phone-style sheet at the bottom of the window; it opens a menu at the button"),
        ChangelogNote("Windows and Linux: Two-step sign-in and How you sign in said \"Could not check\" when the account server could not tell; they now say where to see and change them, with a button to zestssh.com"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.1",
    date: "October 25, 2026",
    tag: "Key Sizes, Even Keys and Hardware Keyboards",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Key size: Small, Medium or Large keys for the key row, as two rows or scrollable"),
        ChangelogNote("With a hardware keyboard, the key row can keep only the keys the keyboard lacks: F1 to F12, Insert, Delete, Home, End, PgUp and PgDn. This is the new default on tablets; phones still hide the row"),
        ChangelogNote("Customize keys works for the two rows too: hide keys and change their order. The F keys, PgUp, PgDn and Insert stay on the FN page"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Every key of the key row is the same width, so the rows line up in columns. Grouped outlines the arrows with Home and End, Flat leaves them plain, and the Compact style is now the Small key size"),
        ChangelogNote("The scrollable key row's keys share a tablet's width up to a comfortable size, then sit in the middle instead of growing very wide"),
        ChangelogNote("Two rows: HOME, ↑ and END stand over ←, ↓ and →, and FN is one tall key at the end"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Phones and tablets: a long press on the terminal selects a word without bringing the keyboard back up, and a drag scrolls; a short tap still opens the keyboard"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.2.0",
    date: "October 24, 2026",
    tag: "Inline Autocomplete, a New Tab Page and Vault Avatars",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Inline autocomplete in the terminal: as you type, the dimmed suggestion now also offers paths on the host (starting with / or ~/), saved hosts after ssh and your snippets, besides your history. Right arrow takes it. No AI: nothing leaves the device but a folder listing asked of the host you are connected to", ChangelogTier.pro),
        ChangelogNote("A New Tab page on computers: Ctrl+T finds open tabs by name, and with nothing typed shows the hosts you connected to last and your saved workspaces"),
        ChangelogNote("Vault avatars: a team's vault chips show who else can open each vault"),
        ChangelogNote("Android: pull down the notification shown while sessions are open to see which hosts they are on; the lock screen shows only how many"),
        ChangelogNote("Host icons follow your hosts to every device: a host with no icon of its own keeps the icon of the system seen on it, so a phone shows it before it ever connects. A picked or uploaded icon always stays"),
        ChangelogNote("Tablets in a keyboard case: on its side, the key row's Fn page has PgUp, PgDn, Insert, Delete, Home and End, in every key style"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The extra key row's settings stay on each device: a phone's and a tablet's rows no longer change each other"),
        ChangelogNote("The scrollable key row's two rows stand in columns, every key one width, and share a tablet's width when they fit"),
        ChangelogNote("The Fn page says PgUp and PgDn (it said PU and PD), and upright it no longer repeats Home and End, which the main page has"),
        ChangelogNote("Phones: a dialog's explanation scrolls with its fields, so the field you type in stays in view with the keyboard up (Create a team's name, for one)"),
        ChangelogNote("Phones: the Manage tab's guide button sits next to its title, apart from Help & support"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Bottom sheets showed two grab handles on phones; they show one"),
        ChangelogNote("A key's actions sheet cut off Delete on smaller phones; it scrolls"),
        ChangelogNote("The phone's host list drew a letter even for a host whose system the phone had seen; it shows the system's icon, as a computer does"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.1.0",
    date: "October 24, 2026",
    tag: "A Manage Tab, Swiping Between Sessions and Groups on Phones",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Phones: the tabs are now Hosts, Sessions, Manage, Monitor and More. Manage holds Keys and Port forwarding, Snippets moved into More, and old links to Keys or Port forwarding open Manage. Tablets keep their tabs"),
        ChangelogNote("Phones: a sideways swipe on a terminal's top bar moves to the previous or next session, in the order the Sessions tab lists them, and shows its name for a moment. A swipe on the terminal itself still selects and scrolls as before"),
        ChangelogNote("Phones and tablets: the bell starts with Needs you, what waits for you right now (a host down or failing, a device or person waiting for approval, a changed team key, sync failing or paused, a certificate running out), each with the one action that resolves it. A row leaves by itself once resolved, and the bell's count includes them"),
        ChangelogNote("Phones: the info button on a host's row opens the host's own page, with Connect and Files, its health, recent sessions, port forwards, how it connects, its tags and its note"),
        ChangelogNote("Phones and tablets make, edit and delete groups: New group in Move to a group, in the host editor's group list, at the end of the group chips and behind the Hosts tab's +, and a long press on a group's chip or header for Edit group, New group and Delete group (its hosts are kept, ungrouped). An empty group keeps its chip. In a team space, only someone who may add to the vault sees them"),
        ChangelogNote("Phones: Arrange on the Hosts list drags hosts into your own order within a group, and the order syncs with your computers"),
        ChangelogNote("Help > Guides: a picture opens full size, with zoom, the guide's next and previous pictures, and its words as a caption"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Phones: the helper key row is one grid, each column as wide as its widest key, with the arrows, Home and End as one cluster. A new Key style setting picks Grouped (the default), Flat (the look before 3.1) or Compact (smaller keys, more terminal)"),
        ChangelogNote("The Monitor tab on a phone: the network strip sits right below the status bar, and a host that cannot be checked says why (it could not be reached, the sign-in was refused, or the check failed) and \"Trying again now.\" while it retries, instead of \"Connecting to collect stats.\""),
        ChangelogNote("Duplicate names the copy in your language (it said \"(copy)\" in English everywhere), and in a team a copied host or key stays in the vault it came from when you may add there"),
        ChangelogNote("An SSH certificate that cannot be read says so in your language, with the reason behind Copy details"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Phones: a digit from the keyboard's number row hid the helper key row, since Android keyboards send digits as key presses, which counted as a hardware keyboard"),
        ChangelogNote("Phones: coming back to the app with the keyboard open now opens it again, after the app lock when it is on, with no empty space left"),
        ChangelogNote("On a computer, Restore in another tab brought back the first tab's maximized terminals: a maximized pane's layout is now kept per tab"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "3.0.0",
    date: "October 23, 2026",
    tag: "Teams, a New Look and Updates From Inside the App",
    sections: [
      ChangelogSection(ChangelogCategory.breaking, [
        ChangelogNote("Update ZestSSH on every device you sync. 3.0 adds to what syncs, and a device still on 2.x does not take the newer data: it stops syncing until it is updated too. The first start of 3.0 upgrades the app's database, and an older version cannot open it afterwards"),
        ChangelogNote("From November 30, 2026, ZestSSH for Windows, macOS and Linux older than 3.0 can no longer sign in to a ZestSSH account through the browser, and the sign-in page says to update. Those versions bring the sign-in back from the browser with your session token in the address; 3.0 brings back a one-time code that only the app can trade. Phones and tablets sign in another way and are not affected"),
        ChangelogNote("Juiced is ZestSSH Cloud for one person on up to 7 devices. On an eighth device, sync to ZestSSH Cloud pauses and offers Sign out a device, which signs one of your other devices out after asking; a computer not signed in for 30 days no longer counts. Sync to your own storage (WebDAV, S3, Google Drive) stays free with no device limit, and members of a paid team have no limit", ChangelogTier.sync),
        ChangelogNote("Automation API keys are shown once, when you make them, and only a hash of each is kept. Keys made before 3.0 keep working but can no longer be copied again: make a new one if you no longer have it"),
        ChangelogNote("New names and one layout: the terminal triggers are now Alerts, and \"identity\" is now \"key\" wherever the app meant a saved key or password. The Classic and Modern layouts are retired for one title bar and one session header, and the per-host card sizes are gone"),
        ChangelogNote("Self-hosted (a ZestSSH sync server of your own) is no longer offered as a new place to sync to, since no such server is given out to run. A device already set up with one keeps syncing and can move to another store"),
      ]),
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("With Encrypt data at rest on, the secrets ZestSSH keeps in your device's secure storage are now also sealed under your vault's key, so they open only after your PIN: your keys' private keys, saved passwords, passphrases and certificates, the sync key, your account keys, each team's database key, your ZestSSH sign-in token, the logins of your own sync storage, cloud import tokens and the automatic backups' password. Before, the system's secure storage alone protected them, so a copy of the device's files could use them without your PIN. With it off, nothing changes"),
        ChangelogNote("With Encrypt data at rest on, your PIN is checked against the vault alone. Earlier versions also kept a quicker-to-check hash of the PIN on the device, so someone with a copy of its storage could guess the PIN faster; 3.0 deletes it at your next unlock"),
        ChangelogNote("A zestssh:// link opened while the app is locked now waits until you unlock it. Before, its question showed over the lock screen, so whoever had your device in hand could add a shared host or open a session to one of your saved hosts without unlocking the app"),
        ChangelogNote("On Windows, macOS and Linux, signing in through the browser now brings back a one-time code that only the app can trade, with a secret it keeps. Before, your ZestSSH session token came back in the address, where it stayed in the browser's history (and on your other computers where that history syncs). The Upgrade button no longer puts your account's id in the checkout address either"),
        ChangelogNote("The connection to ZestSSH Cloud accepts only certificates your system trusts. A device that ran ZestSSH before 1.7 had saved a fingerprint of the certificate it met on first contact, and later versions let that certificate through even when the system's checks failed; 3.0 deletes those saved fingerprints when it starts"),
        ChangelogNote("Signing out of your ZestSSH account now also turns off ZestSSH Cloud sync on that device. Before, its sync keys stayed, and sync went on with them for the next account signed in on the same device. Sync to your own storage goes on, since it needs no account"),
        ChangelogNote("S3 sync to a plain http:// address is now accepted only for an address on your own network, as WebDAV already was: elsewhere, anyone on the way could copy your encrypted vault or hand back an older one. Use https:// for anything else"),
        ChangelogNote("SSH: ZestSSH no longer connects to a server that offers only a Diffie-Hellman group under 2048 bits, or whose RSA host key is under 1024 bits, since someone with enough computing power could break those and read a recorded session or answer in the server's place. The app says why and what the server needs; Compatibility mode, for old routers and switches, still takes a short RSA host key"),
        ChangelogNote("SSH, against someone between you and a server: with a server that has no strict key exchange, nothing sent in the clear is taken once its host key is approved, so a made-up sign-in and session can no longer be shown to you (what you typed could never be read); the Terrapin defense is held to its whole rule; and a made-up RSA host key can no longer freeze the app for minutes before you are asked whether to trust it"),
        ChangelogNote("SSH: ZestSSH asks a server for new encryption keys by itself after a gigabyte of data or about two billion packets, as OpenSSH does. Before, it waited for the server to ask, so a very long session to a server that never asks could go past what its cipher allows under one set of keys"),
        ChangelogNote("SSH sign-in: a saved password goes only to a server that says it takes passwords (a server that takes only keys was sent your saved password after it refused the key), and every signature an RSA key makes is checked before it is sent, since a faulty one can give the key away to the server that sees it"),
        ChangelogNote("A secret you copy (a private key, an API key, a recovery key, two-step codes) is taken off the clipboard 45 seconds later and when the app locks, whichever screen it came from; closing the screen sooner used to leave it there. Pasted text can no longer carry control characters such as ESC, which could end a bracketed paste early and run the rest as if typed"),
        ChangelogNote("Files no longer stay behind: a connection shared as a .zest file stayed in the app's temporary folder, and Connections as SSH config left every host's name and address in your Documents folder. Shares are now deleted once done (on Android at the next start), a computer asks where an export goes, what earlier versions left in the temporary folder is removed at start-up, and backup codes saved on a computer are readable by your user account alone"),
        ChangelogNote("A host someone shared with you keeps its port forwards on this device only (127.0.0.1). Before, a forward the share bound to every address opened its port to your network once started"),
        ChangelogNote("Server Monitor no longer forwards your SSH agent to a host that has Forward SSH agent on. Its background connection did, so that host could use the keys in your agent for as long as it was monitored; only the sessions you work in forward it now"),
        ChangelogNote("Windows: every program ZestSSH starts (PowerShell, ssh-add, WSL and others) is started from where Windows keeps it, never from the current folder, and a shortcut opened in the SFTP local pane can no longer run what its name says"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Teams: next to your personal space, a team shares hosts and keys in shared vaults, end-to-end encrypted on its members' devices, so ZestSSH Cloud passes them along and cannot read them. Who may do what is a signed history that every device checks for itself, and no server can change it"),
        ChangelogNote("Roles with a level in each vault (Connect, Use, Edit or Manage), and team rules: two-step sign-in, approved devices only, the app lock, no export, an offline limit, and signing in again every few hours or days. A device that does not meet them is held back until it does"),
        ChangelogNote("Invite by email, several addresses at once, or with a one-time code shown as text, a link and a QR. The code checks both sides' keys, so there is nothing to compare by hand, ZestSSH Cloud never sees it, and nobody gets anything until an owner lets them in"),
        ChangelogNote("Short-lived SSH certificates from a vault's own certificate authority: members sign in with their own key and a certificate that runs out, instead of a shared password or key. With them come host keys the team pinned, access for a set time on request, and removing someone, which replaces the team keys they held and lists the passwords and keys to change"),
        ChangelogNote("The audit log: version history, what members did, and event export of the team's signed events to your own log system (Splunk, Datadog, Elastic, Microsoft Sentinel and others), each off until an owner turns it on, and every member is told when they do. Trash brings back what was deleted in a vault for 30 days"),
        ChangelogNote("Session sharing: share a session with teammates as a shared tmux session or as a live view encrypted between the devices, hand the keyboard to one viewer at a time, and mark a vault as watched so its sessions start only once someone who manages it is watching. Team session logs, off until an owner turns them on, leave out the secrets the session knows"),
        ChangelogNote("Team recovery by two owners, guests with an end date, the key log of every signed change, and setup as code: a JSON file of the team's vaults, roles, rules, members and hosts, checked and applied from the Team page or with zestssh admin from a terminal"),
        ChangelogNote("Team is \$100 a seat, bought once, for 2 to 25 seats: Squeezed and Juiced for every member while they are in the team, short-lived certificates, the audit log and unlimited ZestSSH Cloud devices. Business adds \$20 a seat a month or \$200 a year for company sign-in (SSO, with SAML 2.0 or OpenID Connect), directory sync (SCIM 2.0), the rule that members use company sign-in, and more than 25 seats. Seats are bought on the website, and redeem codes now look like ZEST-XXXX-XXXX-XXXX"),
        ChangelogNote("The 3.0 look: the themes Ember, Graphite (the new default) and Daylight, a terminal theme that follows the app theme, one title bar and one session header, Settings as a pop-up on a computer, and the Inspector beside a session with Session, Tools and Look"),
        ChangelogNote("Five more app themes in the looks of the editors you know, One Dark, One Light, Darcula, IntelliJ Dark and IntelliJ Light, each with a matching terminal theme. Every built-in theme is free; themes you design yourself stay with Squeezed"),
        ChangelogNote("Updates from inside the app on Windows, macOS and Linux: an Update available pill when a new release is out, its notes, then Update and restart. Every download is checked against a list signed with ZestSSH's own release key, with its size and SHA-256, and a file that fails is deleted unopened. The check sends nothing about you, About has a switch to turn it off, and Store builds update through their store"),
        ChangelogNote("Help > Guides: twenty step-by-step guides, one for every major feature, searched in the app even offline, and a small question mark beside a page's title opens its guide. The guides are in English"),
        ChangelogNote("History suggestions: while you type a command, the newest matching one from your history is shown dimmed after the cursor, and Right arrow takes it. Never at a password prompt, in a full-screen program or in recording mode", ChangelogTier.pro),
        ChangelogNote("The Hosts page remade: one toolbar, a list view with sortable columns and a column picker, a compact grid, sections that fold, and many hosts picked at once (Ctrl, Shift, Ctrl+A or a drag) to move, pin, open as tabs or panes, or save as a workspace. A host's panel shows its health, recent sessions, forwards, tags and note"),
        ChangelogNote("Keys: Replace on all hosts puts a new key on each host and proves it signs in before the old one is taken off, and there are Add to agent, Export and a passphrase you can add, change or remove. A key can keep its password in 1Password, Bitwarden or KeePassXC, and a host can have more than one account, with Connect as"),
        ChangelogNote("One Import hosts dialog: an SSH config file (with an offer, unticked, to copy the private keys it names), PuTTY sessions, Termius, a pasted list, a CSV file, a share link and six clouds (AWS EC2, DigitalOcean, Hetzner Cloud, Azure, Tailscale and Proxmox VE), read from their APIs on your device"),
        ChangelogNote("Run on hosts runs one command on many hosts, Broadcast to hosts opens a group in one tab typing to all of them, and Install key on hosts puts a key on many hosts at once. Free on as many hosts as the free plan opens sessions at once, and on more with Squeezed"),
        ChangelogNote("Approve a new device on ZestSSH Cloud from one you already use, by three matching words, with no sync password typed"),
        ChangelogNote("Pause sync for an hour, a day or until you resume, and choose when it runs: on every change, every 5 minutes up to every 24 hours, or only by hand. Reset cloud sync, for a sync password lost with no recovery key, keeps the old cloud copy for 30 days"),
        ChangelogNote("Wake-on-LAN on every device, a recovery kit to save or print with Check to test a recovery key, a lock when idle, nano keys in the file editor, and support tickets with their answers in the app"),
        ChangelogNote("Tablets work with a hardware keyboard and mouse. On phones, About has Rate ZestSSH, and the store's own rating prompt may appear, at most once per version"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Port forwarding is free on every plan"),
        ChangelogNote("Remade pages: Port forwarding, Networks, Snippets, Alerts, History (its filters on one row; Run again runs a command exactly as typed), Automation (templates, the editor, Runs and API keys) and Server monitor (a table, its warning limits in the status bar, and Reboot needed shown, never acted on)"),
        ChangelogNote("Errors say what went wrong in your language, with a code where it helps, and Copy details copies a report with keys, passwords, addresses and names taken out"),
        ChangelogNote("When ZestSSH Cloud cannot be reached, the app says whether it is down, blocked by your network, or your device is offline, and that your hosts, saved logins and open sessions are not affected. Sync keeps trying by itself and never gives up"),
        ChangelogNote("Sync merges three ways: a change made on this device between two syncs is kept even when another device synced meanwhile, a delete made elsewhere still applies, and sync storage restored from an older backup is caught up instead of refusing every change"),
        ChangelogNote("One account per email address: Google, Apple and an email with a password are ways into the same account, never several, and Account > Security shows how you sign in"),
        ChangelogNote("A zestssh:// link asks before it does anything and opens in the app that is already running, on every computer, and automation links work, after saying what runs and where"),
        ChangelogNote("Broadcast belongs to a tab, with its own button, a switch on each pane and a box to leave a terminal out, and it types only what you type: a terminal's answers to its own host no longer reach the others"),
        ChangelogNote("Panes share their tab evenly as terminals are added or closed, Ctrl+Tab follows the tabs as the strip shows them, and an arrow with Shift, Ctrl or Alt sends what xterm sends"),
        ChangelogNote("A connection that drops is connected again by itself, and a session whose connection dropped says why: the host closed it, or the network to it broke, with what to try"),
        ChangelogNote("A new password that locks something away (a backup export, a new key's passphrase) is typed twice, and a new sync password needs 12 characters at least"),
        ChangelogNote("macOS: the menu bar has the app's own menu (About, Settings, and Quit with Cmd+Q), and Edit > Copy and Paste work"),
        ChangelogNote("Every icon button says what it does to screen readers, and screens keep their words whole on a phone 360 wide, at a large text size, and in a small window"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Windows: no released version started on a PC without the Visual C++ runtime. ZestSSH now brings the runtime it needs"),
        ChangelogNote("Automatic backups turned on from the Profile page never asked for a password, so none were made, and backup places set up in Settings never received a backup"),
        ChangelogNote("Set up sync on a second device while the first was still setting up could end in an error or write over the first device's vault"),
        ChangelogNote("Settings that nothing read now work: the default SSH port and the connection timeout on a computer, the Connection lost notification, haptic feedback, and three phone settings"),
        ChangelogNote("A port forward's Start automatically switched itself off at every sync, Find in terminal left the matches out of view, and Quick connect could sign in as another user than the one you typed"),
        ChangelogNote("File transfers and file panes waited forever when the connection dropped, and files under /proc and /sys would not open or download"),
        ChangelogNote("A server could stop the app by asking to resize the terminal, and a host whose notice before sign-in is not UTF-8 could not be connected to"),
        ChangelogNote("Server Monitor did not say why a host could not be checked, and on a phone said Checking beside hosts it was not monitoring"),
        ChangelogNote("A key whose passphrase was removed on another device became unreadable, and an RSA key's public line said rsa-sha2-256, which sites that take SSH keys refuse; it says ssh-rsa"),
        ChangelogNote("Android 8 to 10: backups and files downloaded from a host were not saved, and a batch sent by Tasker did not run"),
        ChangelogNote("macOS and Linux: Mosh and Eternal Terminal installed with Homebrew or MacPorts were not found, and on Windows they could not sign in with a host's key through WSL"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "2.3.0",
    date: "October 11, 2026",
    tag: "No More Surprise Bans, Keys Fixed on Phones and Terminal Repairs",
    sections: [
      ChangelogSection(ChangelogCategory.breaking, [
        ChangelogNote("The checks of whether your hosts can be reached are now off until you turn them on (Settings > Check whether hosts are reachable). They connected to every saved host every 20 seconds and hung up without signing in, which a server logs, and which got people banned from their own servers by fail2ban. With them off the reachable dots on the Hosts page are gone; a host with an open session still shows as connected. Turning them on asks first, says what a server sees, and the interval you pick is now really used"),
        ChangelogNote("Sign-in details are no longer sent over plain http to addresses on the public internet. WebDAV sync, a custom sync server and Prometheus with a login may use http only on your own network; use https for anything else"),
      ]),
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Hardened the SSH handshake: a key exchange now takes exactly one answer from the server, and anything else ends the connection"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Android: a new switch, Settings > Terminal > Incognito keyboard. Turn it off if your keyboard (SwiftKey among them) does not work well in the terminal"),
        ChangelogNote("Sync says plainly when it is off, behind or failing, in the status bar and on the account page, and clicking the version in the status bar checks for an update"),
        ChangelogNote("PuTTY keys with a passphrase (PPK version 3) can be imported: the app asks for the passphrase. A key that cannot be imported says why, once, in your language"),
        ChangelogNote("Server Monitor and the latency figure use the connection a session already has, and Server Monitor no longer dials again and again a host that refused its sign-in"),
        ChangelogNote("A confirmation whose text does not fit a small window scrolls, and its buttons stay in reach"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Phones and tablets: a key from a physical keyboard was sent twice. Arrow up skipped the last command, and the cursor in vim and other editors moved two places. The same happened in a pop-out window on a computer"),
        ChangelogNote("Android: the search on the Hosts tab found nothing. It now filters by name, address, user and group"),
        ChangelogNote("Windows: opening SFTP froze the window for up to half a minute when a mapped network drive was not reachable"),
        ChangelogNote("Terminal: selecting, searching and highlighting broke after a full-screen program such as vim or nano had scrolled, and colour schemes lost their background until a repaint"),
        ChangelogNote("Terminal: after clear, a selection landed some rows below what was dragged over, and a right or middle click now pastes when the button is let go, which mends pasting over remote desktop tools"),
        ChangelogNote("Terminal: after the scrollback had filled up, changing the width of a terminal scrambled the screen or stopped its output. This is the likely cause of the crash with many sessions in one group"),
        ChangelogNote("Terminal: dialogs of Debian tools closed by themselves on a session whose TERM is linux, because the terminal answered codes that were no question"),
        ChangelogNote("A snippet of several lines written on Windows ran double spaced: both characters of its line ends were typed as Enter"),
        ChangelogNote("The three dots menu on snippet cards, trigger cards and History rows did nothing"),
        ChangelogNote("A host with two sessions was shown as closed once the first of them ended"),
        ChangelogNote("Sync: a device whose sync keys no longer matched the account showed Could not reach the sync server over and over. Sync now pauses and says what to do"),
        ChangelogNote("Sync now in Settings did nothing but say Syncing. It syncs, and says what happened"),
        ChangelogNote("Android: WebDAV sync over http to a server on your own network was refused"),
        ChangelogNote("Server Monitor: the CPU figure of a Linux host was its load average, so an idle container could read 100%, and a host back within its limits stayed marked for several checks"),
        ChangelogNote("The Hosts page did not scroll with a touchpad, or with mouse wheels that scroll smoothly"),
        ChangelogNote("Renaming a file in SFTP on a computer selected the whole name instead of the part before the extension"),
        ChangelogNote("A session dragged out of a group left the selection and the keyboard focus on another pane"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "2.2.1",
    date: "September 24, 2026",
    tag: "Jump Host Sync Fix, Face ID Vault and a Folding Sidebar",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Desktop: an arrow at the top of the narrow sidebar folds it into a strip of icons and back, Ctrl+B does the same outside a terminal, and your choice stays after the app restarts"),
        ChangelogNote("SFTP batch rows name what you dragged, like rag-corpus, pipeline +1 · 67 / 70 files, instead of only a count"),
        ChangelogNote("Sign out everywhere now says plainly that it cannot erase what a lost device already stored, so change the passwords and keys it held too"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Sync stopped for good on a device that connected to a server through a jump host while your other device still had that server's key saved for a direct connection: every sync and Restore from cloud failed with a database error (UNIQUE constraint failed) until the app's data was cleared. Both copies are now kept, so both devices trust the server both ways, and a device that was stuck syncs again once it updates"),
        ChangelogNote("A host key saved twice for the same server no longer breaks that server's host key check and every sync"),
        ChangelogNote("The macOS app quit at launch (\"ZestSSH quit unexpectedly\") in every download since 2.0.0: its signature switched on a macOS check that the bundled frameworks could not pass. The 2.2.1 download opens"),
        ChangelogNote("iPhone and iPad: with the vault bound to Face ID or Touch ID, enrolling a new face or finger locked the vault for good. The vault key now also accepts the device passcode and survives a new enrollment; it moves to the new setting at the first unlock after updating (one Face ID prompt). A vault already locked by an earlier change cannot be recovered this way: restore it from a backup or Cloud Sync"),
        ChangelogNote("tmux session counts on your hosts stopped saving after the app locked and unlocked"),
        ChangelogNote("On desktop, the sidebar stayed as icons when the Hosts panel was switched on but hidden on the Hosts page"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "2.2.0",
    date: "September 23, 2026",
    tag: "Two-Step Sign-in, Signed-in Devices and Sync Fixes",
    sections: [
      ChangelogSection(ChangelogCategory.breaking, [
        ChangelogNote("Update ZestSSH on every device you sync. 2.2.0 adds your account's own keys to the synced data, so once one device updates and syncs, devices still on 2.1.1 stop syncing and ask to be updated. Update phones and tablets before you turn on two-step sign-in too: older versions there cannot ask for the code"),
      ]),
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Two-step sign-in: signing in to your ZestSSH account can also ask for a six-digit code from an authenticator app (Google Authenticator, Microsoft Authenticator, 1Password, Bitwarden and others). Set it up in Profile > Security on phones and tablets, or at zestssh.com/account/security on Windows, macOS and Linux. Ten backup codes, shown once, turn it off if you lose your phone, and your address gets an email when one is used. Firebase Authentication, the sign-in service ZestSSH uses, keeps the authenticator's secret and checks your codes; the secret is shown once on your device so you can add it to your authenticator app, and never reaches ZestSSH Cloud, which keeps only keyed hashes of your backup codes. Free"),
        ChangelogNote("Signed-in devices: Profile > Devices lists every device signed in to your account with its platform and sign-in date. Sign one out, or sign out everywhere (which also ends Google sign-ins), after a fresh sign-in, so a stolen device that is still signed in cannot sign you out. Nothing else about your devices is kept: no hostname, OS or app version, IP address or last-active time. Free"),
        ChangelogNote("ZestSSH Cloud keeps no activity logs: no record of your syncs, sign-ins or account changes, and no IP addresses. The services around it (Firebase for sign-in, Cloudflare for the network, Stripe and the app stores for payments) work under their own policies, named in the privacy policy, and the app shows the updated policy once"),
        ChangelogNote("Account keys: every account that syncs gets its own encryption and signing keys, made on your device and carried in your encrypted sync data, ready for sharing with a team in 3.0. Nothing changes in how you use the app"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("SSH servers that ask for a one-time code (an authenticator or Duo through PAM, RSA SecurID, a YubiKey) now work: the server's question appears in a dialog that says it comes from the server, you answer it, and your saved password only ever goes to a real password prompt, once. Background connections (monitors, automation) still answer nothing"),
        ChangelogNote("Delete account deletes at once: sign in again, enter your sync password when ZestSSH Cloud holds your data, and the account, its synced data and its sign-in are removed and checked gone before the app offers to wipe this device"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("SFTP conflict prompts count every file in a folder upload before it starts: Conflict 1 of 4, and Do this for the remaining 3 conflicts. When a count cannot be known in advance it counts up instead of guessing, and Replace if newer appears only while more conflicts follow"),
        ChangelogNote("On Windows the local SFTP pane shows the Windows attributes that are really set (R read-only, H hidden, S system) instead of a made-up drwxrwxrwx, and no longer offers a Permissions dialog that could change nothing there"),
        ChangelogNote("The Activity panel stops a live transfer with a red stop square, while the grey x only removes a finished row from the list, and the pane footer says what its size covers once folders are selected"),
        ChangelogNote("Rename tree takes effect everywhere, the Teams screens say they arrive in 3.0, and the tab menu's last copy entry is gone"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Profile > Sync now overwrote edits made on your other devices: it pushed this device's copy without merging. It now pulls, merges and pushes like the background sync, and says what stopped it instead of reporting success"),
        ChangelogNote("Self-hosted sync (WebDAV, S3, Google Drive): after the sync password changed on one device, another device could break the store so no new device could join. Key material now travels only with the key it belongs to"),
        ChangelogNote("Delete account failed for accounts made with older settings, or after the sync password was changed on another device"),
        ChangelogNote("On desktop, Sign out from the Tree menu and Manage Tree said Signed out but stayed signed in"),
        ChangelogNote("RSA certificate logins work on current OpenSSH servers (they announced the wrong algorithm), and certificates on hardware keys, and keys in a forwarded agent, can sign"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "2.1.1",
    date: "September 22, 2026",
    tag: "Host Icons, Smarter SFTP Replace and Transcript Fixes",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Host icons redrawn: 130 line icons in eight categories (hardware, network, cloud, services, security, places, tags) and 31 OS and platform marks, all in one white style and tinted with the host's own colour, so a red production box gets a red icon and a blue lab box a blue one. The picker has search and category sections, and every icon you already chose keeps its meaning"),
        ChangelogNote("A tmux button beside Snippets in the session bar: one click opens tmux on that host, and once attached it shows the session name and opens the sessions menu (switch, new, resync, detach, kill)"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Transcripts made honest: Save transcript so far writes everything on screen, scrollback included, whether or not you were recording; Record transcript from now is its own choice; and Stop recording saves first (a cancelled save keeps recording). Every save asks where and whether to encrypt, then ends with the path, a Show in folder button and an entry in the notification bell"),
        ChangelogNote("SFTP Replace changed files now compares content when a same-size file has a different modification time, so a rebuilt folder (new timestamps, same bytes) is no longer re-uploaded in full: both ends are checksummed, unchanged files are skipped, and the drop says how many it skipped, or that everything was already up to date"),
        ChangelogNote("Tab menu: Copy SSH command is gone, and Close others / Close all only appear when there is another tab"),
        ChangelogNote("Account emails (address confirmation, password reset) arrive branded and readable instead of the bare default, and the connection log records the negotiated key exchange, cipher and host key type"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("The pop-out SFTP editor opened as a blank grey window: the window carried no translations, so the editor failed to build and showed only a grey error box. Pop-out windows now render in your language, and a build error in one is printed instead of hidden"),
        ChangelogNote("Stopping a transcript recording used to throw the recording away, on desktop and on mobile; it is saved now, and the app says where"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "2.1.0",
    date: "September 22, 2026",
    tag: "Post-Quantum SSH, Session Logs and Eternal Terminal",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Post-quantum key exchange: every SSH connection now offers mlkem768x25519-sha256 (the OpenSSH 9.9+ default) and sntrup761x25519-sha512 (the OpenSSH 9.0 to 9.8 default) first. Both pair a post-quantum KEM with X25519, so a recording of your session cannot be decrypted later by a quantum computer, and a server without them simply negotiates the classic exchange. ML-KEM-768 is checked against the NIST FIPS 203 vectors, both were verified against OpenSSH 10.2, and the session details show a Post-quantum badge when one was used"),
        ChangelogNote("A cleartext key-exchange reply that happened to have a certain length was rejected with Invalid padding length when ChaCha20 or AES-GCM had been negotiated (seen with ecdh-sha2-nistp256 and an Ed25519 host key). Padding is now checked against the cipher actually in force"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Session log to file: log every session to a plain-text file as it happens, PuTTY and SecureCRT style, with the escape sequences stripped so it reads like the screen did, an optional timestamp on every line, one file per session that a reconnect appends to, and tmux panes marked inside it. Off by default and unencrypted on purpose (a session's secrets end up in the file); pick the folder on desktop, share or delete the files from Settings on mobile"),
        ChangelogNote("Eternal Terminal (ET) as a connection protocol: sessions that survive network drops, sleep and roaming and come back with their scrollback intact. Runs the system et client like Mosh does (WSL on Windows, desktop only), with your SSH port and key handed to its handshake"),
        ChangelogNote("Remote copy to clipboard (OSC 52): let tmux, Vim and Neovim on the remote host put text on this device's clipboard. Off by default because the host then decides what your next paste contains; reading your clipboard is refused whether it is on or off, and it works inside tmux panes too"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Workspaces reworked: neutral cards where red means only that a host is unreachable, an open now tag on the workspace that is open, a single-workspace editor with an Add host row, an honest Replace with current layout caption, a trash icon on pane rows, All workspaces as its own list screen, and a sheet that sizes to its content"),
        ChangelogNote("curve25519-sha256 (the RFC name) is offered next to curve25519-sha256@libssh.org, and the encrypted-transport lock in the sidebar now shows for Mosh and ET too"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("The pop-out SFTP editor and detached terminal windows take input again on Windows (the multi-window plugin registered a second channel that swallowed the first)"),
        ChangelogNote("A Serial or Local Shell host no longer arrives on another device as an SSH connection to a nonsense address after sync"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "2.0.0",
    date: "September 22, 2026",
    tag: "Triggers, Command History, tmux and 12 Languages",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Triggers: watch terminal output for a pattern (regex, optional case sensitivity, one host or all) and get a notification, a sound, or a coloured highlight where it appears. Three ready-made examples for errors, warnings and finished builds, a live test line while you write the pattern, and a match count on every card. Free, and synced across your devices"),
        ChangelogNote("Command history: every command you run is recorded on this device with where and when it ran, plus exit code, duration and working directory when your shell reports them (OSC 133 / OSC 7). Searchable, grouped by day, repeats collapsed, and one click turns a past command into a snippet. Recording is opt-in per device, password prompts are never captured, secrets typed into a command are dropped, and the history syncs end-to-end encrypted", ChangelogTier.pro),
        ChangelogNote("tmux control mode: open a tmux session on any host from Ctrl+Shift+X, the command palette, the host menu, or by typing tmux -CC in the terminal, and its windows become tabs and its panes real panes inside the session tab. Copy and paste, split, zoom, rename, close and kill from a menu, a session picker that shows which sessions are idle or in use, session badges on host cards, and re-attach to anything you left running. Free"),
        ChangelogNote("12 languages: Spanish, French, German, Italian, Portuguese, Russian, Japanese, Korean, Chinese, Arabic and Hindi across every screen. System default follows your device and falls back to English"),
        ChangelogNote("What's new in the app: this changelog opens from Help and from Settings > About, and Report a bug opens the in-app form with your build info attached"),
        ChangelogNote("Setup guides: a ? button on Automation, Snippets and Server Monitor opens a guide for your OS in a side panel"),
        ChangelogNote("Desktop onboarding: Import from SSH config reads ~/.ssh/config for you and shows the hosts to pick, and Scan the local network and Restore from sync are proper dialogs instead of pushed screens"),
        ChangelogNote("Sign in with an email and password (with address confirmation), a copyable Account ID on your profile for support, and Redeem a code under Settings > Account"),
        ChangelogNote("The SFTP text editor pops out into its own window, and a per-host startup command or snippet runs the moment a session opens"),
        ChangelogNote("Host cards, your way: three sizes that share one height (just the icon, the icon and name, or the full card), a 50-icon catalog or your own uploaded image per host (synced), and a dashed New Connection tile at the end of the grid"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Settings rebuilt: one page with Appearance, Keyboard shortcuts (with a search box), Security (app lock, PIN, encrypt at rest, hardware-backed encryption, host keys) and Notifications as their own pages on desktop, a drill-down list on mobile, and an Account panel with one shape whether or not you are signed in"),
        ChangelogNote("Recording mode lives on the REC button in the top bar with a Layout or Strict level. Strict hides Command history entirely, Layout shows stand-in commands, and trigger names, patterns and snippet commands are masked as well"),
        ChangelogNote("The desktop rail is grouped into Manage and Utilities, Triggers and Command history are two-pane screens built on the same components as Snippets, and mobile has a Utilities tab"),
        ChangelogNote("Reorder hosts by dragging a card straight where you want it in Sort: Manual (the separate Arrange mode is gone), and Open tmux sits in the host context menu"),
        ChangelogNote("Regroup terminals by dragging: drop a pane onto another group's header to move it in, or onto empty header space to pop it out into its own group, and the panes you leave behind rebalance to fill the space"),
        ChangelogNote("Keep Screen Awake and Cursor Blink do what they say, copy on select is on by default, and jump-host routing on the free tier is enforced where the connection is made, with a one-time notice"),
        ChangelogNote("Wording aligned everywhere: Juiced is hosted ZestSSH Cloud storage, sync itself is free on every backend you run, and there are no subscriptions"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("macOS: Ctrl+Cmd+F toggles full screen, the top bar no longer leaves a dead gap where the traffic lights sit while full screen, and the title bar reserves the traffic-light zone in every layout"),
        ChangelogNote("Windows: the discrete-GPU forcing is off by default (the black-screen-on-resize workaround stays available), and the New Host dropdown opens the real editor"),
        ChangelogNote("The server's login banner, the notice many hosts show before you sign in, appears in the terminal ahead of the first prompt"),
        ChangelogNote("A hostile or broken host cannot make the tmux workspace allocate the app out of memory: pane sizes and reply blocks from the wire are bounded"),
        ChangelogNote("At the free-tier session limit, closing a session and opening another no longer makes you wait out the close delay: the one you closed frees its slot right away, and a session that is staying open is never touched"),
        ChangelogNote("Ctrl+W reaches the terminal again (nano's search, readline delete-word) instead of closing the tab; closing a tab moved to Ctrl+Shift+W"),
        ChangelogNote("Double-encoded characters in translations, the health-checks and paste toggles now working, the Rate-app link pointing at the real store listing, scrollback help stating the real default, wrapped commands recorded as one history entry, and the SFTP conflict dialog keeping its four choices on one row with a default that follows the operation"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.9.8",
    date: "September 10, 2026",
    tag: "SFTP Conflict Dialog",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The SFTP overwrite-conflict dialog is a cleaner fixed-width window: local and remote line up in one two-column compare so you can read them against each other, all four choices sit on one row with the full wording in their tooltips, and a long path wraps at its separators instead of truncating"),
        ChangelogNote("Folder sync remembers your Verify by content choice for each folder pair, so a folder you rebuild and redeploy keeps content checking on without re-ticking it, while your other folders stay on the faster size and date comparison"),
        ChangelogNote("Mobile: a Help button in the top bar on every tab opens Help and Support, so the Discord community, the FAQ, report a bug and email are all one tap away"),
        ChangelogNote("The Help panel marks its rows in colour: the Discord community in Discord's blurple, Report a bug in red and Suggest a feature in amber"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("When the remote file cannot be read, \"Replace if newer\" is turned off with the reason shown, since it cannot compare ages, and \"Keep both\" becomes the default so a single click never overwrites a file you cannot see"),
        ChangelogNote("Folder sync now warns you before a run when a server does not keep the timestamps ZestSSH sets, so unchanged files are being compared by size alone, and points you to Verify by content"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.9.7",
    date: "September 9, 2026",
    tag: "Help Panel, Recording Mode and In-App Reports",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Help panel: the ? button opens a docked panel beside the app with the most common questions first, then Report a bug, Suggest a feature and Get help, with the version and service status in its footer, in place of the old shortcuts list"),
        ChangelogNote("Report a bug and Suggest a feature from inside the app: a short form posts straight to the ZestSSH Discord forums, anonymous unless you type a Discord handle, with a preview of exactly what leaves your device. Only six facts ride along (app version, build, platform, OS version, language, plan), never logs, hosts or settings"),
        ChangelogNote("Recording mode: one switch hides host names, addresses, usernames, key names, saved-password labels, group, workspace and network names, SSIDs and fingerprints across the whole app for screenshots and screen shares, with Layout and Strict levels, Ctrl+Shift+R, and a reveal guard on anything that would show a real value"),
        ChangelogNote("Copy redacted screenshot puts a masked PNG of the whole window on the clipboard in one click, with a Save as PNG option, without turning recording mode on"),
        ChangelogNote("SFTP remembers the last folder you had open per host and reopens there, and the host default follows you to other devices through Cloud Sync"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The command palette shows every action's current key binding on its row, and keyboard shortcuts now live in Settings where they can be changed"),
        ChangelogNote("Get help points to a private Discord ticket or email; the address is shown with a copy button rather than a bare mail link"),
        ChangelogNote("Tab and Shift+Tab now walk every form, multi-line fields included; the file editor keeps Tab for indenting"),
        ChangelogNote("Screenshots attached to a bug report are redacted by default, and a report that cannot be sent waits inside the encrypted database until the next launch delivers it"),
        ChangelogNote("Sending a report needs no account; a signed in account is used only for rate limiting and is never shown in Discord"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("A local delete that the Recycle Bin or Trash cannot take (a network drive, a disabled bin, an oversized folder) now asks before deleting permanently instead of doing it silently"),
        ChangelogNote("Restored tabs, saved workspaces and the folder-pin counters now live inside the encrypted database instead of plain preferences"),
        ChangelogNote("Windows 11 clipboard history (Win+V) now pastes into the SFTP editor and every other text field; the flyout injects a keypress without a scan code, which the app now repairs before Flutter sees it"),
        ChangelogNote("Row hover no longer paints the theme's text colour as a fill on Dracula, Monokai and similar themes"),
        ChangelogNote("Testing a connection to an already trusted host no longer refuses its host key"),
        ChangelogNote("Documentation links open docs.zestssh.com instead of a dead page on the main site"),
        ChangelogNote("Reopening SFTP no longer falls back to the home directory when the remembered folder was deleted on the server: it walks up to the nearest parent that still exists and says so"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.9.6",
    date: "September 9, 2026",
    tag: "Sync Folder to Server",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("New \"Sync folder to server\": pick a local folder and push only what changed. A preview shows exactly what will upload, what is new, what is skipped, and what exists only on the server, all before anything moves, and there are no per file prompts"),
        ChangelogNote("\"Verify by content\" compares the actual file contents rather than the timestamp, so a file you edited locally and upload weeks later is still detected as changed and sent"),
        ChangelogNote("\"Preview only\" dry run shows everything a sync would do without sending a single file"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Re-syncing an unchanged folder is now near instant: identical files are recognised from a local record of the last upload, and the server is listed one folder at a time instead of one file at a time"),
        ChangelogNote("Deleting files that exist only on the server is opt in, listed by name, runs last after every upload succeeds, and honours the undo window"),
        ChangelogNote("Servers that do not allow setting file timestamps are handled: the app tells you once and compares by size, instead of silently re-uploading the whole folder every time"),
        ChangelogNote("Accented filenames are matched correctly across macOS and Linux, plus a \"Force re-upload everything\" option for when you suspect a bad earlier upload"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("\"Replace only when local is newer\" no longer silently skips a file that changed but has an older timestamp: those files are counted and you can send them in one tap"),
        ChangelogNote("The overwrite conflict counter now shows the real number of files that differ, so re-syncing a large folder with a few changes no longer reads like a huge conflict"),
        ChangelogNote("Case colliding names on the server, like README.md and readme.md in one folder, are detected and skipped with a clear warning instead of overwriting one with the other"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.9.3",
    date: "September 9, 2026",
    tag: "Incremental SFTP Transfers",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Incremental SFTP transfers: files already identical on the other side (same size and time) are skipped, so re-sending a folder copies only the new or changed files instead of everything"),
        ChangelogNote("New \"Replace if newer\" option when a file already exists, alongside Replace, Skip and Keep both"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Deleting files now shows a progress dialog while they move to the trash, instead of sitting on a blank pause"),
        ChangelogNote("Recording mode masks more of the app now: host addresses, usernames and key fingerprints on host cards, the session bar and the keys screen"),
        ChangelogNote("Recording mode is clearer about what it is: it hides identifiers in the app's own screens, it does not record the screen, and the terminal is never masked because its text comes from the server"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed the overwrite counter that could show a wrong total such as \"11 of 6\" when a folder held nested conflicts, it now counts the real number as it finds them"),
        ChangelogNote("The Hosts page now keeps the group you filtered by when you open a host and come back, instead of resetting to All every time"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.9.1",
    date: "September 8, 2026",
    tag: "Theme Designer and Recording Mode",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("New Theme Designer: one place for your app chrome and your terminal colours, with a live preview that updates as you edit"),
        ChangelogNote("Start from any built-in theme, tweak it, and save it as your own, then overwrite or delete your custom themes whenever you like"),
        ChangelogNote("Import terminal colour schemes straight from iTerm2, Windows Terminal, or xrdb"),
        ChangelogNote("Recording mode: swap real host addresses and usernames for stable fake values while screen sharing, with a REC badge across the top"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Match terminal to app theme: pick one theme and the whole app follows, or keep the two independent"),
        ChangelogNote("The designer warns on low contrast or clashing colours and blocks a save that would hide a border"),
        ChangelogNote("Auto lock is now configurable, 10 minutes on desktop and 1 minute on mobile by default, the desktop lock screen is wider, and settings search is bigger with a clear button"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Windows Hello now works on the desktop lock screen, it never opened before on PIN only Hello setups"),
        ChangelogNote("Fixed a lockout where Windows Hello could wedge the desktop lock screen with no way back to the PIN"),
        ChangelogNote("Fixed the file editor asking to save again after you only moved the cursor"),
        ChangelogNote("Fixed workspace chips and settings accents not following the active theme"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.9.0",
    date: "September 3, 2026",
    tag: "Smooth Transfers, Faster Uploads, Mobile Notifications",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("A two factor prompt from a jump host or serial connection is no longer answered with your account password, which could have placed it in the server log"),
        ChangelogNote("Fixed a mid session key renegotiation that could interrupt transfers larger than about 1 GB"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Mobile notifications: a home screen bell with a severity badge, a grouped history screen with swipe to dismiss, and a dedicated notifications settings screen"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Uploading a large folder no longer freezes the app, the transfer list and Activity panel stay responsive even with tens of thousands of files queued"),
        ChangelogNote("Much faster transfers on a local network, uploads now run at full link speed instead of stalling to a crawl"),
        ChangelogNote("A large upload no longer makes the rest of the app lag while it runs"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed a UI freeze when uploading a folder with very many small files"),
        ChangelogNote("Fixed slow transfer speed caused by the connection holding back small packets"),
        ChangelogNote("Fixed the per connection log growing without bound during a long session"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.8.2",
    date: "September 2, 2026",
    tag: "Faster SFTP and Multi-Host Host-Key Prompts",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Faster SFTP uploads, and the app stays responsive while a large transfer runs"),
        ChangelogNote("The Database Error screen is redesigned as a clear card, with Reset marked as a last resort so it is not tapped by accident"),
        ChangelogNote("The Windows installer now shows a license agreement and reads correctly in dark theme"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Connecting to several new hosts at once now asks you to verify each host key in turn, instead of only one prompting while the other sessions hang"),
        ChangelogNote("An SFTP upload the server rejects now fails cleanly instead of hanging"),
        ChangelogNote("Hardened SSH channel cleanup and flow control so an unexpected disconnect or a malformed server can no longer leak resources or spin the client"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.8.1",
    date: "September 1, 2026",
    tag: "Desktop Freeze Fix",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed a desktop freeze where the app could stop responding to the mouse after a long idle, for example overnight: the cursor could stick and clicks did nothing while the app kept running. Moving a window no longer risks it, and Alt+Tab away and back recovers input if it ever happens"),
        ChangelogNote("The command palette shortcut now closes the palette if it is already open, instead of stacking another copy and dimming the screen"),
        ChangelogNote("Cloud Sync no longer hangs on a dead connection after a long idle: network requests now time out and the next sync retries cleanly"),
        ChangelogNote("Mobile Server Monitor: hosts that are actually reporting no longer show Can't check, and the CPU, RAM, and Disk bars show their severity colors again"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.8.0",
    date: "August 31, 2026",
    tag: "Encrypt at Rest, Hardware Binding, and a Cleaner App",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Encrypt data at rest: your saved connections and keys are scrambled behind your PIN, so a lost or stolen device cannot read them. Opt in under Settings, Security"),
        ChangelogNote("Hardware-backed encryption on mobile ties the key to your device secure hardware, so unlocking adds a device-authentication step and a copied data file is useless off the device"),
        ChangelogNote("On Windows, hardware-backed encryption binds the key to the PC TPM, so the encrypted data is useless if the files are copied to another computer"),
        ChangelogNote("A dedicated Security screen gathers app lock, PIN, data-at-rest encryption, hardware binding, and host-key trust in one place"),
        ChangelogNote("Server Monitor moved to the Home tab and the Sessions bar, so it is one tap away instead of buried in Settings"),
        ChangelogNote("Auto Backup now sets its schedule and its location together, including an optional WebDAV or Nextcloud copy"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Settings is reorganised: Import and Export are each a single chooser, backup lives with your account, and SFTP behavior has its own section"),
        ChangelogNote("You can export a backup with no password after a clear confirmation, for a quick local copy"),
        ChangelogNote("The PIN can be up to 32 digits, and changing or turning off the PIN now asks for your current one first"),
        ChangelogNote("A WebDAV backup password is now stored in the device secure store, never in plain settings"),
        ChangelogNote("Additional security hardening across the desktop encryption paths"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Connecting to the same server address through different jump hosts no longer warns that the host key changed"),
        ChangelogNote("Your connection tags now sync across devices"),
        ChangelogNote("Importing a PuTTY key from Settings now actually loads the key instead of opening a blank screen"),
        ChangelogNote("The SFTP browser right-click menu now appears in an empty folder so you can create a file or folder"),
        ChangelogNote("Turning a setting on or off no longer fails when the app is locked"),
        ChangelogNote("A flapping host no longer sends the same critical alert over and over"),
        ChangelogNote("Mute a noisy notification type straight from the notification panel"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.7.4",
    date: "August 26, 2026",
    tag: "Ligatures, Tray Health, and Settings Sync",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Programming ligatures in the terminal: FiraCode, Cascadia Code, and JetBrains Mono render coding symbols like arrows and comparison operators as their combined glyphs, switched on under Settings"),
        ChangelogNote("The desktop tray shows your monitored hosts at a glance, tints its icon when one goes critical, and lets you connect to a specific host straight from its menu"),
        ChangelogNote("Your terminal look and connection defaults now sync across your devices"),
        ChangelogNote("A local shell tab on desktop opens PowerShell on Windows or your login shell on macOS and Linux"),
        ChangelogNote("The server monitor raises an in-app alert when a monitored host turns critical, warning, or offline"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Find in the terminal now supports whole-word matching"),
        ChangelogNote("Snippet variables can be masked so a secret stays hidden while you type it"),
        ChangelogNote("Identity keys show a reminder when an attached certificate is expiring soon or has expired"),
        ChangelogNote("The terminal scrollback size is now honored and can be set to unlimited"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("The terminal bell now respects the enable and disable setting"),
        ChangelogNote("An active local port forward gets an open-in-browser button on desktop"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.7.3",
    date: "August 21, 2026",
    tag: "Stability, Live Monitoring, and Theming",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Tap a monitored host on your phone to see its live CPU, memory, disk, and network graphs"),
        ChangelogNote("Long-press a snippet folder on mobile to rename it or change its color"),
        ChangelogNote("Crop, zoom, and rotate your profile photo when you set an avatar"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Themes now recolor the accent everywhere: pick a color and the buttons, highlights, and even the upgrade screen follow it"),
        ChangelogNote("The identity editor now matches the connection editor, so every screen reads as one design"),
        ChangelogNote("Save a terminal transcript as encrypted or plain text and choose exactly where it goes, with a Show in folder shortcut on desktop"),
        ChangelogNote("The network editor no longer pops the keyboard open the moment you open it on mobile"),
        ChangelogNote("The desktop snippet picker now colours each category, matching the mobile snippet list"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed a launch crash that hit every earlier 1.7 build on Android, caused by a camera library version mismatch in the QR scanner"),
        ChangelogNote("Opening a file to edit during an SFTP transfer no longer freezes the app, transfers now run on their own channel"),
        ChangelogNote("The Linux build now opens its database on launch instead of coming up empty"),
        ChangelogNote("WebDAV and Nextcloud cloud sync no longer gets stuck after the first sync, so your changes reach your other devices again"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.7.2",
    date: "August 20, 2026",
    tag: "Unlimited Connections & Host Sorting",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Unlimited saved connections on every tier: the free tier is no longer capped, so you can save as many hosts as you want"),
        ChangelogNote("Right-click any host group header, including Ungrouped, to sort by name, status, or most recent"),
        ChangelogNote("Drag the subtle dividers in the SFTP file header to resize the Name, Size, and Modified columns"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Open terminal here now reuses your active session and opens a tab at that folder, instead of popping out a new window"),
        ChangelogNote("The choose a host list, shown when you open SFTP with no session running, now sorts and stays in sync with your home screen order"),
        ChangelogNote("The update prompt is a desktop feature now, since mobile updates come from the app stores"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Cancel in the SFTP replace prompt now stops the whole transfer instead of asking again for the very next file"),
        ChangelogNote("The apply to the rest of the conflicts option in that prompt is no longer greyed out when a folder has several clashes"),
        ChangelogNote("Duplicate on the hosts screen now works on desktop, it was silently blocked before"),
        ChangelogNote("The About page no longer runs off the edge of the screen on phones"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.7.1",
    date: "August 20, 2026",
    tag: "macOS & Delete Polish",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("The delete countdown is now off by default, so deletes are immediate unless you switch the safety delay on in settings"),
        ChangelogNote("Save a connection straight from an active session in a filled-in editor, without leaving the terminal"),
        ChangelogNote("Clearer keyboard navigation in the connection editor, with focus rings on menus and arrow-key protocol selection"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("macOS launch and database fixes so the desktop app starts cleanly on Mac, with its proper app icon"),
        ChangelogNote("macOS now uses the native window controls at the top-left, like every other Mac app"),
        ChangelogNote("Deleting a large folder over SFTP is quicker and shows accurate progress"),
        ChangelogNote("The title bar no longer maximizes on an accidental double-click"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.7.0",
    date: "August 20, 2026",
    tag: "SFTP Redesign & Safe Delete Sync",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Hardened every path that handles data from a remote server, so a hostile or compromised server cannot crash the app, from a pre-release adversarial security review"),
        ChangelogNote("The open-source SSH engine ships with SFTP reliability and elliptic-curve correctness fixes"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("A redesigned SFTP file manager on desktop: two panes side by side, a bookmarks sidebar, drag between panes, and a live file filter"),
        ChangelogNote("In-app image preview: double-click an image on a server to view it with zoom, no download needed"),
        ChangelogNote("Tail a log file live over SFTP, straight in the app"),
        ChangelogNote("Generate SSH certificates inside the app"),
        ChangelogNote("Serial console support"),
        ChangelogNote("Pin your favorite hosts to the top"),
        ChangelogNote("Export and import your themes"),
        ChangelogNote("The SSH engine behind ZestSSH is now open source (zest_ssh_core, MIT licensed)"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Cloud sync now removes deleted items everywhere: delete a host on one device and it is gone on the others, with newest change wins so an edit and a delete resolve correctly", ChangelogTier.sync),
        ChangelogNote("A long-offline device reconciles with the cloud instead of bringing back things you deleted", ChangelogTier.sync),
        ChangelogNote("Transfer selection: before a big upload or download, exclude heavy folders like node_modules and .git with one click"),
        ChangelogNote("Delete safety: a remote file delete is held with a countdown and an Undo, so an accidental big-folder delete can be taken back before anything is sent"),
        ChangelogNote("Same-host SFTP moves are instant, with a 10 second undo"),
        ChangelogNote("Cleaner right-click menus for pins and bookmarks"),
        ChangelogNote("Server latency now reads correctly for fast local servers (it used to show 0 ms)"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed a slow resource buildup over very long sessions with monitored servers"),
        ChangelogNote("A batch of field-test fixes across connecting, app lock, local shell, and sync"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.6.0-1.6.2",
    date: "August 15, 2026",
    tag: "Server Monitor & Networks",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("More security hardening behind the scenes"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Server Monitor, see your servers' health live: CPU, memory, disk, network and temperature, with alerts when something needs attention"),
        ChangelogNote("Networks, ZestSSH now knows which network you're on and connects the right way automatically, whether you're home, at work, or on the go"),
        ChangelogNote("Color-code your connections, groups, keys, snippets and networks"),
        ChangelogNote("Make it yours, pick your own accent colors for the app and the terminal"),
        ChangelogNote("Organize your snippets into color-coded categories"),
        ChangelogNote("A cleaner Automation section with Workflows, Runs and Triggers"),
        ChangelogNote("ZestSSH now warns you when two keys are really the same"),
        ChangelogNote("Command palette and Workspaces improvements on desktop"),
        ChangelogNote("A fresh, cleaner setup installer"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("A warmer new look with better contrast across the whole app"),
        ChangelogNote("Redesigned connection editor with a live preview as you type"),
        ChangelogNote("New connection card sizes, plus pinning and notes"),
        ChangelogNote("Custom colors and icons for your folders, with faster editing"),
        ChangelogNote("Redesigned Profile & Sync that shows your real synced devices"),
        ChangelogNote("Clearer, friendlier error messages when something goes wrong"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed a desktop sign-in error"),
        ChangelogNote("Fixed missing stats in Server Monitor"),
        ChangelogNote("Fixed hosts sometimes showing as unreachable, plus assorted layout glitches"),
        ChangelogNote("Polished colors and contrast across the app"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.41",
    date: "August 5, 2026",
    tag: "Bring-your-own sync",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Sync key derivation strengthened to Argon2id with a 128 MB memory cost"),
        ChangelogNote("End-to-end encryption (Argon2id + AES-256-GCM) applies to every backend", ChangelogTier.sync),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Bring-your-own sync backends, Juiced sync now runs on your own WebDAV, S3, or Google Drive, not just hosted ZestSSH Cloud", ChangelogTier.sync),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.36-1.5.40",
    date: "July 27, 2026",
    tag: "Reliability",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Connection inspector redesigned"),
        ChangelogNote("Reorder keys within an identity"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed copying text out of the terminal"),
        ChangelogNote("More reliable file transfers"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.35",
    date: "July 23, 2026",
    tag: "Security",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Security hardening pass across the app"),
        ChangelogNote("Regression fixes surfaced by an adversarial security review"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.29-1.5.34",
    date: "July 23, 2026",
    tag: "Desktop",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Hardened SSH core crypto, host-key verification, and background services"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Docked connection inspector on the desktop"),
        ChangelogNote("Frameless title bar on Windows"),
        ChangelogNote("Branded dark installer wizard with an optional \"Add to PATH\" step"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Desktop UI polish, theme safety net and host-card hover states"),
        ChangelogNote("Toast-style exit confirmation"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.24-1.5.26",
    date: "July 7, 2026",
    tag: "Cloud Sync",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("End-to-end encrypted cloud sync now works end to end, automatic push/pull with a join-existing-vault flow", ChangelogTier.sync),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Memory-safe SFTP for large file transfers"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Fixed vim arrow keys (DECCKM cursor-key mode)"),
        ChangelogNote("Fixed trackpad scrolling"),
        ChangelogNote("Cloud sync reliability fixes", ChangelogTier.sync),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.17-1.5.23",
    date: "June 23, 2026",
    tag: "Terminal & Panes",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Split-pane terminal with independent focus and sizing"),
        ChangelogNote("Broadcast, type once and mirror your keystrokes to a whole group of sessions"),
        ChangelogNote("Workspaces, save a layout of terminal tabs and panes and reopen it later"),
        ChangelogNote("Per-group colors and tier chips"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("SFTP type-ahead in the file browser"),
        ChangelogNote("Drag-select auto-scrolls into the scrollback"),
        ChangelogNote("Wheel-scroll extends the current selection"),
        ChangelogNote("A clean shell exit now closes its tab"),
        ChangelogNote("Broadcast is scoped to the active group"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Normalized CRLF on terminal paste, fixes double-spaced pastes"),
        ChangelogNote("Terminal hotkey gating so app shortcuts no longer leak into the shell"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.14-1.5.15",
    date: "June 9, 2026",
    tag: "Rollup",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("Purchase identity protection, keeps lifetime purchases from being stranded on anonymous accounts"),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("SFTP file browser improvements"),
        ChangelogNote("QR-code connection sharing"),
        ChangelogNote("Entitlement handling improvements"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Stability and polish fixes across the app"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.5.0",
    date: "May 16, 2026",
    tag: "zest_ssh_core",
    sections: [
      ChangelogSection(ChangelogCategory.security, [
        ChangelogNote("zest_ssh_core shipped after a 12-finding security audit, all fixed"),
        ChangelogNote("A follow-up audit fixed 4 more findings"),
      ]),
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("New zest_ssh_core engine, a proprietary SSH stack that replaces the old library, with ChaCha20-Poly1305, Ed448, host-key verification, rekeying, and compression (later open-sourced as MIT in 1.7.0)"),
        ChangelogNote("OpenSSH user certificates, import a certificate and attach it to an identity (including FIDO/sk certificate types)"),
        ChangelogNote("Hardware tokens, authenticate with a YubiKey or FIDO2 security key through the system ssh-agent"),
        ChangelogNote("Networks, context-aware connection profiles that rewrite a host's address, port, jump chain, identity, and port-forward rules based on the Wi-Fi, subnet, or cellular network you are on"),
        ChangelogNote("Desktop V3 redesign, pill bar, sidebar, and a responsive host grid with three layout modes"),
        ChangelogNote("Editable keyboard shortcuts, 23 rebindable actions with conflict detection"),
        ChangelogNote("Theme designer with a full HSV color picker"),
        ChangelogNote("IntelliJ-style notification center replaces snackbars on the desktop"),
        ChangelogNote("Connection groups, tags, and pinned hosts"),
        ChangelogNote("Host card customization, density, columns, and accent colors"),
        ChangelogNote("Scheduler, backup destinations, and SSH agent forwarding"),
        ChangelogNote("Network-aware port forwarding, per-network forward rules", ChangelogTier.pro),
      ]),
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Recursive jump-host chains, A → B → C now routes all the way through C"),
        ChangelogNote("macOS builds are no longer sandboxed, so ZestSSH can read ~/.ssh"),
        ChangelogNote("File-based logging removed entirely, nothing is written to disk"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.4.3",
    date: "April 22, 2026",
    tag: "Hotfix",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("In-app help dialogs for Port Forwarding and Jump Host screens"),
        ChangelogNote("Launch on Windows startup option in the installer"),
        ChangelogNote("Windows installer dark theme with ZestSSH branding"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("macOS database error, SQLCipher library was not loading on Mac"),
        ChangelogNote("zestssh:// URL scheme now registered on Windows for OAuth and automation"),
        ChangelogNote("Removed unnecessary build artifacts from the installer"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.4.2",
    date: "April 21, 2026",
    tag: "Hotfix",
    sections: [
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Desktop sign-in getting stuck, browser OAuth now works on Windows, Mac, and Linux"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.4.1",
    date: "April 20, 2026",
    tag: "Hotfix",
    sections: [
      ChangelogSection(ChangelogCategory.improvements, [
        ChangelogNote("Database upgraded to schema v8"),
      ]),
      ChangelogSection(ChangelogCategory.fixes, [
        ChangelogNote("Automation history now persists, survives app restarts, stores up to 500 entries"),
        ChangelogNote("Workflows now save to the database instead of temporary storage"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.4.0",
    date: "April 19, 2026",
    tag: "Automation & Workflows",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("Automation Engine, control ZestSSH from Tasker, MacroDroid, iOS Shortcuts, and Siri", ChangelogTier.pro),
        ChangelogNote("Automation Wizard, step-by-step URL builder"),
        ChangelogNote("Workflows, multi-step server automation chains", ChangelogTier.pro),
        ChangelogNote("API key authentication with multi-key management, expiration, and rate limiting"),
        ChangelogNote("Batch execution across multiple servers"),
        ChangelogNote("Snippet variables from external apps"),
        ChangelogNote("Output filters (grep, head, tail)"),
        ChangelogNote("Webhook callbacks"),
        ChangelogNote("Clickable URLs in the terminal"),
        ChangelogNote("Smooth scrolling with scroll-to-bottom button"),
        ChangelogNote("Split terminal for tablets and foldables", ChangelogTier.pro),
        ChangelogNote("Cursor shape picker (block, underline, vertical bar)"),
        ChangelogNote("Android foreground service, SSH stays alive when backgrounded"),
        ChangelogNote("Auto-backup on change with a user-chosen password"),
        ChangelogNote("Windows and macOS desktop support"),
      ]),
    ],
  ),
  ChangelogEntry(
    version: "1.0.0",
    date: "March 2026",
    tag: "Initial Release",
    sections: [
      ChangelogSection(ChangelogCategory.features, [
        ChangelogNote("SSH, Telnet, Mosh, and local shell connections"),
        ChangelogNote("Full xterm-compatible terminal emulator"),
        ChangelogNote("SSH key generation: Ed25519, RSA, ECDSA"),
        ChangelogNote("Import OpenSSH PEM and PuTTY .ppk key files"),
        ChangelogNote("49 built-in command snippets"),
        ChangelogNote("7 terminal themes (Dark, Light, AMOLED, Solarized, Monokai, Dracula, Nord)"),
        ChangelogNote("App lock with a PIN, face or fingerprint"),
        ChangelogNote("SFTP file browser"),
        ChangelogNote("Local and remote port forwarding", ChangelogTier.pro),
        ChangelogNote("Jump host / bastion support", ChangelogTier.pro),
        ChangelogNote("Session transcripts", ChangelogTier.pro),
        ChangelogNote("Home screen widgets", ChangelogTier.pro),
        ChangelogNote("Speech-to-text input", ChangelogTier.pro),
        ChangelogNote("End-to-end encrypted sync", ChangelogTier.sync),
        ChangelogNote("Vault across devices", ChangelogTier.sync),
        ChangelogNote("Automatic encrypted backups", ChangelogTier.sync),
      ]),
    ],
  ),
];
