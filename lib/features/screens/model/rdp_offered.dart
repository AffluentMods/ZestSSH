import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app offers RDP as a kind of host (4.0): the host editor's
/// pill, and the imports' Remote Desktop entries and files.
///
/// True since a real Windows sign-in was seen (Windows
/// Server 2025 with Network Level Authentication, TLS 1.3, the graphics
/// pipeline and Display Control), the gate set for offering RDP
/// hosts. It stays a provider so that a test,
/// or a build that has to hide RDP again, can turn it off in one place. A
/// host that is an RDP host already keeps its pill and its section either
/// way, so it can be read and edited.
final rdpOfferedProvider = Provider<bool>((ref) => true);
