import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/help/guides/guide_repository.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Fetches guides from the docs site and keeps the copies for offline.
final guideRepositoryProvider = Provider<GuideRepository>((ref) => GuideRepository());

/// Whether a guide opens in the Help panel (a computer, where the panel sits
/// beside every page) or as a page of its own (a phone or a tablet).
final guidesInHelpPanelProvider = Provider<bool>((_) => desktopShellInUse);

/// What is typed in the guides' search box, kept while the app runs so that
/// Back from a guide finds the list as it was left.
final guidesQueryProvider = StateProvider<String>((_) => '');
