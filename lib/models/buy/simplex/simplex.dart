import 'package:decimal/decimal.dart';
import 'package:stackwallet/models/buy/response_objects/crypto.dart';
import 'package:stackwallet/models/buy/response_objects/fiat.dart';
import 'package:stackwallet/models/buy/response_objects/order.dart';
import 'package:stackwallet/models/buy/response_objects/quote.dart';

class Simplex {
  List<Crypto> supportedCryptos = [];
  List<Fiat> supportedFiats = [];
  SimplexQuote quote = SimplexQuote(
    crypto: Crypto.fromJson({'ticker': 'BTC', 'name': 'Bitcoin', 'image': ''}),
    fiat: Fiat.fromJson(
        {'ticker': 'USD', 'name': 'United States Dollar', 'image': ''}),
    youPayFiatPrice: Decimal.parse("100"),
    youReceiveCryptoAmount: Decimal.parse("1.0238917"),
    id: "someID",
    receivingAddress: '',
    buyWithFiat: true,
  );
  SimplexOrder order = SimplexOrder(
      quote: SimplexQuote(
        crypto:
            Crypto.fromJson({'ticker': 'BTC', 'name': 'Bitcoin', 'image': ''}),
        fiat: Fiat.fromJson(
            {'ticker': 'USD', 'name': 'United States Dollar', 'image': ''}),
        youPayFiatPrice: Decimal.parse("100"),
        youReceiveCryptoAmount: Decimal.parse("1.0238917"),
        id: "someID",
        receivingAddress: '',
        buyWithFiat: true,
      ),
      orderId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      paymentId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      userId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');

  void updateSupportedCryptos(List<Crypto> newCryptos) {
    supportedCryptos = newCryptos;
  }

  void updateSupportedFiats(List<Fiat> newFiats) {
    supportedFiats = newFiats;
  }

  void updateQuote(SimplexQuote newQuote) {
    quote = newQuote;
  }

  void updateOrder(SimplexOrder newOrder) {
    order = newOrder;
  }
}
