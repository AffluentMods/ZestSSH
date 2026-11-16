/// The names of the SSH protocol that have an at sign in them, as the
/// protocol has them. What is no standard's own (an algorithm, a kind of
/// key, a request, a channel, an extension) is named by whoever made it,
/// with their domain after an at sign (RFC 4251, 6). Each reads like a user
/// at a host and is none.
///
/// What masks text for a report or for recording mode leaves these as they
/// are ([Redactor.line]). Only the names that are written here: whatever
/// else stands before and after an at sign is taken for a user at a host.
/// Every name that the SSH core has in its code is here (a test reads them
/// from it), and with them the names of OpenSSH that a server may offer and
/// this app does not have, so that they can be read where a report says
/// what a server offers.
const Set<String> sshNamesWithAnAtSign = {
  // Key exchanges, and the two marks of the strict exchange.
  'curve25519-sha256@libssh.org',
  'sntrup761x25519-sha512@openssh.com',
  'kex-strict-c-v00@openssh.com',
  'kex-strict-s-v00@openssh.com',
  // Ciphers.
  'chacha20-poly1305@openssh.com',
  'aes128-gcm@openssh.com',
  'aes256-gcm@openssh.com',
  'rijndael-cbc@lysator.liu.se',
  // MACs.
  'hmac-sha2-256-etm@openssh.com',
  'hmac-sha2-512-etm@openssh.com',
  'hmac-sha1-etm@openssh.com',
  'hmac-sha1-96-etm@openssh.com',
  'hmac-md5-etm@openssh.com',
  'hmac-md5-96-etm@openssh.com',
  'hmac-ripemd160@openssh.com',
  'hmac-ripemd160-etm@openssh.com',
  'umac-64@openssh.com',
  'umac-128@openssh.com',
  'umac-64-etm@openssh.com',
  'umac-128-etm@openssh.com',
  // Kinds of key and of signature.
  'ssh-ed25519-cert-v01@openssh.com',
  'ssh-rsa-cert-v01@openssh.com',
  'rsa-sha2-256-cert-v01@openssh.com',
  'rsa-sha2-512-cert-v01@openssh.com',
  'ssh-dss-cert-v01@openssh.com',
  'ecdsa-sha2-nistp256-cert-v01@openssh.com',
  'ecdsa-sha2-nistp384-cert-v01@openssh.com',
  'ecdsa-sha2-nistp521-cert-v01@openssh.com',
  'sk-ssh-ed25519@openssh.com',
  'sk-ssh-ed25519-cert-v01@openssh.com',
  'sk-ecdsa-sha2-nistp256@openssh.com',
  'sk-ecdsa-sha2-nistp256-cert-v01@openssh.com',
  'webauthn-sk-ecdsa-sha2-nistp256@openssh.com',
  // Compression.
  'zlib@openssh.com',
  // Requests, channels and extensions of a connection.
  'keepalive@openssh.com',
  'no-more-sessions@openssh.com',
  'hostkeys-00@openssh.com',
  'hostkeys-prove-00@openssh.com',
  'auth-agent-req@openssh.com',
  'auth-agent@openssh.com',
  'eow@openssh.com',
  'tun@openssh.com',
  'direct-streamlocal@openssh.com',
  'forwarded-streamlocal@openssh.com',
  'streamlocal-forward@openssh.com',
  'cancel-streamlocal-forward@openssh.com',
  'publickey-hostbound-v00@openssh.com',
  'ping@openssh.com',
  // Extensions of SFTP.
  'posix-rename@openssh.com',
  'statvfs@openssh.com',
  'fstatvfs@openssh.com',
  'hardlink@openssh.com',
  'fsync@openssh.com',
  'lsetstat@openssh.com',
  'limits@openssh.com',
  'expand-path@openssh.com',
  'users-groups-by-id@openssh.com',
};
