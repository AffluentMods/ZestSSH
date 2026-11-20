// Ask Astryx (4.0) where it is not offered: an iPhone or iPad whose App Store account is in mainland
// China. An AI chat service offered there needs a filing with the Cyberspace Administration of
// China, which Ask Astryx does not have, and the model it asks is not offered there.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show Purchases;

/// Whether Ask Astryx is offered to an App Store account of [storeCountry] (StoreKit's
/// storefront: ISO 3166-1, three letters, as CHN; two taken too). Null (not an App Store
/// device, or not known): offered.
bool assistantOfferedIn(String? storeCountry) {
  final c = storeCountry?.trim().toUpperCase();
  return c != 'CHN' && c != 'CN';
}

/// The App Store account's country on an iPhone or iPad (its storefront, through RevenueCat);
/// null on every other device and where it cannot be told.
Future<String?> appStoreCountry() async {
  if (kIsWeb || !Platform.isIOS) return null;
  try {
    return (await Purchases.storefront)?.countryCode;
  } catch (_) {
    return null;
  }
}

final appStoreCountryProvider = FutureProvider<String?>((ref) => appStoreCountry());

/// Whether Ask Astryx is offered on this device ([assistantOfferedIn]); its rows and its command
/// are left out where it is not.
final assistantOfferedHereProvider =
    FutureProvider<bool>((ref) async => assistantOfferedIn(await ref.watch(appStoreCountryProvider.future)));
