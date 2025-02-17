// import 'package:flutter_riverpod/flutter_riverpod.dart';
// import 'package:stackwallet/providers/providers.dart';
// import 'package:stackwallet/services/buy/simplex/simplex_api.dart';
// import 'package:stackwallet/utilities/logger.dart';
//
// class BuyDataLoadingService {
//   Future<void> loadAll(WidgetRef ref) async {
//     try {
//       await Future.wait([
//         _loadSimplexCurrencies(ref),
//       ]);
//     } catch (e, s) {
//       Logging.instance.log("BuyDataLoadingService.loadAll failed: $e\n$s",
//           level: LogLevel.Error);
//     }
//   }
//
//   Future<void> _loadSimplexCurrencies(WidgetRef ref) async {
//     bool error = false;
//     // if (ref.read(simplexLoadStatusStateProvider.state).state ==
//     //     SimplexLoadStatus.loading) {
//     //   // already in progress so just
//     //   return;
//     // }
//
//     ref.read(simplexLoadStatusStateProvider.state).state =
//         SimplexLoadStatus.loading;
//
//     final response = await SimplexAPI.instance.getSupported();
//
//     if (response.value != null) {
//       ref
//           .read(supportedSimplexCurrenciesProvider)
//           .updateSupportedCryptos(response.value!.item1);
//     } else {
//       error = true;
//       Logging.instance.log(
//         "_loadSimplexCurrencies: $response",
//         level: LogLevel.Warning,
//       );
//     }
//
//     if (response.value != null) {
//       ref
//           .read(supportedSimplexCurrenciesProvider)
//           .updateSupportedFiats(response.value!.item2);
//     } else {
//       error = true;
//       Logging.instance.log(
//         "_loadSimplexCurrencies: $response",
//         level: LogLevel.Warning,
//       );
//     }
//
//     if (error) {
//       // _loadSimplexCurrencies() again?
//     } else {
//       ref.read(simplexLoadStatusStateProvider.state).state =
//           SimplexLoadStatus.success;
//     }
//   }
// }
