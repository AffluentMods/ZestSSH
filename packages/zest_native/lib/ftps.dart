/// FTPS for ZestSSH (3.4): FTP over TLS through the native library (suppaftp with rustls).
/// Plain FTP is never spoken.
library;

export 'src/ftps.dart'
    show
        FtpsCertificate,
        FtpsClient,
        FtpsConnectOptions,
        FtpsEntry,
        FtpsErrorKind,
        FtpsException,
        FtpsFeatures,
        FtpsNative,
        FtpsTrust,
        RustFtpsNative;
