import 'package:flutter/foundation.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The computer the app runs on, named for its own files as its system names
/// it: This PC on Windows, This Mac on a Mac, This computer on Linux (it said
/// This PC on all three).
String thisComputerName(AppLocalizations l10n) => switch (defaultTargetPlatform) {
      TargetPlatform.macOS => l10n.sftpThisMac,
      TargetPlatform.linux => l10n.sftpThisComputer,
      _ => l10n.sftpThisPc,
    };

/// Where the computer's system puts what is deleted: the Recycle Bin on
/// Windows, the Trash on a Mac and on Linux (Linux was told the Recycle Bin).
String thisComputerBinName(AppLocalizations l10n) =>
    defaultTargetPlatform == TargetPlatform.windows ? l10n.sftpBinRecycleBin : l10n.sftpBinTrash;
