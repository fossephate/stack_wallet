import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:bitcoindart/bitcoindart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:lelantus/lelantus.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/electrumx_rpc/cached_electrumx.dart';
import 'package:stackwallet/electrumx_rpc/electrumx.dart';
import 'package:stackwallet/models/balance.dart';
import 'package:stackwallet/models/isar/models/isar_models.dart' as isar_models;
import 'package:stackwallet/models/lelantus_coin.dart';
import 'package:stackwallet/models/lelantus_fee_data.dart';
import 'package:stackwallet/models/paymint/fee_object_model.dart';
import 'package:stackwallet/models/signing_data.dart';
import 'package:stackwallet/services/coins/coin_service.dart';
import 'package:stackwallet/services/event_bus/events/global/node_connection_status_changed_event.dart';
import 'package:stackwallet/services/event_bus/events/global/refresh_percent_changed_event.dart';
import 'package:stackwallet/services/event_bus/events/global/updated_in_background_event.dart';
import 'package:stackwallet/services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'package:stackwallet/services/event_bus/global_event_bus.dart';
import 'package:stackwallet/services/mixins/firo_hive.dart';
import 'package:stackwallet/services/mixins/wallet_cache.dart';
import 'package:stackwallet/services/mixins/wallet_db.dart';
import 'package:stackwallet/services/mixins/xpubable.dart';
import 'package:stackwallet/services/node_service.dart';
import 'package:stackwallet/services/transaction_notification_tracker.dart';
import 'package:stackwallet/utilities/address_utils.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/bip32_utils.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/default_nodes.dart';
import 'package:stackwallet/utilities/enums/coin_enum.dart';
import 'package:stackwallet/utilities/enums/derive_path_type_enum.dart';
import 'package:stackwallet/utilities/enums/fee_rate_type_enum.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/utilities/format.dart';
import 'package:stackwallet/utilities/logger.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/widgets/crypto_notifications.dart';
import 'package:tuple/tuple.dart';
import 'package:uuid/uuid.dart';

const DUST_LIMIT = 1000;
const MINIMUM_CONFIRMATIONS = 1;
const MINT_LIMIT = 100100000000;
const int LELANTUS_VALUE_SPEND_LIMIT_PER_TRANSACTION = 5001 * 100000000;

const JMINT_INDEX = 5;
const MINT_INDEX = 2;
const TRANSACTION_LELANTUS = 8;
const ANONYMITY_SET_EMPTY_ID = 0;

const String GENESIS_HASH_MAINNET =
    "4381deb85b1b2c9843c222944b616d997516dcbd6a964e1eaf0def0830695233";
const String GENESIS_HASH_TESTNET =
    "aa22adcc12becaf436027ffe62a8fb21b234c58c23865291e5dc52cf53f64fca";

final firoNetwork = NetworkType(
    messagePrefix: '\x18Zcoin Signed Message:\n',
    bech32: 'bc',
    bip32: Bip32Type(public: 0x0488b21e, private: 0x0488ade4),
    pubKeyHash: 0x52,
    scriptHash: 0x07,
    wif: 0xd2);

final firoTestNetwork = NetworkType(
    messagePrefix: '\x18Zcoin Signed Message:\n',
    bech32: 'bc',
    bip32: Bip32Type(public: 0x043587cf, private: 0x04358394),
    pubKeyHash: 0x41,
    scriptHash: 0xb2,
    wif: 0xb9);

// isolate

Map<ReceivePort, Isolate> isolates = {};

Future<ReceivePort> getIsolate(Map<String, dynamic> arguments) async {
  ReceivePort receivePort =
      ReceivePort(); //port for isolate to receive messages.
  arguments['sendPort'] = receivePort.sendPort;
  Logging.instance
      .log("starting isolate ${arguments['function']}", level: LogLevel.Info);
  Isolate isolate = await Isolate.spawn(executeNative, arguments);
  Logging.instance.log("isolate spawned!", level: LogLevel.Info);
  isolates[receivePort] = isolate;
  return receivePort;
}

Future<void> executeNative(Map<String, dynamic> arguments) async {
  await Logging.instance.initInIsolate();
  final sendPort = arguments['sendPort'] as SendPort;
  final function = arguments['function'] as String;
  try {
    if (function == "createJoinSplit") {
      final spendAmount = arguments['spendAmount'] as int;
      final address = arguments['address'] as String;
      final subtractFeeFromAmount = arguments['subtractFeeFromAmount'] as bool;
      final mnemonic = arguments['mnemonic'] as String;
      final mnemonicPassphrase = arguments['mnemonicPassphrase'] as String;
      final index = arguments['index'] as int;
      final lelantusEntries =
          arguments['lelantusEntries'] as List<DartLelantusEntry>;
      final coin = arguments['coin'] as Coin;
      final network = arguments['network'] as NetworkType?;
      final locktime = arguments['locktime'] as int;
      final anonymitySets = arguments['_anonymity_sets'] as List<Map>?;
      if (!(network == null || anonymitySets == null)) {
        var joinSplit = await isolateCreateJoinSplitTransaction(
          spendAmount,
          address,
          subtractFeeFromAmount,
          mnemonic,
          mnemonicPassphrase,
          index,
          lelantusEntries,
          locktime,
          coin,
          network,
          anonymitySets,
        );
        sendPort.send(joinSplit);
        return;
      }
    } else if (function == "estimateJoinSplit") {
      final spendAmount = arguments['spendAmount'] as int;
      final subtractFeeFromAmount = arguments['subtractFeeFromAmount'] as bool?;
      final lelantusEntries =
          arguments['lelantusEntries'] as List<DartLelantusEntry>;
      final coin = arguments['coin'] as Coin;

      if (!(subtractFeeFromAmount == null)) {
        var feeData = await isolateEstimateJoinSplitFee(
            spendAmount, subtractFeeFromAmount, lelantusEntries, coin);
        sendPort.send(feeData);
        return;
      }
    } else if (function == "restore") {
      final latestSetId = arguments['latestSetId'] as int;
      final setDataMap = arguments['setDataMap'] as Map;
      final usedSerialNumbers = arguments['usedSerialNumbers'] as List<String>;
      final mnemonic = arguments['mnemonic'] as String;
      final mnemonicPassphrase = arguments['mnemonicPassphrase'] as String;
      final coin = arguments['coin'] as Coin;
      final network = arguments['network'] as NetworkType;

      final restoreData = await isolateRestore(
        mnemonic,
        mnemonicPassphrase,
        coin,
        latestSetId,
        setDataMap,
        usedSerialNumbers,
        network,
      );
      sendPort.send(restoreData);
      return;
    }

    Logging.instance.log(
        "Error Arguments for $function not formatted correctly",
        level: LogLevel.Fatal);
    sendPort.send("Error");
  } catch (e, s) {
    Logging.instance.log(
        "An error was thrown in this isolate $function: $e\n$s",
        level: LogLevel.Error);
    sendPort.send("Error");
  } finally {
    await Logging.instance.isar?.close();
  }
}

void stop(ReceivePort port) {
  Isolate? isolate = isolates.remove(port);
  if (isolate != null) {
    Logging.instance.log('Stopping Isolate...', level: LogLevel.Info);
    isolate.kill(priority: Isolate.immediate);
    isolate = null;
  }
}

Future<Map<String, dynamic>> isolateRestore(
  String mnemonic,
  String mnemonicPassphrase,
  Coin coin,
  int _latestSetId,
  Map<dynamic, dynamic> _setDataMap,
  List<String> _usedSerialNumbers,
  NetworkType network,
) async {
  List<int> jindexes = [];
  List<Map<dynamic, LelantusCoin>> lelantusCoins = [];

  final List<String> spendTxIds = [];
  var lastFoundIndex = 0;
  var currentIndex = 0;

  try {
    Set<String> usedSerialNumbersSet = _usedSerialNumbers.toSet();

    final root = await Bip32Utils.getBip32Root(
      mnemonic,
      mnemonicPassphrase,
      network,
    );
    while (currentIndex < lastFoundIndex + 50) {
      final _derivePath = constructDerivePath(
        networkWIF: network.wif,
        chain: MINT_INDEX,
        index: currentIndex,
      );
      final bip32.BIP32 mintKeyPair = await Bip32Utils.getBip32NodeFromRoot(
        root,
        _derivePath,
      );
      final String mintTag = CreateTag(
        Format.uint8listToString(mintKeyPair.privateKey!),
        currentIndex,
        Format.uint8listToString(mintKeyPair.identifier),
        isTestnet: coin == Coin.firoTestNet,
      );

      for (var setId = 1; setId <= _latestSetId; setId++) {
        final setData = _setDataMap[setId] as Map;
        final foundCoin = (setData["coins"] as List).firstWhere(
          (e) => e[1] == mintTag,
          orElse: () => <Object>[],
        );

        if (foundCoin.length == 4) {
          lastFoundIndex = currentIndex;

          final String publicCoin = foundCoin[0] as String;
          final String txId = foundCoin[3] as String;

          // this value will either be an int or a String
          final dynamic thirdValue = foundCoin[2];

          if (thirdValue is int) {
            final int amount = thirdValue;
            final String serialNumber = GetSerialNumber(
              amount,
              Format.uint8listToString(mintKeyPair.privateKey!),
              currentIndex,
              isTestnet: coin == Coin.firoTestNet,
            );
            final bool isUsed = usedSerialNumbersSet.contains(serialNumber);
            final duplicateCoin = lelantusCoins.firstWhere(
              (element) {
                final coin = element.values.first;
                return coin.txId == txId &&
                    coin.index == currentIndex &&
                    coin.anonymitySetId != setId;
              },
              orElse: () => {},
            );
            if (duplicateCoin.isNotEmpty) {
              Logging.instance.log(
                "Firo isolateRestore removing duplicate coin: $duplicateCoin",
                level: LogLevel.Info,
              );
              lelantusCoins.remove(duplicateCoin);
            }
            lelantusCoins.add({
              txId: LelantusCoin(
                currentIndex,
                amount,
                publicCoin,
                txId,
                setId,
                isUsed,
              )
            });
            Logging.instance.log(
              "amount $amount used $isUsed",
              level: LogLevel.Info,
            );
          } else if (thirdValue is String) {
            final int keyPath = GetAesKeyPath(publicCoin);
            final String derivePath = constructDerivePath(
              networkWIF: network.wif,
              chain: JMINT_INDEX,
              index: keyPath,
            );
            final aesKeyPair = await Bip32Utils.getBip32NodeFromRoot(
              root,
              derivePath,
            );

            if (aesKeyPair.privateKey != null) {
              final String aesPrivateKey = Format.uint8listToString(
                aesKeyPair.privateKey!,
              );
              final int amount = decryptMintAmount(
                aesPrivateKey,
                thirdValue,
              );

              final String serialNumber = GetSerialNumber(
                amount,
                Format.uint8listToString(mintKeyPair.privateKey!),
                currentIndex,
                isTestnet: coin == Coin.firoTestNet,
              );
              bool isUsed = usedSerialNumbersSet.contains(serialNumber);
              final duplicateCoin = lelantusCoins.firstWhere(
                (element) {
                  final coin = element.values.first;
                  return coin.txId == txId &&
                      coin.index == currentIndex &&
                      coin.anonymitySetId != setId;
                },
                orElse: () => {},
              );
              if (duplicateCoin.isNotEmpty) {
                Logging.instance.log(
                  "Firo isolateRestore removing duplicate coin: $duplicateCoin",
                  level: LogLevel.Info,
                );
                lelantusCoins.remove(duplicateCoin);
              }
              lelantusCoins.add({
                txId: LelantusCoin(
                  currentIndex,
                  amount,
                  publicCoin,
                  txId,
                  setId,
                  isUsed,
                )
              });
              jindexes.add(currentIndex);

              spendTxIds.add(txId);
            } else {
              Logging.instance.log(
                "AES keypair derivation issue for derive path: $derivePath",
                level: LogLevel.Warning,
              );
            }
          } else {
            Logging.instance.log(
              "Unexpected coin found: $foundCoin",
              level: LogLevel.Warning,
            );
          }
        } else {
          Logging.instance.log(
            "Coin not found in data with the mint tag: $mintTag",
            level: LogLevel.Warning,
          );
        }
      }

      currentIndex++;
    }
  } catch (e, s) {
    Logging.instance.log("Exception rethrown from isolateRestore(): $e\n$s",
        level: LogLevel.Info);
    rethrow;
  }

  Map<String, dynamic> result = {};
  // Logging.instance.log("mints $lelantusCoins", addToDebugMessagesDB: false);
  // Logging.instance.log("jmints $spendTxIds", addToDebugMessagesDB: false);

  result['_lelantus_coins'] = lelantusCoins;
  result['mintIndex'] = lastFoundIndex + 1;
  result['jindex'] = jindexes;
  result['spendTxIds'] = spendTxIds;

  return result;
}

Future<Map<dynamic, dynamic>> staticProcessRestore(
  List<isar_models.Transaction> txns,
  Map<dynamic, dynamic> result,
  int currentHeight,
) async {
  List<dynamic>? _l = result['_lelantus_coins'] as List?;
  final List<Map<dynamic, LelantusCoin>> lelantusCoins = [];
  for (var el in _l ?? []) {
    lelantusCoins.add({el.keys.first: el.values.first as LelantusCoin});
  }

  // Edit the receive transactions with the mint fees.
  Map<String, isar_models.Transaction> editedTransactions =
      <String, isar_models.Transaction>{};
  for (var item in lelantusCoins) {
    item.forEach((key, value) {
      String txid = value.txId;
      isar_models.Transaction? tx;
      try {
        tx = txns.firstWhere((e) => e.txid == txid);
      } catch (_) {
        tx = null;
      }

      if (tx == null || tx.subType == isar_models.TransactionSubType.join) {
        // This is a jmint.
        return;
      }
      List<isar_models.Transaction> inputs = [];
      for (var element in tx.inputs) {
        isar_models.Transaction? input;
        try {
          input = txns.firstWhere((e) => e.txid == element.txid);
        } catch (_) {
          input = null;
        }
        if (input != null) {
          inputs.add(input);
        }
      }
      if (inputs.isEmpty) {
        //some error.
        return;
      }

      int mintFee = tx.fee;
      int sharedFee = mintFee ~/ inputs.length;
      for (var element in inputs) {
        editedTransactions[element.txid] = isar_models.Transaction(
          walletId: element.walletId,
          txid: element.txid,
          timestamp: element.timestamp,
          type: element.type,
          subType: isar_models.TransactionSubType.mint,
          amount: element.amount,
          amountString: Amount(
            rawValue: BigInt.from(element.amount),
            fractionDigits: Coin.firo.decimals,
          ).toJsonString(),
          fee: sharedFee,
          height: element.height,
          isCancelled: false,
          isLelantus: true,
          slateId: null,
          otherData: txid,
          nonce: null,
          inputs: element.inputs,
          outputs: element.outputs,
        )..address.value = element.address.value;
      }
    });
  }
  // Logging.instance.log(editedTransactions, addToDebugMessagesDB: false);

  Map<String, isar_models.Transaction> transactionMap = {};
  for (final e in txns) {
    transactionMap[e.txid] = e;
  }
  // Logging.instance.log(transactionMap, addToDebugMessagesDB: false);

  editedTransactions.forEach((key, value) {
    transactionMap.update(key, (_value) => value);
  });

  transactionMap.removeWhere((key, value) =>
      lelantusCoins.any((element) => element.containsKey(key)) ||
      ((value.height == -1 || value.height == null) &&
          !value.isConfirmed(currentHeight, MINIMUM_CONFIRMATIONS)));

  result['newTxMap'] = transactionMap;
  return result;
}

Future<LelantusFeeData> isolateEstimateJoinSplitFee(
    int spendAmount,
    bool subtractFeeFromAmount,
    List<DartLelantusEntry> lelantusEntries,
    Coin coin) async {
  Logging.instance.log("estimateJoinsplit fee", level: LogLevel.Info);
  // for (int i = 0; i < lelantusEntries.length; i++) {
  //   Logging.instance.log(lelantusEntries[i], addToDebugMessagesDB: false);
  // }
  Logging.instance
      .log("$spendAmount $subtractFeeFromAmount", level: LogLevel.Info);

  List<int> changeToMint = List.empty(growable: true);
  List<int> spendCoinIndexes = List.empty(growable: true);
  // Logging.instance.log(lelantusEntries, addToDebugMessagesDB: false);
  final fee = estimateFee(
    spendAmount,
    subtractFeeFromAmount,
    lelantusEntries,
    changeToMint,
    spendCoinIndexes,
    isTestnet: coin == Coin.firoTestNet,
  );

  final estimateFeeData =
      LelantusFeeData(changeToMint[0], fee, spendCoinIndexes);
  Logging.instance.log(
      "estimateFeeData ${estimateFeeData.changeToMint} ${estimateFeeData.fee} ${estimateFeeData.spendCoinIndexes}",
      level: LogLevel.Info);
  return estimateFeeData;
}

Future<dynamic> isolateCreateJoinSplitTransaction(
  int spendAmount,
  String address,
  bool subtractFeeFromAmount,
  String mnemonic,
  String mnemonicPassphrase,
  int index,
  List<DartLelantusEntry> lelantusEntries,
  int locktime,
  Coin coin,
  NetworkType _network,
  List<Map<dynamic, dynamic>> anonymitySetsArg,
) async {
  final estimateJoinSplitFee = await isolateEstimateJoinSplitFee(
      spendAmount, subtractFeeFromAmount, lelantusEntries, coin);
  var changeToMint = estimateJoinSplitFee.changeToMint;
  var fee = estimateJoinSplitFee.fee;
  var spendCoinIndexes = estimateJoinSplitFee.spendCoinIndexes;
  Logging.instance
      .log("$changeToMint $fee $spendCoinIndexes", level: LogLevel.Info);
  if (spendCoinIndexes.isEmpty) {
    Logging.instance.log("Error, Not enough funds.", level: LogLevel.Error);
    return 1;
  }

  final tx = TransactionBuilder(network: _network);
  tx.setLockTime(locktime);

  tx.setVersion(3 | (TRANSACTION_LELANTUS << 16));

  tx.addInput(
    '0000000000000000000000000000000000000000000000000000000000000000',
    4294967295,
    4294967295,
    Uint8List(0),
  );
  final derivePath = constructDerivePath(
    networkWIF: _network.wif,
    chain: MINT_INDEX,
    index: index,
  );
  final jmintKeyPair = await Bip32Utils.getBip32Node(
    mnemonic,
    mnemonicPassphrase,
    _network,
    derivePath,
  );

  final String jmintprivatekey =
      Format.uint8listToString(jmintKeyPair.privateKey!);

  final keyPath = getMintKeyPath(changeToMint, jmintprivatekey, index,
      isTestnet: coin == Coin.firoTestNet);

  final _derivePath = constructDerivePath(
    networkWIF: _network.wif,
    chain: JMINT_INDEX,
    index: keyPath,
  );
  final aesKeyPair = await Bip32Utils.getBip32Node(
    mnemonic,
    mnemonicPassphrase,
    _network,
    _derivePath,
  );
  final aesPrivateKey = Format.uint8listToString(aesKeyPair.privateKey!);

  final jmintData = createJMintScript(
    changeToMint,
    Format.uint8listToString(jmintKeyPair.privateKey!),
    index,
    Format.uint8listToString(jmintKeyPair.identifier),
    aesPrivateKey,
    isTestnet: coin == Coin.firoTestNet,
  );

  tx.addOutput(
    Format.stringToUint8List(jmintData),
    0,
  );

  int amount = spendAmount;
  if (subtractFeeFromAmount) {
    amount -= fee;
  }
  tx.addOutput(
    address,
    amount,
  );

  final extractedTx = tx.buildIncomplete();
  extractedTx.setPayload(Uint8List(0));
  final txHash = extractedTx.getId();

  final List<int> setIds = [];
  final List<List<String>> anonymitySets = [];
  final List<String> anonymitySetHashes = [];
  final List<String> groupBlockHashes = [];
  for (var i = 0; i < lelantusEntries.length; i++) {
    final anonymitySetId = lelantusEntries[i].anonymitySetId;
    if (!setIds.contains(anonymitySetId)) {
      setIds.add(anonymitySetId);
      final anonymitySet = anonymitySetsArg.firstWhere(
          (element) => element["setId"] == anonymitySetId,
          orElse: () => <String, dynamic>{});
      if (anonymitySet.isNotEmpty) {
        anonymitySetHashes.add(anonymitySet['setHash'] as String);
        groupBlockHashes.add(anonymitySet['blockHash'] as String);
        List<String> list = [];
        for (int i = 0; i < (anonymitySet['coins'] as List).length; i++) {
          list.add(anonymitySet['coins'][i][0] as String);
        }
        anonymitySets.add(list);
      }
    }
  }

  final String spendScript = createJoinSplitScript(
      txHash,
      spendAmount,
      subtractFeeFromAmount,
      Format.uint8listToString(jmintKeyPair.privateKey!),
      index,
      lelantusEntries,
      setIds,
      anonymitySets,
      anonymitySetHashes,
      groupBlockHashes,
      isTestnet: coin == Coin.firoTestNet);

  final finalTx = TransactionBuilder(network: _network);
  finalTx.setLockTime(locktime);

  finalTx.setVersion(3 | (TRANSACTION_LELANTUS << 16));

  finalTx.addOutput(
    Format.stringToUint8List(jmintData),
    0,
  );

  finalTx.addOutput(
    address,
    amount,
  );

  final extTx = finalTx.buildIncomplete();
  extTx.addInput(
    Format.stringToUint8List(
        '0000000000000000000000000000000000000000000000000000000000000000'),
    4294967295,
    4294967295,
    Format.stringToUint8List("c9"),
  );
  debugPrint("spendscript: $spendScript");
  extTx.setPayload(Format.stringToUint8List(spendScript));

  final txHex = extTx.toHex();
  final txId = extTx.getId();
  Logging.instance.log("txid  $txId", level: LogLevel.Info);
  Logging.instance.log("txHex: $txHex", level: LogLevel.Info);

  final amountAmount = Amount(
    rawValue: BigInt.from(amount),
    fractionDigits: coin.decimals,
  );

  return {
    "txid": txId,
    "txHex": txHex,
    "value": amount,
    "fees": Amount(
      rawValue: BigInt.from(fee),
      fractionDigits: coin.decimals,
    ).decimal.toDouble(),
    "fee": fee,
    "vSize": extTx.virtualSize(),
    "jmintValue": changeToMint,
    "publicCoin": "jmintData.publicCoin",
    "spendCoinIndexes": spendCoinIndexes,
    "height": locktime,
    "txType": "Sent",
    "confirmed_status": false,
    "amount": amountAmount.decimal.toDouble(),
    "recipientAmt": amountAmount,
    "address": address,
    "timestamp": DateTime.now().millisecondsSinceEpoch ~/ 1000,
    "subType": "join",
  };
}

Future<int> getBlockHead(ElectrumX client) async {
  try {
    final tip = await client.getBlockHeadTip();
    return tip["height"] as int;
  } catch (e) {
    Logging.instance
        .log("Exception rethrown in getBlockHead(): $e", level: LogLevel.Error);
    rethrow;
  }
}
// end of isolates

String constructDerivePath({
  // required DerivePathType derivePathType,
  required int networkWIF,
  int account = 0,
  required int chain,
  required int index,
}) {
  String coinType;
  switch (networkWIF) {
    case 0xd2: // firo mainnet wif
      coinType = "136"; // firo mainnet
      break;
    case 0xb9: // firo testnet wif
      coinType = "1"; // firo testnet
      break;
    default:
      throw Exception("Invalid Firo network wif used!");
  }

  int purpose;
  // switch (derivePathType) {
  //   case DerivePathType.bip44:
  purpose = 44;
  //     break;
  //   default:
  //     throw Exception("DerivePathType $derivePathType not supported");
  // }

  return "m/$purpose'/$coinType'/$account'/$chain/$index";
}

Future<String> _getMintScriptWrapper(
    Tuple5<int, String, int, String, bool> data) async {
  String mintHex = getMintScript(data.item1, data.item2, data.item3, data.item4,
      isTestnet: data.item5);
  return mintHex;
}

Future<void> _setTestnetWrapper(bool isTestnet) async {
  // setTestnet(isTestnet);
}

/// Handles a single instance of a firo wallet
class FiroWallet extends CoinServiceAPI
    with WalletCache, WalletDB, FiroHive
    implements XPubAble {
  // Constructor
  FiroWallet({
    required String walletId,
    required String walletName,
    required Coin coin,
    required ElectrumX client,
    required CachedElectrumX cachedClient,
    required TransactionNotificationTracker tracker,
    required SecureStorageInterface secureStore,
    MainDB? mockableOverride,
  }) {
    txTracker = tracker;
    _walletId = walletId;
    _walletName = walletName;
    _coin = coin;
    _electrumXClient = client;
    _cachedElectrumXClient = cachedClient;
    _secureStore = secureStore;
    initCache(walletId, coin);
    initFiroHive(walletId);
    initWalletDB(mockableOverride: mockableOverride);

    Logging.instance.log("$walletName isolates length: ${isolates.length}",
        level: LogLevel.Info);
    // investigate possible issues killing shared isolates between multiple firo instances
    for (final isolate in isolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    isolates.clear();
  }

  static const integrationTestFlag =
      bool.fromEnvironment("IS_INTEGRATION_TEST");

  final _prefs = Prefs.instance;

  Timer? timer;
  late final Coin _coin;

  bool _shouldAutoSync = false;

  @override
  bool get shouldAutoSync => _shouldAutoSync;

  @override
  set shouldAutoSync(bool shouldAutoSync) {
    if (_shouldAutoSync != shouldAutoSync) {
      _shouldAutoSync = shouldAutoSync;
      if (!shouldAutoSync) {
        timer?.cancel();
        timer = null;
        stopNetworkAlivePinging();
      } else {
        startNetworkAlivePinging();
        refresh();
      }
    }
  }

  NetworkType get _network {
    switch (coin) {
      case Coin.firo:
        return firoNetwork;
      case Coin.firoTestNet:
        return firoTestNetwork;
      default:
        throw Exception("Invalid network type!");
    }
  }

  @override
  set isFavorite(bool markFavorite) {
    _isFavorite = markFavorite;
    updateCachedIsFavorite(markFavorite);
  }

  @override
  bool get isFavorite => _isFavorite ??= getCachedIsFavorite();

  bool? _isFavorite;

  @override
  Coin get coin => _coin;

  @override
  Future<List<String>> get mnemonic => _getMnemonicList();

  @override
  Future<String?> get mnemonicString =>
      _secureStore.read(key: '${_walletId}_mnemonic');

  @override
  Future<String?> get mnemonicPassphrase => _secureStore.read(
        key: '${_walletId}_mnemonicPassphrase',
      );

  @override
  bool validateAddress(String address) {
    return Address.validateAddress(address, _network);
  }

  /// Holds wallet transaction data
  Future<List<isar_models.Transaction>> get _txnData => db
      .getTransactions(walletId)
      .filter()
      .isLelantusIsNull()
      .or()
      .isLelantusEqualTo(false)
      .findAll();

  // _transactionData ??= _refreshTransactions();

  // models.TransactionData? cachedTxData;

  // hack to add tx to txData before refresh completes
  // required based on current app architecture where we don't properly store
  // transactions locally in a good way
  @override
  Future<void> updateSentCachedTxData(Map<String, dynamic> txData) async {
    final transaction = isar_models.Transaction(
      walletId: walletId,
      txid: txData["txid"] as String,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      type: isar_models.TransactionType.outgoing,
      subType: isar_models.TransactionSubType.none,
      // precision may be lost here hence the following amountString
      amount: (txData["recipientAmt"] as Amount).raw.toInt(),
      amountString: (txData["recipientAmt"] as Amount).toJsonString(),
      fee: txData["fee"] as int,
      height: null,
      isCancelled: false,
      isLelantus: false,
      otherData: null,
      slateId: null,
      nonce: null,
      inputs: [],
      outputs: [],
    );

    final address = txData["address"] is String
        ? await db.getAddress(walletId, txData["address"] as String)
        : null;

    await db.addNewTransactionData(
      [
        Tuple2(transaction, address),
      ],
      walletId,
    );
  }

  /// Holds the max fee that can be sent
  Future<int>? _maxFee;

  @override
  Future<int> get maxFee => _maxFee ??= _fetchMaxFee();

  Future<FeeObject>? _feeObject;

  @override
  Future<FeeObject> get fees => _feeObject ??= _getFees();

  @override
  Future<String> get currentReceivingAddress async =>
      (await _currentReceivingAddress).value;

  Future<isar_models.Address> get _currentReceivingAddress async =>
      (await db
          .getAddresses(walletId)
          .filter()
          .typeEqualTo(isar_models.AddressType.p2pkh)
          .subTypeEqualTo(isar_models.AddressSubType.receiving)
          .sortByDerivationIndexDesc()
          .findFirst()) ??
      await _generateAddressForChain(0, 0);

  Future<String> get currentChangeAddress async =>
      (await _currentChangeAddress).value;

  Future<isar_models.Address> get _currentChangeAddress async =>
      (await db
          .getAddresses(walletId)
          .filter()
          .typeEqualTo(isar_models.AddressType.p2pkh)
          .subTypeEqualTo(isar_models.AddressSubType.change)
          .sortByDerivationIndexDesc()
          .findFirst()) ??
      await _generateAddressForChain(1, 0);

  late String _walletName;

  @override
  String get walletName => _walletName;

  // setter for updating on rename
  @override
  set walletName(String newName) => _walletName = newName;

  /// unique wallet id
  late final String _walletId;

  @override
  String get walletId => _walletId;

  @override
  Future<bool> testNetworkConnection() async {
    try {
      final result = await _electrumXClient.ping();
      return result;
    } catch (_) {
      return false;
    }
  }

  Timer? _networkAliveTimer;

  void startNetworkAlivePinging() {
    // call once on start right away
    _periodicPingCheck();

    // then periodically check
    _networkAliveTimer = Timer.periodic(
      Constants.networkAliveTimerDuration,
      (_) async {
        _periodicPingCheck();
      },
    );
  }

  void _periodicPingCheck() async {
    bool hasNetwork = await testNetworkConnection();
    _isConnected = hasNetwork;
    if (_isConnected != hasNetwork) {
      NodeConnectionStatus status = hasNetwork
          ? NodeConnectionStatus.connected
          : NodeConnectionStatus.disconnected;
      GlobalEventBus.instance
          .fire(NodeConnectionStatusChangedEvent(status, walletId, coin));
    }
  }

  void stopNetworkAlivePinging() {
    _networkAliveTimer?.cancel();
    _networkAliveTimer = null;
  }

  bool _isConnected = false;

  @override
  bool get isConnected => _isConnected;

  Future<Map<String, dynamic>> prepareSendPublic({
    required String address,
    required Amount amount,
    Map<String, dynamic>? args,
  }) async {
    try {
      final feeRateType = args?["feeRate"];
      final feeRateAmount = args?["feeRateAmount"];
      if (feeRateType is FeeRateType || feeRateAmount is int) {
        late final int rate;
        if (feeRateType is FeeRateType) {
          int fee = 0;
          final feeObject = await fees;
          switch (feeRateType) {
            case FeeRateType.fast:
              fee = feeObject.fast;
              break;
            case FeeRateType.average:
              fee = feeObject.medium;
              break;
            case FeeRateType.slow:
              fee = feeObject.slow;
              break;
          }
          rate = fee;
        } else {
          rate = feeRateAmount as int;
        }

        // check for send all
        bool isSendAll = false;
        final balance = availablePublicBalance();
        if (amount == balance) {
          isSendAll = true;
        }

        final txData = await coinSelection(
          amount.raw.toInt(),
          rate,
          address,
          isSendAll,
        );

        Logging.instance.log("prepare send: $txData", level: LogLevel.Info);
        try {
          if (txData is int) {
            switch (txData) {
              case 1:
                throw Exception("Insufficient balance!");
              case 2:
                throw Exception(
                    "Insufficient funds to pay for transaction fee!");
              default:
                throw Exception("Transaction failed with error code $txData");
            }
          } else {
            final hex = txData["hex"];

            if (hex is String) {
              final fee = txData["fee"] as int;
              final vSize = txData["vSize"] as int;

              Logging.instance
                  .log("prepared txHex: $hex", level: LogLevel.Info);
              Logging.instance.log("prepared fee: $fee", level: LogLevel.Info);
              Logging.instance
                  .log("prepared vSize: $vSize", level: LogLevel.Info);

              // fee should never be less than vSize sanity check
              if (fee < vSize) {
                throw Exception(
                    "Error in fee calculation: Transaction fee cannot be less than vSize");
              }

              return txData as Map<String, dynamic>;
            } else {
              throw Exception("prepared hex is not a String!!!");
            }
          }
        } catch (e, s) {
          Logging.instance.log("Exception rethrown from prepareSend(): $e\n$s",
              level: LogLevel.Error);
          rethrow;
        }
      } else {
        throw ArgumentError("Invalid fee rate argument provided!");
      }
    } catch (e, s) {
      Logging.instance.log("Exception rethrown from prepareSend(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<String> confirmSendPublic({dynamic txData}) async {
    try {
      Logging.instance.log("confirmSend txData: $txData", level: LogLevel.Info);
      final txHash = await _electrumXClient.broadcastTransaction(
          rawTx: txData["hex"] as String);
      Logging.instance.log("Sent txHash: $txHash", level: LogLevel.Info);
      txData["txid"] = txHash;
      // dirty ui update hack
      await updateSentCachedTxData(txData as Map<String, dynamic>);
      return txHash;
    } catch (e, s) {
      Logging.instance.log("Exception rethrown from confirmSend(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> prepareSend({
    required String address,
    required Amount amount,
    Map<String, dynamic>? args,
  }) async {
    try {
      // check for send all
      bool isSendAll = false;
      final balance = availablePrivateBalance();
      if (amount == balance) {
        // print("is send all");
        isSendAll = true;
      }
      dynamic txHexOrError = await _createJoinSplitTransaction(
        amount.raw.toInt(),
        address,
        isSendAll,
      );
      Logging.instance.log("txHexOrError $txHexOrError", level: LogLevel.Error);
      if (txHexOrError is int) {
        // Here, we assume that transaction crafting returned an error
        switch (txHexOrError) {
          case 1:
            throw Exception("Insufficient balance!");
          default:
            throw Exception("Error Creating Transaction!");
        }
      } else {
        final fee = txHexOrError["fee"] as int;
        final vSize = txHexOrError["vSize"] as int;

        Logging.instance.log("prepared fee: $fee", level: LogLevel.Info);
        Logging.instance.log("prepared vSize: $vSize", level: LogLevel.Info);

        // fee should never be less than vSize sanity check
        if (fee < vSize) {
          throw Exception(
              "Error in fee calculation: Transaction fee cannot be less than vSize");
        }
        return txHexOrError as Map<String, dynamic>;
      }
    } catch (e, s) {
      Logging.instance.log("Exception rethrown in firo prepareSend(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  @override
  Future<String> confirmSend({required Map<String, dynamic> txData}) async {
    if (await _submitLelantusToNetwork(txData)) {
      try {
        final txid = txData["txid"] as String;

        // temporarily update apdate available balance until a full refresh is done

        // TODO: something here causes an exception to be thrown giving user false info that the tx failed
        // Decimal sendTotal =
        //     Format.satoshisToAmount(txData["value"] as int, coin: coin);
        // sendTotal += Decimal.parse(txData["fees"].toString());

        // TODO: is this needed?
        // final bals = await balances;
        // bals[0] -= sendTotal;
        // _balances = Future(() => bals);

        return txid;
      } catch (e, s) {
        //todo: come back to this
        debugPrint("$e $s");
        return txData["txid"] as String;
        // don't throw anything here or it will tell the user that th tx
        // failed even though it was successfully broadcast to network
        // throw Exception("Transaction failed.");
      }
    } else {
      //TODO provide more info
      throw Exception("Transaction failed.");
    }
  }

  // /// returns txid on successful send
  // ///
  // /// can throw
  // @override
  // Future<String> send({
  //   required String toAddress,
  //   required int amount,
  //   Map<String, String> args = const {},
  // }) async {
  //   try {
  //     dynamic txHexOrError =
  //         await _createJoinSplitTransaction(amount, toAddress, false);
  //     Logging.instance.log("txHexOrError $txHexOrError", level: LogLevel.Error);
  //     if (txHexOrError is int) {
  //       // Here, we assume that transaction crafting returned an error
  //       switch (txHexOrError) {
  //         case 1:
  //           throw Exception("Insufficient balance!");
  //         default:
  //           throw Exception("Error Creating Transaction!");
  //       }
  //     } else {
  //       if (await _submitLelantusToNetwork(
  //           txHexOrError as Map<String, dynamic>)) {
  //         final txid = txHexOrError["txid"] as String;
  //
  //         // temporarily update apdate available balance until a full refresh is done
  //         Decimal sendTotal =
  //             Format.satoshisToAmount(txHexOrError["value"] as int, coin: coin);
  //         sendTotal += Decimal.parse(txHexOrError["fees"].toString());
  //         final bals = await balances;
  //         bals[0] -= sendTotal;
  //         _balances = Future(() => bals);
  //
  //         return txid;
  //       } else {
  //         //TODO provide more info
  //         throw Exception("Transaction failed.");
  //       }
  //     }
  //   } catch (e, s) {
  //     Logging.instance.log("Exception rethrown in firo send(): $e\n$s",
  //         level: LogLevel.Error);
  //     rethrow;
  //   }
  // }

  Future<List<String>> _getMnemonicList() async {
    final _mnemonicString = await mnemonicString;
    if (_mnemonicString == null) {
      return [];
    }
    final List<String> data = _mnemonicString.split(' ');
    return data;
  }

  late ElectrumX _electrumXClient;

  ElectrumX get electrumXClient => _electrumXClient;

  late CachedElectrumX _cachedElectrumXClient;

  CachedElectrumX get cachedElectrumXClient => _cachedElectrumXClient;

  late SecureStorageInterface _secureStore;

  late TransactionNotificationTracker txTracker;

  int estimateTxFee({required int vSize, required int feeRatePerKB}) {
    return vSize * (feeRatePerKB / 1000).ceil();
  }

  /// The coinselection algorithm decides whether or not the user is eligible to make the transaction
  /// with [satoshiAmountToSend] and [selectedTxFeeRate]. If so, it will call buildTrasaction() and return
  /// a map containing the tx hex along with other important information. If not, then it will return
  /// an integer (1 or 2)
  dynamic coinSelection(
    int satoshiAmountToSend,
    int selectedTxFeeRate,
    String _recipientAddress,
    bool isSendAll, {
    int additionalOutputs = 0,
    List<isar_models.UTXO>? utxos,
  }) async {
    Logging.instance
        .log("Starting coinSelection ----------", level: LogLevel.Info);
    final List<isar_models.UTXO> availableOutputs = utxos ?? await this.utxos;
    final currentChainHeight = await chainHeight;
    final List<isar_models.UTXO> spendableOutputs = [];
    int spendableSatoshiValue = 0;

    // Build list of spendable outputs and totaling their satoshi amount
    for (var i = 0; i < availableOutputs.length; i++) {
      if (availableOutputs[i].isBlocked == false &&
          availableOutputs[i]
                  .isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS) ==
              true) {
        spendableOutputs.add(availableOutputs[i]);
        spendableSatoshiValue += availableOutputs[i].value;
      }
    }

    // sort spendable by age (oldest first)
    spendableOutputs.sort((a, b) => b.blockTime!.compareTo(a.blockTime!));

    Logging.instance.log("spendableOutputs.length: ${spendableOutputs.length}",
        level: LogLevel.Info);
    Logging.instance
        .log("spendableOutputs: $spendableOutputs", level: LogLevel.Info);
    Logging.instance.log("spendableSatoshiValue: $spendableSatoshiValue",
        level: LogLevel.Info);
    Logging.instance
        .log("satoshiAmountToSend: $satoshiAmountToSend", level: LogLevel.Info);
    // If the amount the user is trying to send is smaller than the amount that they have spendable,
    // then return 1, which indicates that they have an insufficient balance.
    if (spendableSatoshiValue < satoshiAmountToSend) {
      return 1;
      // If the amount the user wants to send is exactly equal to the amount they can spend, then return
      // 2, which indicates that they are not leaving enough over to pay the transaction fee
    } else if (spendableSatoshiValue == satoshiAmountToSend && !isSendAll) {
      return 2;
    }
    // If neither of these statements pass, we assume that the user has a spendable balance greater
    // than the amount they're attempting to send. Note that this value still does not account for
    // the added transaction fee, which may require an extra input and will need to be checked for
    // later on.

    // Possible situation right here
    int satoshisBeingUsed = 0;
    int inputsBeingConsumed = 0;
    List<isar_models.UTXO> utxoObjectsToUse = [];

    for (var i = 0;
        satoshisBeingUsed <= satoshiAmountToSend && i < spendableOutputs.length;
        i++) {
      utxoObjectsToUse.add(spendableOutputs[i]);
      satoshisBeingUsed += spendableOutputs[i].value;
      inputsBeingConsumed += 1;
    }
    for (int i = 0;
        i < additionalOutputs && inputsBeingConsumed < spendableOutputs.length;
        i++) {
      utxoObjectsToUse.add(spendableOutputs[inputsBeingConsumed]);
      satoshisBeingUsed += spendableOutputs[inputsBeingConsumed].value;
      inputsBeingConsumed += 1;
    }

    Logging.instance
        .log("satoshisBeingUsed: $satoshisBeingUsed", level: LogLevel.Info);
    Logging.instance
        .log("inputsBeingConsumed: $inputsBeingConsumed", level: LogLevel.Info);
    Logging.instance
        .log('utxoObjectsToUse: $utxoObjectsToUse', level: LogLevel.Info);

    // numberOfOutputs' length must always be equal to that of recipientsArray and recipientsAmtArray
    List<String> recipientsArray = [_recipientAddress];
    List<int> recipientsAmtArray = [satoshiAmountToSend];

    // gather required signing data
    final utxoSigningData = await fetchBuildTxData(utxoObjectsToUse);

    if (isSendAll) {
      Logging.instance
          .log("Attempting to send all $coin", level: LogLevel.Info);

      final int vSizeForOneOutput = (await buildTransaction(
        utxoSigningData: utxoSigningData,
        recipients: [_recipientAddress],
        satoshiAmounts: [satoshisBeingUsed - 1],
      ))["vSize"] as int;
      int feeForOneOutput = estimateTxFee(
        vSize: vSizeForOneOutput,
        feeRatePerKB: selectedTxFeeRate,
      );

      if (feeForOneOutput < vSizeForOneOutput + 1) {
        feeForOneOutput = vSizeForOneOutput + 1;
      }

      final int amount = satoshiAmountToSend - feeForOneOutput;
      dynamic txn = await buildTransaction(
        utxoSigningData: utxoSigningData,
        recipients: recipientsArray,
        satoshiAmounts: [amount],
      );
      Map<String, dynamic> transactionObject = {
        "hex": txn["hex"],
        "recipient": recipientsArray[0],
        "recipientAmt": Amount(
          rawValue: BigInt.from(amount),
          fractionDigits: coin.decimals,
        ),
        "fee": feeForOneOutput,
        "vSize": txn["vSize"],
      };
      return transactionObject;
    }

    final int vSizeForOneOutput = (await buildTransaction(
      utxoSigningData: utxoSigningData,
      recipients: [_recipientAddress],
      satoshiAmounts: [satoshisBeingUsed - 1],
    ))["vSize"] as int;
    final int vSizeForTwoOutPuts = (await buildTransaction(
      utxoSigningData: utxoSigningData,
      recipients: [
        _recipientAddress,
        await _getCurrentAddressForChain(1),
      ],
      satoshiAmounts: [
        satoshiAmountToSend,
        satoshisBeingUsed - satoshiAmountToSend - 1,
      ], // dust limit is the minimum amount a change output should be
    ))["vSize"] as int;
    //todo: check if print needed
    debugPrint("vSizeForOneOutput $vSizeForOneOutput");
    debugPrint("vSizeForTwoOutPuts $vSizeForTwoOutPuts");

    // Assume 1 output, only for recipient and no change
    var feeForOneOutput = estimateTxFee(
      vSize: vSizeForOneOutput,
      feeRatePerKB: selectedTxFeeRate,
    );
    // Assume 2 outputs, one for recipient and one for change
    var feeForTwoOutputs = estimateTxFee(
      vSize: vSizeForTwoOutPuts,
      feeRatePerKB: selectedTxFeeRate,
    );

    Logging.instance
        .log("feeForTwoOutputs: $feeForTwoOutputs", level: LogLevel.Info);
    Logging.instance
        .log("feeForOneOutput: $feeForOneOutput", level: LogLevel.Info);
    if (feeForOneOutput < (vSizeForOneOutput + 1)) {
      feeForOneOutput = (vSizeForOneOutput + 1);
    }
    if (feeForTwoOutputs < ((vSizeForTwoOutPuts + 1))) {
      feeForTwoOutputs = ((vSizeForTwoOutPuts + 1));
    }

    Logging.instance
        .log("feeForTwoOutputs: $feeForTwoOutputs", level: LogLevel.Info);
    Logging.instance
        .log("feeForOneOutput: $feeForOneOutput", level: LogLevel.Info);

    if (satoshisBeingUsed - satoshiAmountToSend > feeForOneOutput) {
      if (satoshisBeingUsed - satoshiAmountToSend >
          feeForOneOutput + DUST_LIMIT) {
        // Here, we know that theoretically, we may be able to include another output(change) but we first need to
        // factor in the value of this output in satoshis.
        int changeOutputSize =
            satoshisBeingUsed - satoshiAmountToSend - feeForTwoOutputs;
        // We check to see if the user can pay for the new transaction with 2 outputs instead of one. If they can and
        // the second output's size > DUST_LIMIT satoshis, we perform the mechanics required to properly generate and use a new
        // change address.
        if (changeOutputSize > DUST_LIMIT &&
            satoshisBeingUsed - satoshiAmountToSend - changeOutputSize ==
                feeForTwoOutputs) {
          // generate new change address if current change address has been used
          await checkChangeAddressForTransactions();
          final String newChangeAddress = await _getCurrentAddressForChain(1);

          int feeBeingPaid =
              satoshisBeingUsed - satoshiAmountToSend - changeOutputSize;

          recipientsArray.add(newChangeAddress);
          recipientsAmtArray.add(changeOutputSize);
          // At this point, we have the outputs we're going to use, the amounts to send along with which addresses
          // we intend to send these amounts to. We have enough to send instructions to build the transaction.
          Logging.instance.log('2 outputs in tx', level: LogLevel.Info);
          Logging.instance
              .log('Input size: $satoshisBeingUsed', level: LogLevel.Info);
          Logging.instance.log('Recipient output size: $satoshiAmountToSend',
              level: LogLevel.Info);
          Logging.instance.log('Change Output Size: $changeOutputSize',
              level: LogLevel.Info);
          Logging.instance.log(
              'Difference (fee being paid): $feeBeingPaid sats',
              level: LogLevel.Info);
          Logging.instance
              .log('Estimated fee: $feeForTwoOutputs', level: LogLevel.Info);
          dynamic txn = await buildTransaction(
            utxoSigningData: utxoSigningData,
            recipients: recipientsArray,
            satoshiAmounts: recipientsAmtArray,
          );

          // make sure minimum fee is accurate if that is being used
          if (txn["vSize"] - feeBeingPaid == 1) {
            int changeOutputSize =
                satoshisBeingUsed - satoshiAmountToSend - (txn["vSize"] as int);
            feeBeingPaid =
                satoshisBeingUsed - satoshiAmountToSend - changeOutputSize;
            recipientsAmtArray.removeLast();
            recipientsAmtArray.add(changeOutputSize);
            Logging.instance.log('Adjusted Input size: $satoshisBeingUsed',
                level: LogLevel.Info);
            Logging.instance.log(
                'Adjusted Recipient output size: $satoshiAmountToSend',
                level: LogLevel.Info);
            Logging.instance.log(
                'Adjusted Change Output Size: $changeOutputSize',
                level: LogLevel.Info);
            Logging.instance.log(
                'Adjusted Difference (fee being paid): $feeBeingPaid sats',
                level: LogLevel.Info);
            Logging.instance.log('Adjusted Estimated fee: $feeForTwoOutputs',
                level: LogLevel.Info);
            txn = await buildTransaction(
              utxoSigningData: utxoSigningData,
              recipients: recipientsArray,
              satoshiAmounts: recipientsAmtArray,
            );
          }

          Map<String, dynamic> transactionObject = {
            "hex": txn["hex"],
            "recipient": recipientsArray[0],
            "recipientAmt": Amount(
              rawValue: BigInt.from(recipientsAmtArray[0]),
              fractionDigits: coin.decimals,
            ),
            "fee": feeBeingPaid,
            "vSize": txn["vSize"],
          };
          return transactionObject;
        } else {
          // Something went wrong here. It either overshot or undershot the estimated fee amount or the changeOutputSize
          // is smaller than or equal to [DUST_LIMIT]. Revert to single output transaction.
          Logging.instance.log('1 output in tx', level: LogLevel.Info);
          Logging.instance
              .log('Input size: $satoshisBeingUsed', level: LogLevel.Info);
          Logging.instance.log('Recipient output size: $satoshiAmountToSend',
              level: LogLevel.Info);
          Logging.instance.log(
              'Difference (fee being paid): ${satoshisBeingUsed - satoshiAmountToSend} sats',
              level: LogLevel.Info);
          Logging.instance
              .log('Estimated fee: $feeForOneOutput', level: LogLevel.Info);
          dynamic txn = await buildTransaction(
            utxoSigningData: utxoSigningData,
            recipients: recipientsArray,
            satoshiAmounts: recipientsAmtArray,
          );
          Map<String, dynamic> transactionObject = {
            "hex": txn["hex"],
            "recipient": recipientsArray[0],
            "recipientAmt": Amount(
              rawValue: BigInt.from(recipientsAmtArray[0]),
              fractionDigits: coin.decimals,
            ),
            "fee": satoshisBeingUsed - satoshiAmountToSend,
            "vSize": txn["vSize"],
          };
          return transactionObject;
        }
      } else {
        // No additional outputs needed since adding one would mean that it'd be smaller than 546 sats
        // which makes it uneconomical to add to the transaction. Here, we pass data directly to instruct
        // the wallet to begin crafting the transaction that the user requested.
        Logging.instance.log('1 output in tx', level: LogLevel.Info);
        Logging.instance
            .log('Input size: $satoshisBeingUsed', level: LogLevel.Info);
        Logging.instance.log('Recipient output size: $satoshiAmountToSend',
            level: LogLevel.Info);
        Logging.instance.log(
            'Difference (fee being paid): ${satoshisBeingUsed - satoshiAmountToSend} sats',
            level: LogLevel.Info);
        Logging.instance
            .log('Estimated fee: $feeForOneOutput', level: LogLevel.Info);
        dynamic txn = await buildTransaction(
          utxoSigningData: utxoSigningData,
          recipients: recipientsArray,
          satoshiAmounts: recipientsAmtArray,
        );
        Map<String, dynamic> transactionObject = {
          "hex": txn["hex"],
          "recipient": recipientsArray[0],
          "recipientAmt": Amount(
            rawValue: BigInt.from(recipientsAmtArray[0]),
            fractionDigits: coin.decimals,
          ),
          "fee": satoshisBeingUsed - satoshiAmountToSend,
          "vSize": txn["vSize"],
        };
        return transactionObject;
      }
    } else if (satoshisBeingUsed - satoshiAmountToSend == feeForOneOutput) {
      // In this scenario, no additional change output is needed since inputs - outputs equal exactly
      // what we need to pay for fees. Here, we pass data directly to instruct the wallet to begin
      // crafting the transaction that the user requested.
      Logging.instance.log('1 output in tx', level: LogLevel.Info);
      Logging.instance
          .log('Input size: $satoshisBeingUsed', level: LogLevel.Info);
      Logging.instance.log('Recipient output size: $satoshiAmountToSend',
          level: LogLevel.Info);
      Logging.instance.log(
          'Fee being paid: ${satoshisBeingUsed - satoshiAmountToSend} sats',
          level: LogLevel.Info);
      Logging.instance
          .log('Estimated fee: $feeForOneOutput', level: LogLevel.Info);
      dynamic txn = await buildTransaction(
        utxoSigningData: utxoSigningData,
        recipients: recipientsArray,
        satoshiAmounts: recipientsAmtArray,
      );
      Map<String, dynamic> transactionObject = {
        "hex": txn["hex"],
        "recipient": recipientsArray[0],
        "recipientAmt": Amount(
          rawValue: BigInt.from(recipientsAmtArray[0]),
          fractionDigits: coin.decimals,
        ),
        "fee": feeForOneOutput,
        "vSize": txn["vSize"],
      };
      return transactionObject;
    } else {
      // Remember that returning 2 indicates that the user does not have a sufficient balance to
      // pay for the transaction fee. Ideally, at this stage, we should check if the user has any
      // additional outputs they're able to spend and then recalculate fees.
      Logging.instance.log(
          'Cannot pay tx fee - checking for more outputs and trying again',
          level: LogLevel.Warning);
      // try adding more outputs
      if (spendableOutputs.length > inputsBeingConsumed) {
        return coinSelection(satoshiAmountToSend, selectedTxFeeRate,
            _recipientAddress, isSendAll,
            additionalOutputs: additionalOutputs + 1, utxos: utxos);
      }
      return 2;
    }
  }

  Future<List<SigningData>> fetchBuildTxData(
    List<isar_models.UTXO> utxosToUse,
  ) async {
    // return data
    List<SigningData> signingData = [];

    try {
      // Populating the addresses to check
      for (var i = 0; i < utxosToUse.length; i++) {
        if (utxosToUse[i].address == null) {
          final txid = utxosToUse[i].txid;
          final tx = await _cachedElectrumXClient.getTransaction(
            txHash: txid,
            coin: coin,
          );
          for (final output in tx["vout"] as List) {
            final n = output["n"];
            if (n != null && n == utxosToUse[i].vout) {
              utxosToUse[i] = utxosToUse[i].copyWith(
                address: output["scriptPubKey"]?["addresses"]?[0] as String? ??
                    output["scriptPubKey"]["address"] as String,
              );
            }
          }
        }

        signingData.add(
          SigningData(
            derivePathType: DerivePathType.bip44,
            utxo: utxosToUse[i],
          ),
        );
      }

      Map<DerivePathType, Map<String, dynamic>> receiveDerivations = {};
      Map<DerivePathType, Map<String, dynamic>> changeDerivations = {};

      for (final sd in signingData) {
        String? pubKey;
        String? wif;

        final address = await db.getAddress(walletId, sd.utxo.address!);
        if (address?.derivationPath != null) {
          final node = await Bip32Utils.getBip32Node(
            (await mnemonicString)!,
            (await mnemonicPassphrase)!,
            _network,
            address!.derivationPath!.value,
          );

          wif = node.toWIF();
          pubKey = Format.uint8listToString(node.publicKey);
        }
        if (wif == null || pubKey == null) {
          // fetch receiving derivations if null
          receiveDerivations[sd.derivePathType] ??= Map<String, dynamic>.from(
            jsonDecode((await _secureStore.read(
                  key: "${walletId}_receiveDerivations",
                )) ??
                "{}") as Map,
          );

          dynamic receiveDerivation;
          for (int j = 0;
              j < receiveDerivations[sd.derivePathType]!.length &&
                  receiveDerivation == null;
              j++) {
            if (receiveDerivations[sd.derivePathType]!["$j"]["address"] ==
                sd.utxo.address!) {
              receiveDerivation = receiveDerivations[sd.derivePathType]!["$j"];
            }
          }

          if (receiveDerivation != null) {
            pubKey = receiveDerivation["publicKey"] as String;
            wif = receiveDerivation["wif"] as String;
          } else {
            // fetch change derivations if null
            changeDerivations[sd.derivePathType] ??= Map<String, dynamic>.from(
              jsonDecode((await _secureStore.read(
                    key: "${walletId}_changeDerivations",
                  )) ??
                  "{}") as Map,
            );

            dynamic changeDerivation;
            for (int j = 0;
                j < changeDerivations[sd.derivePathType]!.length &&
                    changeDerivation == null;
                j++) {
              if (changeDerivations[sd.derivePathType]!["$j"]["address"] ==
                  sd.utxo.address!) {
                changeDerivation = changeDerivations[sd.derivePathType]!["$j"];
              }
            }

            if (changeDerivation != null) {
              pubKey = changeDerivation["publicKey"] as String;
              wif = changeDerivation["wif"] as String;
            }
          }
        }

        if (wif != null && pubKey != null) {
          final PaymentData data;
          final Uint8List? redeemScript;

          switch (sd.derivePathType) {
            case DerivePathType.bip44:
              data = P2PKH(
                data: PaymentData(
                  pubkey: Format.stringToUint8List(pubKey),
                ),
                network: _network,
              ).data;
              redeemScript = null;
              break;

            default:
              throw Exception("DerivePathType unsupported");
          }

          final keyPair = ECPair.fromWIF(
            wif,
            network: _network,
          );

          sd.redeemScript = redeemScript;
          sd.output = data.output;
          sd.keyPair = keyPair;
        } else {
          throw Exception("key or wif not found for ${sd.utxo}");
        }
      }

      return signingData;
    } catch (e, s) {
      Logging.instance
          .log("fetchBuildTxData() threw: $e,\n$s", level: LogLevel.Error);
      rethrow;
    }
  }

  /// Builds and signs a transaction
  Future<Map<String, dynamic>> buildTransaction({
    required List<SigningData> utxoSigningData,
    required List<String> recipients,
    required List<int> satoshiAmounts,
  }) async {
    Logging.instance
        .log("Starting buildTransaction ----------", level: LogLevel.Info);

    final txb = TransactionBuilder(network: _network);
    txb.setVersion(1);

    // Add transaction inputs
    for (var i = 0; i < utxoSigningData.length; i++) {
      final txid = utxoSigningData[i].utxo.txid;
      txb.addInput(
        txid,
        utxoSigningData[i].utxo.vout,
        null,
        utxoSigningData[i].output!,
      );
    }

    // Add transaction output
    for (var i = 0; i < recipients.length; i++) {
      txb.addOutput(recipients[i], satoshiAmounts[i]);
    }

    try {
      // Sign the transaction accordingly
      for (var i = 0; i < utxoSigningData.length; i++) {
        txb.sign(
          vin: i,
          keyPair: utxoSigningData[i].keyPair!,
          witnessValue: utxoSigningData[i].utxo.value,
          redeemScript: utxoSigningData[i].redeemScript,
        );
      }
    } catch (e, s) {
      Logging.instance.log("Caught exception while signing transaction: $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }

    final builtTx = txb.build();
    final vSize = builtTx.virtualSize();

    return {"hex": builtTx.toHex(), "vSize": vSize};
  }

  @override
  Future<void> updateNode(bool shouldRefresh) async {
    final failovers = NodeService(secureStorageInterface: _secureStore)
        .failoverNodesFor(coin: coin)
        .map(
          (e) => ElectrumXNode(
            address: e.host,
            port: e.port,
            name: e.name,
            id: e.id,
            useSSL: e.useSSL,
          ),
        )
        .toList();
    final newNode = await _getCurrentNode();
    _cachedElectrumXClient = CachedElectrumX.from(
      node: newNode,
      prefs: _prefs,
      failovers: failovers,
    );
    _electrumXClient = ElectrumX.from(
      node: newNode,
      prefs: _prefs,
      failovers: failovers,
    );

    if (shouldRefresh) {
      unawaited(refresh());
    }
  }

  @override
  Future<void> initializeNew() async {
    Logging.instance
        .log("Generating new ${coin.prettyName} wallet.", level: LogLevel.Info);

    if (getCachedId() != null) {
      throw Exception(
          "Attempted to initialize a new wallet using an existing wallet ID!");
    }

    await _prefs.init();
    try {
      await _generateNewWallet();
    } catch (e, s) {
      Logging.instance.log("Exception rethrown from initializeNew(): $e\n$s",
          level: LogLevel.Fatal);
      rethrow;
    }

    await Future.wait([
      updateCachedId(walletId),
      updateCachedIsFavorite(false),
    ]);
  }

  @override
  Future<void> initializeExisting() async {
    Logging.instance.log(
        "initializeExisting() $_walletId ${coin.prettyName} wallet.",
        level: LogLevel.Info);

    if (getCachedId() == null) {
      throw Exception(
          "Attempted to initialize an existing wallet using an unknown wallet ID!");
    }
    await _prefs.init();
    // await checkChangeAddressForTransactions();
    // await checkReceivingAddressForTransactions();
  }

  Future<bool> refreshIfThereIsNewData() async {
    if (longMutex) return false;
    if (_hasCalledExit) return false;
    Logging.instance
        .log("$walletName refreshIfThereIsNewData", level: LogLevel.Info);

    try {
      bool needsRefresh = false;
      Set<String> txnsToCheck = {};

      for (final String txid in txTracker.pendings) {
        if (!txTracker.wasNotifiedConfirmed(txid)) {
          txnsToCheck.add(txid);
        }
      }

      for (String txid in txnsToCheck) {
        final txn = await electrumXClient.getTransaction(txHash: txid);
        int confirmations = txn["confirmations"] as int? ?? 0;
        bool isUnconfirmed = confirmations < MINIMUM_CONFIRMATIONS;
        if (!isUnconfirmed) {
          needsRefresh = true;
          break;
        }
      }
      if (!needsRefresh) {
        final allOwnAddresses = await _fetchAllOwnAddresses();
        List<Map<String, dynamic>> allTxs = await _fetchHistory(
            allOwnAddresses.map((e) => e.value).toList(growable: false));
        for (Map<String, dynamic> transaction in allTxs) {
          final txid = transaction['tx_hash'] as String;
          if ((await db
                  .getTransactions(walletId)
                  .filter()
                  .txidEqualTo(txid)
                  .count()) ==
              0) {
            Logging.instance.log(
              " txid not found in address history already ${transaction['tx_hash']}",
              level: LogLevel.Info,
            );
            needsRefresh = true;
            break;
          }
        }
      }
      return needsRefresh;
    } catch (e, s) {
      Logging.instance.log(
          "Exception caught in refreshIfThereIsNewData: $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<void> getAllTxsToWatch() async {
    if (_hasCalledExit) return;
    Logging.instance.log("$walletName periodic", level: LogLevel.Info);
    List<isar_models.Transaction> unconfirmedTxnsToNotifyPending = [];
    List<isar_models.Transaction> unconfirmedTxnsToNotifyConfirmed = [];

    final currentChainHeight = await chainHeight;

    final txCount = await db.getTransactions(walletId).count();

    const paginateLimit = 50;

    for (int i = 0; i < txCount; i += paginateLimit) {
      final transactions = await db
          .getTransactions(walletId)
          .offset(i)
          .limit(paginateLimit)
          .findAll();
      for (final tx in transactions) {
        if (tx.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS)) {
          // get all transactions that were notified as pending but not as confirmed
          if (txTracker.wasNotifiedPending(tx.txid) &&
              !txTracker.wasNotifiedConfirmed(tx.txid)) {
            unconfirmedTxnsToNotifyConfirmed.add(tx);
          }
        } else {
          // get all transactions that were not notified as pending yet
          if (!txTracker.wasNotifiedPending(tx.txid)) {
            unconfirmedTxnsToNotifyPending.add(tx);
          }
        }
      }
    }

    Logging.instance.log(
        "unconfirmedTxnsToNotifyPending $unconfirmedTxnsToNotifyPending",
        level: LogLevel.Info);
    Logging.instance.log(
        "unconfirmedTxnsToNotifyConfirmed $unconfirmedTxnsToNotifyConfirmed",
        level: LogLevel.Info);

    for (final tx in unconfirmedTxnsToNotifyPending) {
      final confirmations = tx.getConfirmations(currentChainHeight);

      switch (tx.type) {
        case isar_models.TransactionType.incoming:
          CryptoNotificationsEventBus.instance.fire(
            CryptoNotificationEvent(
              title: "Incoming transaction",
              walletId: walletId,
              date: DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000),
              shouldWatchForUpdates: confirmations < MINIMUM_CONFIRMATIONS,
              txid: tx.txid,
              confirmations: confirmations,
              requiredConfirmations: MINIMUM_CONFIRMATIONS,
              walletName: walletName,
              coin: coin,
            ),
          );

          await txTracker.addNotifiedPending(tx.txid);
          break;
        case isar_models.TransactionType.outgoing:
          CryptoNotificationsEventBus.instance.fire(
            CryptoNotificationEvent(
              title: tx.subType == isar_models.TransactionSubType.mint
                  ? "Anonymizing"
                  : "Outgoing transaction",
              walletId: walletId,
              date: DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000),
              shouldWatchForUpdates: confirmations < MINIMUM_CONFIRMATIONS,
              txid: tx.txid,
              confirmations: confirmations,
              requiredConfirmations: MINIMUM_CONFIRMATIONS,
              walletName: walletName,
              coin: coin,
            ),
          );

          await txTracker.addNotifiedPending(tx.txid);
          break;
        default:
          break;
      }
    }

    for (final tx in unconfirmedTxnsToNotifyConfirmed) {
      if (tx.type == isar_models.TransactionType.incoming) {
        CryptoNotificationsEventBus.instance.fire(
          CryptoNotificationEvent(
            title: "Incoming transaction confirmed",
            walletId: walletId,
            date: DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000),
            shouldWatchForUpdates: false,
            txid: tx.txid,
            requiredConfirmations: MINIMUM_CONFIRMATIONS,
            walletName: walletName,
            coin: coin,
          ),
        );

        await txTracker.addNotifiedConfirmed(tx.txid);
      } else if (tx.type == isar_models.TransactionType.outgoing &&
          tx.subType == isar_models.TransactionSubType.join) {
        CryptoNotificationsEventBus.instance.fire(
          CryptoNotificationEvent(
            title: tx.subType ==
                    isar_models.TransactionSubType.mint // redundant check?
                ? "Anonymized"
                : "Outgoing transaction confirmed",
            walletId: walletId,
            date: DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000),
            shouldWatchForUpdates: false,
            txid: tx.txid,
            requiredConfirmations: MINIMUM_CONFIRMATIONS,
            walletName: walletName,
            coin: coin,
          ),
        );
        await txTracker.addNotifiedConfirmed(tx.txid);
      }
    }
  }

  /// Generates initial wallet values such as mnemonic, chain (receive/change) arrays and indexes.
  Future<void> _generateNewWallet() async {
    Logging.instance
        .log("IS_INTEGRATION_TEST: $integrationTestFlag", level: LogLevel.Info);
    if (!integrationTestFlag) {
      try {
        final features = await electrumXClient
            .getServerFeatures()
            .timeout(const Duration(seconds: 3));
        Logging.instance.log("features: $features", level: LogLevel.Info);
        switch (coin) {
          case Coin.firo:
            if (features['genesis_hash'] != GENESIS_HASH_MAINNET) {
              throw Exception("genesis hash does not match main net!");
            }
            break;
          case Coin.firoTestNet:
            if (features['genesis_hash'] != GENESIS_HASH_TESTNET) {
              throw Exception("genesis hash does not match test net!");
            }
            break;
          default:
            throw Exception(
                "Attempted to generate a FiroWallet using a non firo coin type: ${coin.name}");
        }
      } catch (e, s) {
        Logging.instance.log("$e/n$s", level: LogLevel.Info);
      }
    }

    // this should never fail as overwriting a mnemonic is big bad
    if ((await mnemonicString) != null || (await mnemonicPassphrase) != null) {
      longMutex = false;
      throw Exception("Attempted to overwrite mnemonic on initialize new!");
    }
    await _secureStore.write(
        key: '${_walletId}_mnemonic',
        value: bip39.generateMnemonic(strength: 128));
    await _secureStore.write(
      key: '${_walletId}_mnemonicPassphrase',
      value: "",
    );

    await firoUpdateJIndex(<dynamic>[]);
    // Generate and add addresses to relevant arrays
    final initialReceivingAddress = await _generateAddressForChain(0, 0);
    final initialChangeAddress = await _generateAddressForChain(1, 0);

    await db.putAddresses([
      initialReceivingAddress,
      initialChangeAddress,
    ]);
  }

  bool refreshMutex = false;

  @override
  bool get isRefreshing => refreshMutex;

  /// Refreshes display data for the wallet
  @override
  Future<void> refresh() async {
    if (refreshMutex) {
      Logging.instance.log("$walletId $walletName refreshMutex denied",
          level: LogLevel.Info);
      return;
    } else {
      refreshMutex = true;
    }
    Logging.instance
        .log("PROCESSORS ${Platform.numberOfProcessors}", level: LogLevel.Info);
    try {
      GlobalEventBus.instance.fire(
        WalletSyncStatusChangedEvent(
          WalletSyncStatus.syncing,
          walletId,
          coin,
        ),
      );

      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.0, walletId));

      await checkReceivingAddressForTransactions();
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.1, walletId));

      await _refreshUTXOs();
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.2, walletId));

      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.25, walletId));

      await _refreshTransactions();
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.35, walletId));

      final feeObj = _getFees();
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.50, walletId));

      _feeObject = Future(() => feeObj);
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.60, walletId));

      final lelantusCoins = getLelantusCoinMap();
      Logging.instance.log("_lelantus_coins at refresh: $lelantusCoins",
          level: LogLevel.Warning, printFullLength: true);
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.70, walletId));

      await _refreshLelantusData();
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.80, walletId));

      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.90, walletId));

      await _refreshBalance();

      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(0.95, walletId));

      await getAllTxsToWatch();

      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(1.0, walletId));

      GlobalEventBus.instance.fire(
        WalletSyncStatusChangedEvent(
          WalletSyncStatus.synced,
          walletId,
          coin,
        ),
      );
      refreshMutex = false;

      if (isActive || shouldAutoSync) {
        timer ??= Timer.periodic(const Duration(seconds: 30), (timer) async {
          bool shouldNotify = await refreshIfThereIsNewData();
          if (shouldNotify) {
            await refresh();
            GlobalEventBus.instance.fire(UpdatedInBackgroundEvent(
                "New data found in $walletId $walletName in background!",
                walletId));
          }
        });
      }
    } catch (error, strace) {
      refreshMutex = false;
      GlobalEventBus.instance.fire(
        NodeConnectionStatusChangedEvent(
          NodeConnectionStatus.disconnected,
          walletId,
          coin,
        ),
      );
      GlobalEventBus.instance.fire(
        WalletSyncStatusChangedEvent(
          WalletSyncStatus.unableToSync,
          walletId,
          coin,
        ),
      );
      Logging.instance.log(
          "Caught exception in refreshWalletData(): $error\n$strace",
          level: LogLevel.Warning);
    }
  }

  Future<int> _fetchMaxFee() async {
    final balance = availablePrivateBalance();
    int spendAmount =
        (balance.decimal * Decimal.fromInt(Constants.satsPerCoin(coin)))
            .toBigInt()
            .toInt();
    int fee = await estimateJoinSplitFee(spendAmount);
    return fee;
  }

  Future<List<DartLelantusEntry>> _getLelantusEntry() async {
    final _mnemonic = await mnemonicString;
    final _mnemonicPassphrase = await mnemonicPassphrase;
    if (_mnemonicPassphrase == null) {
      Logging.instance.log(
          "Exception in _getLelantusEntry: mnemonic passphrase null, possible migration issue; if using internal builds, delete wallet and restore from seed, if using a release build, please file bug report",
          level: LogLevel.Error);
    }

    final List<LelantusCoin> lelantusCoins = await _getUnspentCoins();

    final root = await Bip32Utils.getBip32Root(
      _mnemonic!,
      _mnemonicPassphrase!,
      _network,
    );

    final waitLelantusEntries = lelantusCoins.map((coin) async {
      final derivePath = constructDerivePath(
        networkWIF: _network.wif,
        chain: MINT_INDEX,
        index: coin.index,
      );
      final keyPair = await Bip32Utils.getBip32NodeFromRoot(root, derivePath);

      if (keyPair.privateKey == null) {
        Logging.instance.log("error bad key", level: LogLevel.Error);
        return DartLelantusEntry(1, 0, 0, 0, 0, '');
      }
      final String privateKey = Format.uint8listToString(keyPair.privateKey!);
      return DartLelantusEntry(coin.isUsed ? 1 : 0, 0, coin.anonymitySetId,
          coin.value, coin.index, privateKey);
    }).toList();

    final lelantusEntries = await Future.wait(waitLelantusEntries);

    if (lelantusEntries.isNotEmpty) {
      lelantusEntries.removeWhere((element) => element.amount == 0);
    }

    return lelantusEntries;
  }

  List<Map<dynamic, LelantusCoin>> getLelantusCoinMap() {
    final _l = firoGetLelantusCoins();
    final List<Map<dynamic, LelantusCoin>> lelantusCoins = [];
    for (var el in _l ?? []) {
      lelantusCoins.add({el.keys.first: el.values.first as LelantusCoin});
    }
    return lelantusCoins;
  }

  Future<List<LelantusCoin>> _getUnspentCoins() async {
    final List<Map<dynamic, LelantusCoin>> lelantusCoins = getLelantusCoinMap();
    if (lelantusCoins.isNotEmpty) {
      lelantusCoins.removeWhere((element) =>
          element.values.any((elementCoin) => elementCoin.value == 0));
    }
    final jindexes = firoGetJIndex();

    List<LelantusCoin> coins = [];

    List<LelantusCoin> lelantusCoinsList =
        lelantusCoins.fold(<LelantusCoin>[], (previousValue, element) {
      previousValue.add(element.values.first);
      return previousValue;
    });

    final currentChainHeight = await chainHeight;

    for (int i = 0; i < lelantusCoinsList.length; i++) {
      // Logging.instance.log("lelantusCoinsList[$i]: ${lelantusCoinsList[i]}");
      final txid = lelantusCoinsList[i].txId;
      final txn = await cachedElectrumXClient.getTransaction(
        txHash: txid,
        verbose: true,
        coin: coin,
      );
      final confirmations = txn["confirmations"];
      bool isUnconfirmed = confirmations is int && confirmations < 1;

      final tx = await db.getTransaction(walletId, txid);

      if (!jindexes!.contains(lelantusCoinsList[i].index) &&
          tx != null &&
          tx.isLelantus == true &&
          !(tx.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS))) {
        isUnconfirmed = true;
      }

      if (tx != null &&
          !tx.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS)) {
        continue;
      }
      if (!lelantusCoinsList[i].isUsed &&
          lelantusCoinsList[i].anonymitySetId != ANONYMITY_SET_EMPTY_ID &&
          !isUnconfirmed) {
        coins.add(lelantusCoinsList[i]);
      }
    }
    return coins;
  }

  // index 0 and 1 for the funds available to spend.
  // index 2 and 3 for all the funds in the wallet (including the undependable ones)
  // Future<List<Decimal>> _refreshBalance() async {
  Future<void> _refreshBalance() async {
    try {
      final utxosUpdateFuture = _refreshUTXOs();
      final List<Map<dynamic, LelantusCoin>> lelantusCoins =
          getLelantusCoinMap();
      if (lelantusCoins.isNotEmpty) {
        lelantusCoins.removeWhere((element) =>
            element.values.any((elementCoin) => elementCoin.value == 0));
      }

      final currentChainHeight = await chainHeight;
      final jindexes = firoGetJIndex();
      int intLelantusBalance = 0;
      int unconfirmedLelantusBalance = 0;

      for (final element in lelantusCoins) {
        element.forEach((key, lelantusCoin) {
          isar_models.Transaction? txn = db.isar.transactions
              .where()
              .txidWalletIdEqualTo(
                lelantusCoin.txId,
                walletId,
              )
              .findFirstSync();

          if (txn == null) {
            // TODO: ??????????????????????????????????????
          } else {
            bool isLelantus = txn.isLelantus == true;
            if (!jindexes!.contains(lelantusCoin.index) && isLelantus) {
              if (!lelantusCoin.isUsed &&
                  txn.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS)) {
                // mint tx, add value to balance
                intLelantusBalance += lelantusCoin.value;
              } /* else {
            // This coin is not confirmed and may be replaced
            }*/
            } else if (jindexes.contains(lelantusCoin.index) &&
                isLelantus &&
                !lelantusCoin.isUsed &&
                !txn.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS)) {
              unconfirmedLelantusBalance += lelantusCoin.value;
            } else if (jindexes.contains(lelantusCoin.index) &&
                !lelantusCoin.isUsed) {
              intLelantusBalance += lelantusCoin.value;
            } else if (!lelantusCoin.isUsed &&
                (txn.isLelantus == true
                    ? true
                    : txn.isConfirmed(
                            currentChainHeight, MINIMUM_CONFIRMATIONS) !=
                        false)) {
              intLelantusBalance += lelantusCoin.value;
            } else if (!isLelantus &&
                txn.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS) ==
                    false) {
              unconfirmedLelantusBalance += lelantusCoin.value;
            }
          }
        });
      }

      _balancePrivate = Balance(
        total: Amount(
          rawValue:
              BigInt.from(intLelantusBalance + unconfirmedLelantusBalance),
          fractionDigits: coin.decimals,
        ),
        spendable: Amount(
          rawValue: BigInt.from(intLelantusBalance),
          fractionDigits: coin.decimals,
        ),
        blockedTotal: Amount(
          rawValue: BigInt.zero,
          fractionDigits: coin.decimals,
        ),
        pendingSpendable: Amount(
          rawValue: BigInt.from(unconfirmedLelantusBalance),
          fractionDigits: coin.decimals,
        ),
      );
      await updateCachedBalanceSecondary(_balancePrivate!);

      // wait for updated uxtos to get updated public balance
      await utxosUpdateFuture;
    } catch (e, s) {
      Logging.instance.log("Exception rethrown in getFullBalance(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<void> anonymizeAllPublicFunds() async {
    try {
      var mintResult = await _mintSelection();
      if (mintResult.isEmpty) {
        Logging.instance.log("nothing to mint", level: LogLevel.Info);
        return;
      }
      await _submitLelantusToNetwork(mintResult);
      unawaited(refresh());
    } catch (e, s) {
      Logging.instance.log(
          "Exception caught in anonymizeAllPublicFunds(): $e\n$s",
          level: LogLevel.Warning);
      rethrow;
    }
  }

  /// Returns the mint transaction hex to mint all of the available funds.
  Future<Map<String, dynamic>> _mintSelection() async {
    final currentChainHeight = await chainHeight;
    final List<isar_models.UTXO> availableOutputs = await utxos;
    final List<isar_models.UTXO?> spendableOutputs = [];

    // Build list of spendable outputs and totaling their satoshi amount
    for (var i = 0; i < availableOutputs.length; i++) {
      if (availableOutputs[i].isBlocked == false &&
          availableOutputs[i]
                  .isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS) ==
              true &&
          !(availableOutputs[i].isCoinbase &&
              availableOutputs[i].getConfirmations(currentChainHeight) <=
                  101)) {
        spendableOutputs.add(availableOutputs[i]);
      }
    }

    final List<Map<dynamic, LelantusCoin>> lelantusCoins = getLelantusCoinMap();
    if (lelantusCoins.isNotEmpty) {
      lelantusCoins.removeWhere((element) =>
          element.values.any((elementCoin) => elementCoin.value == 0));
    }
    final data = await _txnData;
    for (final value in data) {
      if (value.inputs.isNotEmpty) {
        for (var element in value.inputs) {
          if (lelantusCoins
                  .any((element) => element.keys.contains(value.txid)) &&
              spendableOutputs.firstWhere(
                      (output) => output?.txid == element.txid,
                      orElse: () => null) !=
                  null) {
            spendableOutputs
                .removeWhere((output) => output!.txid == element.txid);
          }
        }
      }
    }

    // If there is no Utxos to mint then stop the function.
    if (spendableOutputs.isEmpty) {
      Logging.instance.log("_mintSelection(): No spendable outputs found",
          level: LogLevel.Info);
      return {};
    }

    int satoshisBeingUsed = 0;
    List<isar_models.UTXO> utxoObjectsToUse = [];

    for (var i = 0; i < spendableOutputs.length; i++) {
      final spendable = spendableOutputs[i];
      if (spendable != null) {
        utxoObjectsToUse.add(spendable);
        satoshisBeingUsed += spendable.value;
      }
    }

    var mintsWithoutFee = await createMintsFromAmount(satoshisBeingUsed);

    var tmpTx = await buildMintTransaction(
        utxoObjectsToUse, satoshisBeingUsed, mintsWithoutFee);

    int vSize = (tmpTx['transaction'] as Transaction).virtualSize();
    final Decimal dvSize = Decimal.fromInt(vSize);

    final feesObject = await fees;

    final Decimal fastFee = Amount(
      rawValue: BigInt.from(feesObject.fast),
      fractionDigits: coin.decimals,
    ).decimal;
    int firoFee =
        (dvSize * fastFee * Decimal.fromInt(100000)).toDouble().ceil();
    // int firoFee = (vSize * feesObject.fast * (1 / 1000.0) * 100000000).ceil();

    if (firoFee < vSize) {
      firoFee = vSize + 1;
    }
    firoFee = firoFee + 10;
    int satoshiAmountToSend = satoshisBeingUsed - firoFee;

    var mintsWithFee = await createMintsFromAmount(satoshiAmountToSend);

    Map<String, dynamic> transaction = await buildMintTransaction(
        utxoObjectsToUse, satoshiAmountToSend, mintsWithFee);
    transaction['transaction'] = "";
    Logging.instance.log(transaction.toString(), level: LogLevel.Info);
    Logging.instance.log(transaction['txHex'], level: LogLevel.Info);
    return transaction;
  }

  Future<List<Map<String, dynamic>>> createMintsFromAmount(int total) async {
    var tmpTotal = total;
    var index = 1;
    var mints = <Map<String, dynamic>>[];
    final nextFreeMintIndex = firoGetMintIndex();
    while (tmpTotal > 0) {
      final mintValue = min(tmpTotal, MINT_LIMIT);
      final mint = await _getMintHex(
        mintValue,
        nextFreeMintIndex + index,
      );
      mints.add({
        "value": mintValue,
        "script": mint,
        "index": nextFreeMintIndex + index,
        "publicCoin": "",
      });
      tmpTotal = tmpTotal - MINT_LIMIT;
      index++;
    }
    return mints;
  }

  /// returns a valid txid if successful
  Future<String> submitHexToNetwork(String hex) async {
    try {
      final txid = await electrumXClient.broadcastTransaction(rawTx: hex);
      return txid;
    } catch (e, s) {
      Logging.instance.log(
          "Caught exception in submitHexToNetwork(\"$hex\"): $e $s",
          printFullLength: true,
          level: LogLevel.Info);
      // return an invalid tx
      return "transaction submission failed";
    }
  }

  /// Builds and signs a transaction
  Future<Map<String, dynamic>> buildMintTransaction(
    List<isar_models.UTXO> utxosToUse,
    int satoshisPerRecipient,
    List<Map<String, dynamic>> mintsMap,
  ) async {
    //todo: check if print needed
    // debugPrint(utxosToUse.toString());
    List<String> addressStringsToGet = [];

    // Populating the addresses to derive
    for (var i = 0; i < utxosToUse.length; i++) {
      final txid = utxosToUse[i].txid;
      final outputIndex = utxosToUse[i].vout;

      // txid may not work for this as txid may not always be the same as tx_hash?
      final tx = await cachedElectrumXClient.getTransaction(
        txHash: txid,
        verbose: true,
        coin: coin,
      );

      final vouts = tx["vout"] as List?;
      if (vouts != null && outputIndex < vouts.length) {
        final address =
            vouts[outputIndex]["scriptPubKey"]["addresses"][0] as String?;
        if (address != null) {
          addressStringsToGet.add(address);
        }
      }
    }

    final List<isar_models.Address> addresses = [];
    for (final addressString in addressStringsToGet) {
      final address = await db.getAddress(walletId, addressString);
      if (address == null) {
        Logging.instance.log(
          "Failed to fetch the corresponding address object for $addressString",
          level: LogLevel.Fatal,
        );
      } else {
        addresses.add(address);
      }
    }

    List<ECPair> ellipticCurvePairArray = [];
    List<Uint8List> outputDataArray = [];

    Map<String, dynamic>? receiveDerivations;
    Map<String, dynamic>? changeDerivations;

    for (final addressString in addressStringsToGet) {
      String? pubKey;
      String? wif;

      final address = await db.getAddress(walletId, addressString);

      if (address?.derivationPath != null) {
        final node = await Bip32Utils.getBip32Node(
          (await mnemonicString)!,
          (await mnemonicPassphrase)!,
          _network,
          address!.derivationPath!.value,
        );
        wif = node.toWIF();
        pubKey = Format.uint8listToString(node.publicKey);
      }

      if (wif == null || pubKey == null) {
        receiveDerivations ??= Map<String, dynamic>.from(
          jsonDecode((await _secureStore.read(
                  key: "${walletId}_receiveDerivations")) ??
              "{}") as Map,
        );
        for (var i = 0; i < receiveDerivations.length; i++) {
          final receive = receiveDerivations["$i"];
          if (receive['address'] == addressString) {
            wif = receive['wif'] as String;
            pubKey = receive['publicKey'] as String;
            break;
          }
        }

        if (wif == null || pubKey == null) {
          changeDerivations ??= Map<String, dynamic>.from(
            jsonDecode((await _secureStore.read(
                    key: "${walletId}_changeDerivations")) ??
                "{}") as Map,
          );

          for (var i = 0; i < changeDerivations.length; i++) {
            final change = changeDerivations["$i"];
            if (change['address'] == addressString) {
              wif = change['wif'] as String;
              pubKey = change['publicKey'] as String;

              break;
            }
          }
        }
      }

      ellipticCurvePairArray.add(
        ECPair.fromWIF(
          wif!,
          network: _network,
        ),
      );
      outputDataArray.add(P2PKH(
        network: _network,
        data: PaymentData(
          pubkey: Format.stringToUint8List(
            pubKey!,
          ),
        ),
      ).data.output!);
    }

    final txb = TransactionBuilder(network: _network);
    txb.setVersion(2);

    int height = await getBlockHead(electrumXClient);
    txb.setLockTime(height);
    int amount = 0;
    // Add transaction inputs
    for (var i = 0; i < utxosToUse.length; i++) {
      txb.addInput(
          utxosToUse[i].txid, utxosToUse[i].vout, null, outputDataArray[i]);
      amount += utxosToUse[i].value;
    }

    final index = firoGetMintIndex();
    Logging.instance.log("index of mint $index", level: LogLevel.Info);

    for (var mintsElement in mintsMap) {
      Logging.instance.log("using $mintsElement", level: LogLevel.Info);
      Uint8List mintu8 =
          Format.stringToUint8List(mintsElement['script'] as String);
      txb.addOutput(mintu8, mintsElement['value'] as int);
    }

    for (var i = 0; i < utxosToUse.length; i++) {
      txb.sign(
        vin: i,
        keyPair: ellipticCurvePairArray[i],
        witnessValue: utxosToUse[i].value,
      );
    }
    var incomplete = txb.buildIncomplete();
    var txId = incomplete.getId();
    var txHex = incomplete.toHex();
    int fee = amount - incomplete.outs[0].value!;

    var builtHex = txb.build();
    // return builtHex;
    // final locale =
    //     Platform.isWindows ? "en_US" : await Devicelocale.currentLocale;
    return {
      "transaction": builtHex,
      "txid": txId,
      "txHex": txHex,
      "value": amount - fee,
      "fees": Amount(
        rawValue: BigInt.from(fee),
        fractionDigits: coin.decimals,
      ).decimal.toDouble(),
      "publicCoin": "",
      "height": height,
      "txType": "Sent",
      "confirmed_status": false,
      "amount": Amount(
        rawValue: BigInt.from(amount),
        fractionDigits: coin.decimals,
      ).decimal.toDouble(),
      "timestamp": DateTime.now().millisecondsSinceEpoch ~/ 1000,
      "subType": "mint",
      "mintsMap": mintsMap,
    };
  }

  Future<void> _refreshLelantusData() async {
    final List<Map<dynamic, LelantusCoin>> lelantusCoins = getLelantusCoinMap();
    final jindexes = firoGetJIndex();

    // Get all joinsplit transaction ids

    final listLelantusTxData = await db
        .getTransactions(walletId)
        .filter()
        .isLelantusEqualTo(true)
        .findAll();
    List<String> joinsplits = [];
    for (final tx in listLelantusTxData) {
      if (tx.subType == isar_models.TransactionSubType.join) {
        joinsplits.add(tx.txid);
      }
    }
    for (final coin
        in lelantusCoins.fold(<LelantusCoin>[], (previousValue, element) {
      (previousValue as List<LelantusCoin>).add(element.values.first);
      return previousValue;
    })) {
      if (jindexes != null) {
        if (jindexes.contains(coin.index) && !joinsplits.contains(coin.txId)) {
          joinsplits.add(coin.txId);
        }
      }
    }

    Map<String, Tuple2<isar_models.Address?, isar_models.Transaction>> data =
        {};
    for (final entry in listLelantusTxData) {
      data[entry.txid] = Tuple2(entry.address.value, entry);
    }

    // Grab the most recent information on all the joinsplits

    final updatedJSplit = await getJMintTransactions(
      cachedElectrumXClient,
      joinsplits,
      coin,
    );

    final currentChainHeight = await chainHeight;

    // update all of joinsplits that are now confirmed.
    for (final tx in updatedJSplit.entries) {
      isar_models.Transaction? currentTx;

      try {
        currentTx =
            listLelantusTxData.firstWhere((e) => e.txid == tx.value.txid);
      } catch (_) {
        currentTx = null;
      }

      if (currentTx == null) {
        // this send was accidentally not included in the list
        tx.value.isLelantus = true;
        data[tx.value.txid] =
            Tuple2(tx.value.address.value ?? tx.key, tx.value);

        continue;
      }
      if (currentTx.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS) !=
          tx.value.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS)) {
        tx.value.isLelantus = true;
        data[tx.value.txid] =
            Tuple2(tx.value.address.value ?? tx.key, tx.value);
      }
    }

    // Logging.instance.log(txData.txChunks);
    final listTxData = await _txnData;
    for (final value in listTxData) {
      // ignore change addresses
      // bool hasAtLeastOneReceive = false;
      // int howManyReceiveInputs = 0;
      // for (var element in value.inputs) {
      //   if (listLelantusTxData.containsKey(element.txid) &&
      //           listLelantusTxData[element.txid]!.txType == "Received"
      //       // &&
      //       // listLelantusTxData[element.txid].subType != "mint"
      //       ) {
      //     // hasAtLeastOneReceive = true;
      //     // howManyReceiveInputs++;
      //   }
      // }

      if (value.type == isar_models.TransactionType.incoming &&
          value.subType != isar_models.TransactionSubType.mint) {
        // Every receive other than a mint should be shown. Mints will be collected and shown from the send side
        value.isLelantus = true;
        data[value.txid] = Tuple2(value.address.value, value);
      } else if (value.type == isar_models.TransactionType.outgoing) {
        // all sends should be shown, mints will be displayed correctly in the ui
        value.isLelantus = true;
        data[value.txid] = Tuple2(value.address.value, value);
      }
    }

    // TODO: optimize this whole lelantus process

    final List<Tuple2<isar_models.Transaction, isar_models.Address?>> txnsData =
        [];

    for (final value in data.values) {
      // allow possible null address on mints as we don't display address
      // this should normally never be null anyways but old (dbVersion up to 4)
      // migrated transactions may not have had an address (full rescan should
      // fix this)
      isar_models.Address? transactionAddress;
      try {
        transactionAddress =
            value.item2.subType == isar_models.TransactionSubType.mint
                ? value.item1
                : value.item1!;
      } catch (_) {
        Logging.instance
            .log("_refreshLelantusData value: $value", level: LogLevel.Fatal);
      }
      final outs =
          value.item2.outputs.where((_) => true).toList(growable: false);
      final ins = value.item2.inputs.where((_) => true).toList(growable: false);

      txnsData.add(Tuple2(
          value.item2.copyWith(inputs: ins, outputs: outs).item1,
          transactionAddress));
    }

    await db.addNewTransactionData(txnsData, walletId);

    // // update the _lelantusTransactionData
    // final models.TransactionData newTxData =
    //     models.TransactionData.fromMap(listLelantusTxData);
    // // Logging.instance.log(newTxData.txChunks);
    // _lelantusTransactionData = Future(() => newTxData);
    // await DB.instance.put<dynamic>(
    //     boxName: walletId, key: 'latest_lelantus_tx_model', value: newTxData);
    // return newTxData;
  }

  Future<String> _getMintHex(int amount, int index) async {
    final _mnemonic = await mnemonicString;
    final _mnemonicPassphrase = await mnemonicPassphrase;
    if (_mnemonicPassphrase == null) {
      Logging.instance.log(
          "Exception in _getMintHex: mnemonic passphrase null, possible migration issue; if using internal builds, delete wallet and restore from seed, if using a release build, please file bug report",
          level: LogLevel.Error);
    }

    final derivePath = constructDerivePath(
      networkWIF: _network.wif,
      chain: MINT_INDEX,
      index: index,
    );
    final mintKeyPair = await Bip32Utils.getBip32Node(
      _mnemonic!,
      _mnemonicPassphrase!,
      _network,
      derivePath,
    );

    String keydata = Format.uint8listToString(mintKeyPair.privateKey!);
    String seedID = Format.uint8listToString(mintKeyPair.identifier);

    String mintHex = await compute(
      _getMintScriptWrapper,
      Tuple5(
        amount,
        keydata,
        index,
        seedID,
        coin == Coin.firoTestNet,
      ),
    );
    return mintHex;
  }

  Future<bool> _submitLelantusToNetwork(
      Map<String, dynamic> transactionInfo) async {
    final latestSetId = await getLatestSetId();
    final txid = await submitHexToNetwork(transactionInfo['txHex'] as String);
    // success if txid matches the generated txid
    Logging.instance.log(
        "_submitLelantusToNetwork txid: ${transactionInfo['txid']}",
        level: LogLevel.Info);
    if (txid == transactionInfo['txid']) {
      final index = firoGetMintIndex();
      final List<Map<dynamic, LelantusCoin>> lelantusCoins =
          getLelantusCoinMap();
      List<Map<dynamic, LelantusCoin>> coins;
      if (lelantusCoins.isEmpty) {
        coins = [];
      } else {
        coins = [...lelantusCoins];
      }

      if (transactionInfo['spendCoinIndexes'] != null) {
        // This is a joinsplit

        // Update all of the coins that have been spent.
        for (final lCoinMap in coins) {
          final lCoin = lCoinMap.values.first;
          if ((transactionInfo['spendCoinIndexes'] as List<int>)
              .contains(lCoin.index)) {
            lCoinMap[lCoinMap.keys.first] = LelantusCoin(
                lCoin.index,
                lCoin.value,
                lCoin.publicCoin,
                lCoin.txId,
                lCoin.anonymitySetId,
                true);
          }
        }

        // if a jmint was made add it to the unspent coin index
        LelantusCoin jmint = LelantusCoin(
            index,
            transactionInfo['jmintValue'] as int? ?? 0,
            transactionInfo['publicCoin'] as String,
            transactionInfo['txid'] as String,
            latestSetId,
            false);
        if (jmint.value > 0) {
          coins.add({jmint.txId: jmint});
          final jindexes = firoGetJIndex()!;
          jindexes.add(index);
          await firoUpdateJIndex(jindexes);
          await firoUpdateMintIndex(index + 1);
        }
        await firoUpdateLelantusCoins(coins);

        final amount = Amount.fromDecimal(
          Decimal.parse(transactionInfo["amount"].toString()),
          fractionDigits: coin.decimals,
        );

        // add the send transaction
        final transaction = isar_models.Transaction(
          walletId: walletId,
          txid: transactionInfo['txid'] as String,
          timestamp: transactionInfo['timestamp'] as int? ??
              (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          type: transactionInfo['txType'] == "Received"
              ? isar_models.TransactionType.incoming
              : isar_models.TransactionType.outgoing,
          subType: transactionInfo["subType"] == "mint"
              ? isar_models.TransactionSubType.mint
              : transactionInfo["subType"] == "join"
                  ? isar_models.TransactionSubType.join
                  : isar_models.TransactionSubType.none,
          amount: amount.raw.toInt(),
          amountString: amount.toJsonString(),
          fee: Amount.fromDecimal(
            Decimal.parse(transactionInfo["fees"].toString()),
            fractionDigits: coin.decimals,
          ).raw.toInt(),
          height: transactionInfo["height"] as int?,
          isCancelled: false,
          isLelantus: true,
          slateId: null,
          nonce: null,
          otherData: transactionInfo["otherData"] as String?,
          inputs: [],
          outputs: [],
        );

        final transactionAddress = await db
                .getAddresses(walletId)
                .filter()
                .valueEqualTo(transactionInfo["address"] as String)
                .findFirst() ??
            isar_models.Address(
              walletId: walletId,
              value: transactionInfo["address"] as String,
              derivationIndex: -1,
              derivationPath: null,
              type: isar_models.AddressType.nonWallet,
              subType: isar_models.AddressSubType.nonWallet,
              publicKey: [],
            );

        final List<Tuple2<isar_models.Transaction, isar_models.Address?>>
            txnsData = [];

        txnsData.add(Tuple2(transaction, transactionAddress));

        await db.addNewTransactionData(txnsData, walletId);

        // final models.TransactionData newTxData =
        //     models.TransactionData.fromMap(transactions);
        // await DB.instance.put<dynamic>(
        //     boxName: walletId,
        //     key: 'latest_lelantus_tx_model',
        //     value: newTxData);
        // final ldata = DB.instance.get<dynamic>(
        //     boxName: walletId,
        //     key: 'latest_lelantus_tx_model') as models.TransactionData;
        // _lelantusTransactionData = Future(() => ldata);
      } else {
        // This is a mint
        Logging.instance.log("this is a mint", level: LogLevel.Info);

        // TODO: transactionInfo['mintsMap']
        for (final mintMap
            in transactionInfo['mintsMap'] as List<Map<String, dynamic>>) {
          final index = mintMap['index'] as int?;
          LelantusCoin mint = LelantusCoin(
            index!,
            mintMap['value'] as int,
            mintMap['publicCoin'] as String,
            transactionInfo['txid'] as String,
            latestSetId,
            false,
          );
          if (mint.value > 0) {
            coins.add({mint.txId: mint});
            await firoUpdateMintIndex(index + 1);
          }
        }
        // Logging.instance.log(coins);
        await firoUpdateLelantusCoins(coins);
      }
      return true;
    } else {
      // Failed to send to network
      return false;
    }
  }

  Future<FeeObject> _getFees() async {
    try {
      //TODO adjust numbers for different speeds?
      const int f = 1, m = 5, s = 20;

      final fast = await electrumXClient.estimateFee(blocks: f);
      final medium = await electrumXClient.estimateFee(blocks: m);
      final slow = await electrumXClient.estimateFee(blocks: s);

      final feeObject = FeeObject(
        numberOfBlocksFast: f,
        numberOfBlocksAverage: m,
        numberOfBlocksSlow: s,
        fast: Amount.fromDecimal(
          fast,
          fractionDigits: coin.decimals,
        ).raw.toInt(),
        medium: Amount.fromDecimal(
          medium,
          fractionDigits: coin.decimals,
        ).raw.toInt(),
        slow: Amount.fromDecimal(
          slow,
          fractionDigits: coin.decimals,
        ).raw.toInt(),
      );

      Logging.instance.log("fetched fees: $feeObject", level: LogLevel.Info);
      return feeObject;

      // final result = await electrumXClient.getFeeRate();
      //
      // final locale = await Devicelocale.currentLocale;
      // final String fee =
      //     Format.satoshiAmountToPrettyString(result["rate"] as int, locale!);
      //
      // final fees = {
      //   "fast": fee,
      //   "average": fee,
      //   "slow": fee,
      // };
      // final FeeObject feeObject = FeeObject.fromJson(fees);
      // return feeObject;
    } catch (e) {
      Logging.instance
          .log("Exception rethrown from _getFees(): $e", level: LogLevel.Error);
      rethrow;
    }
  }

  Future<ElectrumXNode> _getCurrentNode() async {
    final node = NodeService(secureStorageInterface: _secureStore)
            .getPrimaryNodeFor(coin: coin) ??
        DefaultNodes.getNodeFor(coin);

    return ElectrumXNode(
      address: node.host,
      port: node.port,
      name: node.name,
      useSSL: node.useSSL,
      id: node.id,
    );
  }

  Future<int> _getTxCount({required String address}) async {
    try {
      final scriptHash = AddressUtils.convertToScriptHash(address, _network);
      final transactions = await electrumXClient.getHistory(
        scripthash: scriptHash,
      );
      return transactions.length;
    } catch (e) {
      Logging.instance.log(
        "Exception rethrown in _getReceivedTxCount(address: $address): $e",
        level: LogLevel.Error,
      );
      rethrow;
    }
  }

  Future<void> checkReceivingAddressForTransactions() async {
    try {
      final currentReceiving = await _currentReceivingAddress;

      final int txCount = await _getTxCount(address: currentReceiving.value);
      Logging.instance.log(
          'Number of txs for current receiving address $currentReceiving: $txCount',
          level: LogLevel.Info);

      if (txCount >= 1 || currentReceiving.derivationIndex < 0) {
        // First increment the receiving index
        final newReceivingIndex = currentReceiving.derivationIndex + 1;

        // Use new index to derive a new receiving address
        final newReceivingAddress = await _generateAddressForChain(
          0,
          newReceivingIndex,
        );

        final existing = await db
            .getAddresses(walletId)
            .filter()
            .valueEqualTo(newReceivingAddress.value)
            .findFirst();
        if (existing == null) {
          // Add that new change address
          await db.putAddress(newReceivingAddress);
        } else {
          // we need to update the address
          await db.updateAddress(existing, newReceivingAddress);
        }
        // keep checking until address with no tx history is set as current
        await checkReceivingAddressForTransactions();
      }
    } on SocketException catch (se, s) {
      Logging.instance.log(
          "SocketException caught in checkReceivingAddressForTransactions(): $se\n$s",
          level: LogLevel.Error);
      return;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown from checkReceivingAddressForTransactions(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<void> checkChangeAddressForTransactions() async {
    try {
      final currentChange = await _currentChangeAddress;
      final int txCount = await _getTxCount(address: currentChange.value);
      Logging.instance.log(
          'Number of txs for current change address: $currentChange: $txCount',
          level: LogLevel.Info);

      if (txCount >= 1 || currentChange.derivationIndex < 0) {
        // First increment the change index
        final newChangeIndex = currentChange.derivationIndex + 1;

        // Use new index to derive a new change address
        final newChangeAddress = await _generateAddressForChain(
          1,
          newChangeIndex,
        );

        final existing = await db
            .getAddresses(walletId)
            .filter()
            .valueEqualTo(newChangeAddress.value)
            .findFirst();
        if (existing == null) {
          // Add that new change address
          await db.putAddress(newChangeAddress);
        } else {
          // we need to update the address
          await db.updateAddress(existing, newChangeAddress);
        }
        // keep checking until address with no tx history is set as current
        await checkChangeAddressForTransactions();
      }
    } on SocketException catch (se, s) {
      Logging.instance.log(
          "SocketException caught in checkChangeAddressForTransactions(): $se\n$s",
          level: LogLevel.Error);
      return;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown from checkChangeAddressForTransactions(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<List<isar_models.Address>> _fetchAllOwnAddresses() async {
    final allAddresses = await db
        .getAddresses(walletId)
        .filter()
        .not()
        .group(
          (q) => q
              .typeEqualTo(isar_models.AddressType.nonWallet)
              .or()
              .subTypeEqualTo(isar_models.AddressSubType.nonWallet),
        )
        .findAll();
    return allAddresses;
  }

  Future<List<Map<String, dynamic>>> _fetchHistory(
      List<String> allAddresses) async {
    try {
      List<Map<String, dynamic>> allTxHashes = [];

      final Map<int, Map<String, List<dynamic>>> batches = {};
      final Map<String, String> requestIdToAddressMap = {};
      const batchSizeMax = 100;
      int batchNumber = 0;
      for (int i = 0; i < allAddresses.length; i++) {
        if (batches[batchNumber] == null) {
          batches[batchNumber] = {};
        }
        final scripthash =
            AddressUtils.convertToScriptHash(allAddresses[i], _network);
        final id = Logger.isTestEnv ? "$i" : const Uuid().v1();
        requestIdToAddressMap[id] = allAddresses[i];
        batches[batchNumber]!.addAll({
          id: [scripthash]
        });
        if (i % batchSizeMax == batchSizeMax - 1) {
          batchNumber++;
        }
      }

      for (int i = 0; i < batches.length; i++) {
        final response =
            await _electrumXClient.getBatchHistory(args: batches[i]!);
        for (final entry in response.entries) {
          for (int j = 0; j < entry.value.length; j++) {
            entry.value[j]["address"] = requestIdToAddressMap[entry.key];
            if (!allTxHashes.contains(entry.value[j])) {
              allTxHashes.add(entry.value[j]);
            }
          }
        }
      }

      return allTxHashes;
    } catch (e, s) {
      Logging.instance.log("_fetchHistory: $e\n$s", level: LogLevel.Error);
      rethrow;
    }
  }

  bool _duplicateTxCheck(
      List<Map<String, dynamic>> allTransactions, String txid) {
    for (int i = 0; i < allTransactions.length; i++) {
      if (allTransactions[i]["txid"] == txid) {
        return true;
      }
    }
    return false;
  }

  Future<void> _refreshTransactions() async {
    final List<isar_models.Address> allAddresses =
        await _fetchAllOwnAddresses();

    Set<String> receivingAddresses = allAddresses
        .where((e) => e.subType == isar_models.AddressSubType.receiving)
        .map((e) => e.value)
        .toSet();
    Set<String> changeAddresses = allAddresses
        .where((e) => e.subType == isar_models.AddressSubType.change)
        .map((e) => e.value)
        .toSet();

    final List<Map<String, dynamic>> allTxHashes =
        await _fetchHistory(allAddresses.map((e) => e.value).toList());

    List<Map<String, dynamic>> allTransactions = [];

    final currentHeight = await chainHeight;

    for (final txHash in allTxHashes) {
      final storedTx = await db
          .getTransactions(walletId)
          .filter()
          .txidEqualTo(txHash["tx_hash"] as String)
          .findFirst();

      if (storedTx == null ||
          !storedTx.isConfirmed(currentHeight, MINIMUM_CONFIRMATIONS)) {
        final tx = await cachedElectrumXClient.getTransaction(
          txHash: txHash["tx_hash"] as String,
          verbose: true,
          coin: coin,
        );

        if (!_duplicateTxCheck(allTransactions, tx["txid"] as String)) {
          tx["address"] = await db
              .getAddresses(walletId)
              .filter()
              .valueEqualTo(txHash["address"] as String)
              .findFirst();
          tx["height"] = txHash["height"];
          allTransactions.add(tx);
        }
      }
    }

    final List<Tuple2<isar_models.Transaction, isar_models.Address?>> txnsData =
        [];

    for (final txObject in allTransactions) {
      final inputList = txObject["vin"] as List;
      final outputList = txObject["vout"] as List;

      bool isMint = false;
      bool isJMint = false;

      // check if tx is Mint or jMint
      for (final output in outputList) {
        if (output["scriptPubKey"]?["type"] == "lelantusmint") {
          final asm = output["scriptPubKey"]?["asm"] as String?;
          if (asm != null) {
            if (asm.startsWith("OP_LELANTUSJMINT")) {
              isJMint = true;
              break;
            } else if (asm.startsWith("OP_LELANTUSMINT")) {
              isMint = true;
              break;
            } else {
              Logging.instance.log(
                "Unknown mint op code found for lelantusmint tx: ${txObject["txid"]}",
                level: LogLevel.Error,
              );
            }
          } else {
            Logging.instance.log(
              "ASM for lelantusmint tx: ${txObject["txid"]} is null!",
              level: LogLevel.Error,
            );
          }
        }
      }

      Set<String> inputAddresses = {};
      Set<String> outputAddresses = {};

      Amount totalInputValue = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );
      Amount totalOutputValue = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );

      Amount amountSentFromWallet = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );
      Amount amountReceivedInWallet = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );
      Amount changeAmount = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );

      // Parse mint transaction ================================================
      // We should be able to assume this belongs to this wallet
      if (isMint) {
        List<isar_models.Input> ins = [];

        // Parse inputs
        for (final input in inputList) {
          // Both value and address should not be null for a mint
          final address = input["address"] as String?;
          final value = input["valueSat"] as int?;

          // We should not need to check whether the mint belongs to this
          // wallet as any tx we look up will be looked up by one of this
          // wallet's addresses
          if (address != null && value != null) {
            totalInputValue += value.toAmountAsRaw(
              fractionDigits: coin.decimals,
            );
          }

          ins.add(
            isar_models.Input(
              txid: input['txid'] as String? ?? "",
              vout: input['vout'] as int? ?? -1,
              scriptSig: input['scriptSig']?['hex'] as String?,
              scriptSigAsm: input['scriptSig']?['asm'] as String?,
              isCoinbase: input['is_coinbase'] as bool?,
              sequence: input['sequence'] as int?,
              innerRedeemScriptAsm: input['innerRedeemscriptAsm'] as String?,
            ),
          );
        }

        // Parse outputs
        for (final output in outputList) {
          // get value
          final value = Amount.fromDecimal(
            Decimal.parse(output["value"].toString()),
            fractionDigits: coin.decimals,
          );

          // add value to total
          totalOutputValue += value;
        }

        final fee = totalInputValue - totalOutputValue;
        final tx = isar_models.Transaction(
          walletId: walletId,
          txid: txObject["txid"] as String,
          timestamp: txObject["blocktime"] as int? ??
              (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          type: isar_models.TransactionType.sentToSelf,
          subType: isar_models.TransactionSubType.mint,
          amount: totalOutputValue.raw.toInt(),
          amountString: totalOutputValue.toJsonString(),
          fee: fee.raw.toInt(),
          height: txObject["height"] as int?,
          isCancelled: false,
          isLelantus: true,
          slateId: null,
          otherData: null,
          nonce: null,
          inputs: ins,
          outputs: [],
        );

        txnsData.add(Tuple2(tx, null));

        // Otherwise parse JMint transaction ===================================
      } else if (isJMint) {
        Amount jMintFees = Amount(
          rawValue: BigInt.zero,
          fractionDigits: coin.decimals,
        );

        // Parse inputs
        List<isar_models.Input> ins = [];
        for (final input in inputList) {
          // JMint fee
          final nFee = Decimal.tryParse(input["nFees"].toString());
          if (nFee != null) {
            final fees = Amount.fromDecimal(
              nFee,
              fractionDigits: coin.decimals,
            );

            jMintFees += fees;
          }

          ins.add(
            isar_models.Input(
              txid: input['txid'] as String? ?? "",
              vout: input['vout'] as int? ?? -1,
              scriptSig: input['scriptSig']?['hex'] as String?,
              scriptSigAsm: input['scriptSig']?['asm'] as String?,
              isCoinbase: input['is_coinbase'] as bool?,
              sequence: input['sequence'] as int?,
              innerRedeemScriptAsm: input['innerRedeemscriptAsm'] as String?,
            ),
          );
        }

        bool nonWalletAddressFoundInOutputs = false;

        // Parse outputs
        List<isar_models.Output> outs = [];
        for (final output in outputList) {
          // get value
          final value = Amount.fromDecimal(
            Decimal.parse(output["value"].toString()),
            fractionDigits: coin.decimals,
          );

          // add value to total
          totalOutputValue += value;

          final address = output["scriptPubKey"]?["addresses"]?[0] as String? ??
              output['scriptPubKey']?['address'] as String?;

          if (address != null) {
            outputAddresses.add(address);
            if (receivingAddresses.contains(address) ||
                changeAddresses.contains(address)) {
              amountReceivedInWallet += value;
            } else {
              nonWalletAddressFoundInOutputs = true;
            }
          }

          outs.add(
            isar_models.Output(
              scriptPubKey: output['scriptPubKey']?['hex'] as String?,
              scriptPubKeyAsm: output['scriptPubKey']?['asm'] as String?,
              scriptPubKeyType: output['scriptPubKey']?['type'] as String?,
              scriptPubKeyAddress: address ?? "jmint",
              value: value.raw.toInt(),
            ),
          );
        }

        const subType = isar_models.TransactionSubType.join;
        final type = nonWalletAddressFoundInOutputs
            ? isar_models.TransactionType.outgoing
            : isar_models.TransactionType.incoming;

        final amount = nonWalletAddressFoundInOutputs
            ? totalOutputValue
            : amountReceivedInWallet;

        final possibleNonWalletAddresses =
            receivingAddresses.difference(outputAddresses);
        final possibleReceivingAddresses =
            receivingAddresses.intersection(outputAddresses);

        final transactionAddress = nonWalletAddressFoundInOutputs
            ? isar_models.Address(
                walletId: walletId,
                value: possibleNonWalletAddresses.first,
                derivationIndex: -1,
                derivationPath: null,
                type: isar_models.AddressType.nonWallet,
                subType: isar_models.AddressSubType.nonWallet,
                publicKey: [],
              )
            : allAddresses.firstWhere(
                (e) => e.value == possibleReceivingAddresses.first,
              );

        final tx = isar_models.Transaction(
          walletId: walletId,
          txid: txObject["txid"] as String,
          timestamp: txObject["blocktime"] as int? ??
              (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          type: type,
          subType: subType,
          amount: amount.raw.toInt(),
          amountString: amount.toJsonString(),
          fee: jMintFees.raw.toInt(),
          height: txObject["height"] as int?,
          isCancelled: false,
          isLelantus: true,
          slateId: null,
          otherData: null,
          nonce: null,
          inputs: ins,
          outputs: outs,
        );

        txnsData.add(Tuple2(tx, transactionAddress));

        // Assume non lelantus transaction =====================================
      } else {
        // parse inputs
        List<isar_models.Input> ins = [];
        for (final input in inputList) {
          final valueSat = input["valueSat"] as int?;
          final address = input["address"] as String? ??
              input["scriptPubKey"]?["address"] as String? ??
              input["scriptPubKey"]?["addresses"]?[0] as String?;

          if (address != null && valueSat != null) {
            final value = valueSat.toAmountAsRaw(
              fractionDigits: coin.decimals,
            );

            // add value to total
            totalInputValue += value;
            inputAddresses.add(address);

            // if input was from my wallet, add value to amount sent
            if (receivingAddresses.contains(address) ||
                changeAddresses.contains(address)) {
              amountSentFromWallet += value;
            }
          }

          ins.add(
            isar_models.Input(
              txid: input['txid'] as String,
              vout: input['vout'] as int? ?? -1,
              scriptSig: input['scriptSig']?['hex'] as String?,
              scriptSigAsm: input['scriptSig']?['asm'] as String?,
              isCoinbase: input['is_coinbase'] as bool?,
              sequence: input['sequence'] as int?,
              innerRedeemScriptAsm: input['innerRedeemscriptAsm'] as String?,
            ),
          );
        }

        // parse outputs
        List<isar_models.Output> outs = [];
        for (final output in outputList) {
          // get value
          final value = Amount.fromDecimal(
            Decimal.parse(output["value"].toString()),
            fractionDigits: coin.decimals,
          );

          // add value to total
          totalOutputValue += value;

          // get output address
          final address = output["scriptPubKey"]?["addresses"]?[0] as String? ??
              output["scriptPubKey"]?["address"] as String?;
          if (address != null) {
            outputAddresses.add(address);

            // if output was to my wallet, add value to amount received
            if (receivingAddresses.contains(address)) {
              amountReceivedInWallet += value;
            } else if (changeAddresses.contains(address)) {
              changeAmount += value;
            }
          }

          outs.add(
            isar_models.Output(
              scriptPubKey: output['scriptPubKey']?['hex'] as String?,
              scriptPubKeyAsm: output['scriptPubKey']?['asm'] as String?,
              scriptPubKeyType: output['scriptPubKey']?['type'] as String?,
              scriptPubKeyAddress: address ?? "",
              value: value.raw.toInt(),
            ),
          );
        }

        final mySentFromAddresses = [
          ...receivingAddresses.intersection(inputAddresses),
          ...changeAddresses.intersection(inputAddresses)
        ];
        final myReceivedOnAddresses =
            receivingAddresses.intersection(outputAddresses);
        final myChangeReceivedOnAddresses =
            changeAddresses.intersection(outputAddresses);

        final fee = totalInputValue - totalOutputValue;

        // this is the address initially used to fetch the txid
        isar_models.Address transactionAddress =
            txObject["address"] as isar_models.Address;

        isar_models.TransactionType type;
        Amount amount;
        if (mySentFromAddresses.isNotEmpty &&
            myReceivedOnAddresses.isNotEmpty) {
          // tx is sent to self
          type = isar_models.TransactionType.sentToSelf;

          // should be 0
          amount = amountSentFromWallet -
              amountReceivedInWallet -
              fee -
              changeAmount;
        } else if (mySentFromAddresses.isNotEmpty) {
          // outgoing tx
          type = isar_models.TransactionType.outgoing;
          amount = amountSentFromWallet - changeAmount - fee;

          final possible =
              outputAddresses.difference(myChangeReceivedOnAddresses).first;

          if (transactionAddress.value != possible) {
            transactionAddress = isar_models.Address(
              walletId: walletId,
              value: possible,
              derivationIndex: -1,
              derivationPath: null,
              subType: isar_models.AddressSubType.nonWallet,
              type: isar_models.AddressType.nonWallet,
              publicKey: [],
            );
          }
        } else {
          // incoming tx
          type = isar_models.TransactionType.incoming;
          amount = amountReceivedInWallet;
        }

        final tx = isar_models.Transaction(
          walletId: walletId,
          txid: txObject["txid"] as String,
          timestamp: txObject["blocktime"] as int? ??
              (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          type: type,
          subType: isar_models.TransactionSubType.none,
          // amount may overflow. Deprecated. Use amountString
          amount: amount.raw.toInt(),
          amountString: amount.toJsonString(),
          fee: fee.raw.toInt(),
          height: txObject["height"] as int?,
          isCancelled: false,
          isLelantus: false,
          slateId: null,
          otherData: null,
          nonce: null,
          inputs: ins,
          outputs: outs,
        );

        txnsData.add(Tuple2(tx, transactionAddress));
      }
    }

    await db.addNewTransactionData(txnsData, walletId);

    // quick hack to notify manager to call notifyListeners if
    // transactions changed
    if (txnsData.isNotEmpty) {
      GlobalEventBus.instance.fire(
        UpdatedInBackgroundEvent(
          "Transactions updated/added for: $walletId $walletName  ",
          walletId,
        ),
      );
    }
  }

  Future<void> _refreshUTXOs() async {
    final allAddresses = await _fetchAllOwnAddresses();

    try {
      final fetchedUtxoList = <List<Map<String, dynamic>>>[];

      final Map<int, Map<String, List<dynamic>>> batches = {};
      const batchSizeMax = 100;
      int batchNumber = 0;
      for (int i = 0; i < allAddresses.length; i++) {
        if (batches[batchNumber] == null) {
          batches[batchNumber] = {};
        }
        final scripthash =
            AddressUtils.convertToScriptHash(allAddresses[i].value, _network);
        batches[batchNumber]!.addAll({
          scripthash: [scripthash]
        });
        if (i % batchSizeMax == batchSizeMax - 1) {
          batchNumber++;
        }
      }

      for (int i = 0; i < batches.length; i++) {
        final response =
            await _electrumXClient.getBatchUTXOs(args: batches[i]!);
        for (final entry in response.entries) {
          if (entry.value.isNotEmpty) {
            fetchedUtxoList.add(entry.value);
          }
        }
      }

      final currentChainHeight = await chainHeight;

      final List<isar_models.UTXO> outputArray = [];
      Amount satoshiBalanceTotal = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );
      Amount satoshiBalancePending = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );
      Amount satoshiBalanceSpendable = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );
      Amount satoshiBalanceBlocked = Amount(
        rawValue: BigInt.zero,
        fractionDigits: coin.decimals,
      );

      for (int i = 0; i < fetchedUtxoList.length; i++) {
        for (int j = 0; j < fetchedUtxoList[i].length; j++) {
          final txn = await cachedElectrumXClient.getTransaction(
            txHash: fetchedUtxoList[i][j]["tx_hash"] as String,
            verbose: true,
            coin: coin,
          );

          // todo check here if we should mark as blocked
          final utxo = isar_models.UTXO(
            walletId: walletId,
            txid: txn["txid"] as String,
            vout: fetchedUtxoList[i][j]["tx_pos"] as int,
            value: fetchedUtxoList[i][j]["value"] as int,
            name: "",
            isBlocked: false,
            blockedReason: null,
            isCoinbase: txn["is_coinbase"] as bool? ?? false,
            blockHash: txn["blockhash"] as String?,
            blockHeight: fetchedUtxoList[i][j]["height"] as int?,
            blockTime: txn["blocktime"] as int?,
          );

          final utxoAmount = Amount(
            rawValue: BigInt.from(utxo.value),
            fractionDigits: coin.decimals,
          );
          satoshiBalanceTotal = satoshiBalanceTotal + utxoAmount;

          if (utxo.isBlocked) {
            satoshiBalanceBlocked = satoshiBalanceBlocked + utxoAmount;
          } else {
            if (utxo.isConfirmed(currentChainHeight, MINIMUM_CONFIRMATIONS)) {
              satoshiBalanceSpendable = satoshiBalanceSpendable + utxoAmount;
            } else {
              satoshiBalancePending = satoshiBalancePending + utxoAmount;
            }
          }

          outputArray.add(utxo);
        }
      }

      Logging.instance
          .log('Outputs fetched: $outputArray', level: LogLevel.Info);

      // TODO move this out of here and into IDB
      await db.isar.writeTxn(() async {
        await db.isar.utxos.where().walletIdEqualTo(walletId).deleteAll();
        await db.isar.utxos.putAll(outputArray);
      });

      // finally update public balance
      _balance = Balance(
        total: satoshiBalanceTotal,
        spendable: satoshiBalanceSpendable,
        blockedTotal: satoshiBalanceBlocked,
        pendingSpendable: satoshiBalancePending,
      );
      await updateCachedBalance(_balance!);
    } catch (e, s) {
      Logging.instance
          .log("Output fetch unsuccessful: $e\n$s", level: LogLevel.Error);
    }
  }

  /// Returns the latest receiving/change (external/internal) address for the wallet depending on [chain]
  /// [chain] - Use 0 for receiving (external), 1 for change (internal). Should not be any other value!
  Future<String> _getCurrentAddressForChain(int chain) async {
    final subType = chain == 0 // Here, we assume that chain == 1 if it isn't 0
        ? isar_models.AddressSubType.receiving
        : isar_models.AddressSubType.change;

    isar_models.Address? address = await db
        .getAddresses(walletId)
        .filter()
        .typeEqualTo(isar_models.AddressType.p2pkh)
        .subTypeEqualTo(subType)
        .sortByDerivationIndexDesc()
        .findFirst();

    return address!.value;
  }

  /// Generates a new internal or external chain address for the wallet using a BIP84 derivation path.
  /// [chain] - Use 0 for receiving (external), 1 for change (internal). Should not be any other value!
  /// [index] - This can be any integer >= 0
  Future<isar_models.Address> _generateAddressForChain(
      int chain, int index) async {
    final _mnemonic = await mnemonicString;
    final _mnemonicPassphrase = await mnemonicPassphrase;
    if (_mnemonicPassphrase == null) {
      Logging.instance.log(
          "Exception in _generateAddressForChain: mnemonic passphrase null,"
          " possible migration issue; if using internal builds, delete "
          "wallet and restore from seed, if using a release build, "
          "please file bug report",
          level: LogLevel.Error);
    }

    final derivePath = constructDerivePath(
      networkWIF: _network.wif,
      chain: chain,
      index: index,
    );

    final node = await Bip32Utils.getBip32Node(
      _mnemonic!,
      _mnemonicPassphrase!,
      _network,
      derivePath,
    );

    final address = P2PKH(
      network: _network,
      data: PaymentData(
        pubkey: node.publicKey,
      ),
    ).data.address!;

    return isar_models.Address(
      walletId: walletId,
      value: address,
      publicKey: node.publicKey,
      type: isar_models.AddressType.p2pkh,
      derivationIndex: index,
      derivationPath: isar_models.DerivationPath()..value = derivePath,
      subType: chain == 0
          ? isar_models.AddressSubType.receiving
          : isar_models.AddressSubType.change,
    );
  }

  // /// Takes in a list of isar_models.UTXOs and adds a name (dependent on object index within list)
  // /// and checks for the txid associated with the utxo being blocked and marks it accordingly.
  // /// Now also checks for output labeling.
  // Future<void> _sortOutputs(List<isar_models.UTXO> utxos) async {
  //   final blockedHashArray =
  //       DB.instance.get<dynamic>(boxName: walletId, key: 'blocked_tx_hashes')
  //           as List<dynamic>?;
  //   final List<String> lst = [];
  //   if (blockedHashArray != null) {
  //     for (var hash in blockedHashArray) {
  //       lst.add(hash as String);
  //     }
  //   }
  //   final labels =
  //       DB.instance.get<dynamic>(boxName: walletId, key: 'labels') as Map? ??
  //           {};
  //
  //   _outputsList = [];
  //
  //   for (var i = 0; i < utxos.length; i++) {
  //     if (labels[utxos[i].txid] != null) {
  //       utxos[i].txName = labels[utxos[i].txid] as String? ?? "";
  //     } else {
  //       utxos[i].txName = 'Output #$i';
  //     }
  //
  //     if (utxos[i].status.confirmed == false) {
  //       _outputsList.add(utxos[i]);
  //     } else {
  //       if (lst.contains(utxos[i].txid)) {
  //         utxos[i].blocked = true;
  //         _outputsList.add(utxos[i]);
  //       } else if (!lst.contains(utxos[i].txid)) {
  //         _outputsList.add(utxos[i]);
  //       }
  //     }
  //   }
  // }

  @override
  Future<void> fullRescan(
    int maxUnusedAddressGap,
    int maxNumberOfIndexesToCheck,
  ) async {
    Logging.instance.log("Starting full rescan!", level: LogLevel.Info);
    // timer?.cancel();
    // for (final isolate in isolates.values) {
    //   isolate.kill(priority: Isolate.immediate);
    // }
    // isolates.clear();
    longMutex = true;
    GlobalEventBus.instance.fire(
      WalletSyncStatusChangedEvent(
        WalletSyncStatus.syncing,
        walletId,
        coin,
      ),
    );

    // clear cache
    await _cachedElectrumXClient.clearSharedTransactionCache(coin: coin);

    // back up data
    // await _rescanBackup();

    // clear blockchain info
    await db.deleteWalletBlockchainData(walletId);
    await _deleteDerivations();

    try {
      final _mnemonic = await mnemonicString;
      final _mnemonicPassphrase = await mnemonicPassphrase;
      if (_mnemonicPassphrase == null) {
        Logging.instance.log(
            "Exception in fullRescan: mnemonic passphrase null, possible migration issue; if using internal builds, delete wallet and restore from seed, if using a release build, please file bug report",
            level: LogLevel.Error);
      }

      await _recoverWalletFromBIP32SeedPhrase(
        _mnemonic!,
        _mnemonicPassphrase!,
        maxUnusedAddressGap,
        maxNumberOfIndexesToCheck,
        true,
      );

      longMutex = false;
      await refresh();
      Logging.instance.log("Full rescan complete!", level: LogLevel.Info);
      GlobalEventBus.instance.fire(
        WalletSyncStatusChangedEvent(
          WalletSyncStatus.synced,
          walletId,
          coin,
        ),
      );
    } catch (e, s) {
      GlobalEventBus.instance.fire(
        WalletSyncStatusChangedEvent(
          WalletSyncStatus.unableToSync,
          walletId,
          coin,
        ),
      );

      // restore from backup
      // await _rescanRestore();

      longMutex = false;
      Logging.instance.log("Exception rethrown from fullRescan(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<void> _deleteDerivations() async {
    // P2PKH derivations
    await _secureStore.delete(key: "${walletId}_receiveDerivations");
    await _secureStore.delete(key: "${walletId}_changeDerivations");
  }

  /// wrapper for _recoverWalletFromBIP32SeedPhrase()
  @override
  Future<void> recoverFromMnemonic({
    required String mnemonic,
    String? mnemonicPassphrase,
    required int maxUnusedAddressGap,
    required int maxNumberOfIndexesToCheck,
    required int height,
  }) async {
    try {
      await compute(
        _setTestnetWrapper,
        coin == Coin.firoTestNet,
      );
      Logging.instance.log("IS_INTEGRATION_TEST: $integrationTestFlag",
          level: LogLevel.Info);
      if (!integrationTestFlag) {
        final features = await electrumXClient.getServerFeatures();
        Logging.instance.log("features: $features", level: LogLevel.Info);
        switch (coin) {
          case Coin.firo:
            if (features['genesis_hash'] != GENESIS_HASH_MAINNET) {
              throw Exception("genesis hash does not match main net!");
            }
            break;
          case Coin.firoTestNet:
            if (features['genesis_hash'] != GENESIS_HASH_TESTNET) {
              throw Exception("genesis hash does not match test net!");
            }
            break;
          default:
            throw Exception(
                "Attempted to generate a FiroWallet using a non firo coin type: ${coin.name}");
        }
        // if (_networkType == BasicNetworkType.main) {
        //   if (features['genesis_hash'] != GENESIS_HASH_MAINNET) {
        //     throw Exception("genesis hash does not match main net!");
        //   }
        // } else if (_networkType == BasicNetworkType.test) {
        //   if (features['genesis_hash'] != GENESIS_HASH_TESTNET) {
        //     throw Exception("genesis hash does not match test net!");
        //   }
        // }
      }
      // this should never fail
      if ((await mnemonicString) != null ||
          (await this.mnemonicPassphrase) != null) {
        longMutex = false;
        throw Exception("Attempted to overwrite mnemonic on restore!");
      }
      await _secureStore.write(
          key: '${_walletId}_mnemonic', value: mnemonic.trim());
      await _secureStore.write(
        key: '${_walletId}_mnemonicPassphrase',
        value: mnemonicPassphrase ?? "",
      );
      await _recoverWalletFromBIP32SeedPhrase(
        mnemonic.trim(),
        mnemonicPassphrase ?? "",
        maxUnusedAddressGap,
        maxNumberOfIndexesToCheck,
        false,
      );

      await compute(
        _setTestnetWrapper,
        false,
      );
    } catch (e, s) {
      await compute(
        _setTestnetWrapper,
        false,
      );
      Logging.instance.log(
          "Exception rethrown from recoverFromMnemonic(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  bool longMutex = false;

  Future<Map<int, dynamic>> getSetDataMap(int latestSetId) async {
    final Map<int, dynamic> setDataMap = {};
    final anonymitySets = await fetchAnonymitySets();
    for (int setId = 1; setId <= latestSetId; setId++) {
      final setData = anonymitySets
          .firstWhere((element) => element["setId"] == setId, orElse: () => {});

      if (setData.isNotEmpty) {
        setDataMap[setId] = setData;
      }
    }
    return setDataMap;
  }

  Future<Map<String, int>> _getBatchTxCount({
    required Map<String, String> addresses,
  }) async {
    try {
      final Map<String, List<dynamic>> args = {};
      for (final entry in addresses.entries) {
        args[entry.key] = [
          AddressUtils.convertToScriptHash(entry.value, _network)
        ];
      }
      final response = await electrumXClient.getBatchHistory(args: args);

      final Map<String, int> result = {};
      for (final entry in response.entries) {
        result[entry.key] = entry.value.length;
      }
      return result;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown in _getBatchTxCount(address: $addresses: $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<Tuple2<List<isar_models.Address>, int>> _checkGaps(
    int maxNumberOfIndexesToCheck,
    int maxUnusedAddressGap,
    int txCountBatchSize,
    bip32.BIP32 root,
    int chain,
  ) async {
    List<isar_models.Address> addressArray = [];
    int gapCounter = 0;
    int highestIndexWithHistory = 0;

    for (int index = 0;
        index < maxNumberOfIndexesToCheck && gapCounter < maxUnusedAddressGap;
        index += txCountBatchSize) {
      List<String> iterationsAddressArray = [];
      Logging.instance.log(
        "index: $index, \t GapCounter $chain: $gapCounter",
        level: LogLevel.Info,
      );

      final _id = "k_$index";
      Map<String, String> txCountCallArgs = {};

      for (int j = 0; j < txCountBatchSize; j++) {
        final derivePath = constructDerivePath(
          networkWIF: root.network.wif,
          chain: chain,
          index: index + j,
        );
        final node = await Bip32Utils.getBip32NodeFromRoot(root, derivePath);

        final data = PaymentData(pubkey: node.publicKey);
        final String addressString = P2PKH(
          data: data,
          network: _network,
        ).data.address!;
        const isar_models.AddressType addrType = isar_models.AddressType.p2pkh;

        final address = isar_models.Address(
          walletId: walletId,
          value: addressString,
          publicKey: node.publicKey,
          type: addrType,
          derivationIndex: index + j,
          derivationPath: isar_models.DerivationPath()..value = derivePath,
          subType: chain == 0
              ? isar_models.AddressSubType.receiving
              : isar_models.AddressSubType.change,
        );

        addressArray.add(address);

        txCountCallArgs.addAll({
          "${_id}_$j": addressString,
        });
      }

      // get address tx counts
      final counts = await _getBatchTxCount(addresses: txCountCallArgs);

      // check and add appropriate addresses
      for (int k = 0; k < txCountBatchSize; k++) {
        int count = counts["${_id}_$k"]!;
        if (count > 0) {
          iterationsAddressArray.add(txCountCallArgs["${_id}_$k"]!);

          // update highest
          highestIndexWithHistory = index + k;

          // reset counter
          gapCounter = 0;
        }

        // increase counter when no tx history found
        if (count == 0) {
          gapCounter++;
        }
      }
      // cache all the transactions while waiting for the current function to finish.
      unawaited(getTransactionCacheEarly(iterationsAddressArray));
    }
    return Tuple2(addressArray, highestIndexWithHistory);
  }

  Future<void> getTransactionCacheEarly(List<String> allAddresses) async {
    try {
      final List<Map<String, dynamic>> allTxHashes =
          await _fetchHistory(allAddresses);
      for (final txHash in allTxHashes) {
        try {
          unawaited(cachedElectrumXClient.getTransaction(
            txHash: txHash["tx_hash"] as String,
            verbose: true,
            coin: coin,
          ));
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      //
    }
  }

  Future<void> _recoverHistory(
    String suppliedMnemonic,
    String mnemonicPassphrase,
    int maxUnusedAddressGap,
    int maxNumberOfIndexesToCheck,
    bool isRescan,
  ) async {
    final root = await Bip32Utils.getBip32Root(
      suppliedMnemonic,
      mnemonicPassphrase,
      _network,
    );

    final List<Future<Tuple2<List<isar_models.Address>, int>>> receiveFutures =
        [];
    final List<Future<Tuple2<List<isar_models.Address>, int>>> changeFutures =
        [];

    const receiveChain = 0;
    const changeChain = 1;
    const indexZero = 0;

    // actual size is 36 due to p2pkh, p2sh, and p2wpkh so 12x3
    const txCountBatchSize = 12;

    try {
      // receiving addresses
      Logging.instance.log(
        "checking receiving addresses...",
        level: LogLevel.Info,
      );

      receiveFutures.add(
        _checkGaps(
          maxNumberOfIndexesToCheck,
          maxUnusedAddressGap,
          txCountBatchSize,
          root,
          receiveChain,
        ),
      );

      // change addresses
      Logging.instance.log(
        "checking change addresses...",
        level: LogLevel.Info,
      );
      changeFutures.add(
        _checkGaps(
          maxNumberOfIndexesToCheck,
          maxUnusedAddressGap,
          txCountBatchSize,
          root,
          changeChain,
        ),
      );

      // io limitations may require running these linearly instead
      final futuresResult = await Future.wait([
        Future.wait(receiveFutures),
        Future.wait(changeFutures),
      ]);

      final receiveResults = futuresResult[0];
      final changeResults = futuresResult[1];

      final List<isar_models.Address> addressesToStore = [];

      int highestReceivingIndexWithHistory = 0;
      // If restoring a wallet that never received any funds, then set receivingArray manually
      // If we didn't do this, it'd store an empty array
      for (final tuple in receiveResults) {
        if (tuple.item1.isEmpty) {
          final address = await _generateAddressForChain(
            receiveChain,
            indexZero,
          );
          addressesToStore.add(address);
        } else {
          highestReceivingIndexWithHistory =
              max(tuple.item2, highestReceivingIndexWithHistory);
          addressesToStore.addAll(tuple.item1);
        }
      }

      int highestChangeIndexWithHistory = 0;
      // If restoring a wallet that never sent any funds with change, then set changeArray
      // manually. If we didn't do this, it'd store an empty array.
      for (final tuple in changeResults) {
        if (tuple.item1.isEmpty) {
          final address = await _generateAddressForChain(
            changeChain,
            indexZero,
          );
          addressesToStore.add(address);
        } else {
          highestChangeIndexWithHistory =
              max(tuple.item2, highestChangeIndexWithHistory);
          addressesToStore.addAll(tuple.item1);
        }
      }

      // remove extra addresses to help minimize risk of creating a large gap
      addressesToStore.removeWhere((e) =>
          e.subType == isar_models.AddressSubType.change &&
          e.derivationIndex > highestChangeIndexWithHistory);
      addressesToStore.removeWhere((e) =>
          e.subType == isar_models.AddressSubType.receiving &&
          e.derivationIndex > highestReceivingIndexWithHistory);

      if (isRescan) {
        await db.updateOrPutAddresses(addressesToStore);
      } else {
        await db.putAddresses(addressesToStore);
      }

      await Future.wait([
        _refreshTransactions(),
        _refreshUTXOs(),
      ]);

      await Future.wait([
        updateCachedId(walletId),
        updateCachedIsFavorite(false),
      ]);

      longMutex = false;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown from _recoverWalletFromBIP32SeedPhrase(): $e\n$s",
          level: LogLevel.Error);

      longMutex = false;
      rethrow;
    }
  }

  /// Recovers wallet from [suppliedMnemonic]. Expects a valid mnemonic.
  Future<void> _recoverWalletFromBIP32SeedPhrase(
    String suppliedMnemonic,
    String mnemonicPassphrase,
    int maxUnusedAddressGap,
    int maxNumberOfIndexesToCheck,
    bool isRescan,
  ) async {
    longMutex = true;
    Logging.instance
        .log("PROCESSORS ${Platform.numberOfProcessors}", level: LogLevel.Info);
    try {
      final latestSetId = await getLatestSetId();
      final setDataMap = getSetDataMap(latestSetId);

      final usedSerialNumbers = getUsedCoinSerials();
      final generateAndCheckAddresses = _recoverHistory(
        suppliedMnemonic,
        mnemonicPassphrase,
        maxUnusedAddressGap,
        maxNumberOfIndexesToCheck,
        isRescan,
      );

      await Future.wait([
        updateCachedId(walletId),
        updateCachedIsFavorite(false),
      ]);

      await Future.wait([
        usedSerialNumbers,
        setDataMap,
        generateAndCheckAddresses,
      ]);

      await _restore(latestSetId, await setDataMap, await usedSerialNumbers);
      longMutex = false;
    } catch (e, s) {
      longMutex = false;
      Logging.instance.log(
          "Exception rethrown from recoverWalletFromBIP32SeedPhrase(): $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<void> _restore(
    int latestSetId,
    Map<dynamic, dynamic> setDataMap,
    List<String> usedSerialNumbers,
  ) async {
    final _mnemonic = await mnemonicString;
    final _mnemonicPassphrase = await mnemonicPassphrase;

    final dataFuture = _refreshTransactions();

    ReceivePort receivePort = await getIsolate({
      "function": "restore",
      "mnemonic": _mnemonic,
      "mnemonicPassphrase": _mnemonicPassphrase,
      "coin": coin,
      "latestSetId": latestSetId,
      "setDataMap": setDataMap,
      "usedSerialNumbers": usedSerialNumbers,
      "network": _network,
    });

    await Future.wait([dataFuture]);
    var result = await receivePort.first;
    if (result is String) {
      Logging.instance
          .log("restore() ->> this is a string", level: LogLevel.Error);
      stop(receivePort);
      throw Exception("isolate restore failed.");
    }
    stop(receivePort);

    final message = await staticProcessRestore(
      (await _txnData),
      result as Map<dynamic, dynamic>,
      await chainHeight,
    );

    await Future.wait([
      firoUpdateMintIndex(message['mintIndex'] as int),
      firoUpdateLelantusCoins(message['_lelantus_coins'] as List),
      firoUpdateJIndex(message['jindex'] as List),
    ]);

    final transactionMap =
        message["newTxMap"] as Map<String, isar_models.Transaction>;
    Map<String, Tuple2<isar_models.Address?, isar_models.Transaction>> data =
        {};

    for (final entry in transactionMap.entries) {
      data[entry.key] = Tuple2(entry.value.address.value, entry.value);
    }

    // Create the joinsplit transactions.
    final spendTxs = await getJMintTransactions(
      _cachedElectrumXClient,
      message["spendTxIds"] as List<String>,
      coin,
    );
    Logging.instance.log(spendTxs, level: LogLevel.Info);

    for (var element in spendTxs.entries) {
      final address = element.value.address.value ??
          data[element.value.txid]?.item1 ??
          element.key;
      // isar_models.Address(
      //   walletId: walletId,
      //   value: transactionInfo["address"] as String,
      //   derivationIndex: -1,
      //   type: isar_models.AddressType.nonWallet,
      //   subType: isar_models.AddressSubType.nonWallet,
      //   publicKey: [],
      // );

      data[element.value.txid] = Tuple2(address, element.value);
    }

    final List<Tuple2<isar_models.Transaction, isar_models.Address?>> txnsData =
        [];

    for (final value in data.values) {
      final transactionAddress = value.item1!;
      final outs =
          value.item2.outputs.where((_) => true).toList(growable: false);
      final ins = value.item2.inputs.where((_) => true).toList(growable: false);

      txnsData.add(Tuple2(
          value.item2.copyWith(inputs: ins, outputs: outs).item1,
          transactionAddress));
    }

    await db.addNewTransactionData(txnsData, walletId);
  }

  Future<List<Map<String, dynamic>>> fetchAnonymitySets() async {
    try {
      final latestSetId = await getLatestSetId();

      final List<Map<String, dynamic>> sets = [];
      List<Future<Map<String, dynamic>>> anonFutures = [];
      for (int i = 1; i <= latestSetId; i++) {
        final set = cachedElectrumXClient.getAnonymitySet(
          groupId: "$i",
          coin: coin,
        );
        anonFutures.add(set);
      }
      await Future.wait(anonFutures);
      for (int i = 1; i <= latestSetId; i++) {
        Map<String, dynamic> set = (await anonFutures[i - 1]);
        set["setId"] = i;
        sets.add(set);
      }
      return sets;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown from refreshAnonymitySets: $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<dynamic> _createJoinSplitTransaction(
      int spendAmount, String address, bool subtractFeeFromAmount) async {
    final _mnemonic = await mnemonicString;
    final _mnemonicPassphrase = await mnemonicPassphrase;
    final index = firoGetMintIndex();
    final lelantusEntry = await _getLelantusEntry();
    final anonymitySets = await fetchAnonymitySets();
    final locktime = await getBlockHead(electrumXClient);
    // final locale =
    //     Platform.isWindows ? "en_US" : await Devicelocale.currentLocale;

    ReceivePort receivePort = await getIsolate({
      "function": "createJoinSplit",
      "spendAmount": spendAmount,
      "address": address,
      "subtractFeeFromAmount": subtractFeeFromAmount,
      "mnemonic": _mnemonic,
      "mnemonicPassphrase": _mnemonicPassphrase,
      "index": index,
      // "price": price,
      "lelantusEntries": lelantusEntry,
      "locktime": locktime,
      "coin": coin,
      "network": _network,
      "_anonymity_sets": anonymitySets,
      // "locale": locale,
    });
    var message = await receivePort.first;
    if (message is String) {
      Logging.instance
          .log("Error in CreateJoinSplit: $message", level: LogLevel.Error);
      stop(receivePort);
      return 3;
    }
    if (message is int) {
      stop(receivePort);
      return message;
    }
    stop(receivePort);
    Logging.instance.log('Closing createJoinSplit!', level: LogLevel.Info);
    return message;
  }

  Future<int> getLatestSetId() async {
    try {
      final id = await electrumXClient.getLatestCoinId();
      return id;
    } catch (e, s) {
      Logging.instance.log("Exception rethrown in firo_wallet.dart: $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  Future<List<String>> getUsedCoinSerials() async {
    try {
      final response = await cachedElectrumXClient.getUsedCoinSerials(
        coin: coin,
      );
      return response;
    } catch (e, s) {
      Logging.instance.log("Exception rethrown in firo_wallet.dart: $e\n$s",
          level: LogLevel.Error);
      rethrow;
    }
  }

  @override
  Future<void> exit() async {
    _hasCalledExit = true;
    timer?.cancel();
    timer = null;
    stopNetworkAlivePinging();
    for (final isolate in isolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    isolates.clear();
    Logging.instance
        .log("$walletName firo_wallet exit finished", level: LogLevel.Info);
  }

  bool _hasCalledExit = false;

  @override
  bool get hasCalledExit => _hasCalledExit;

  bool isActive = false;

  @override
  void Function(bool)? get onIsActiveWalletChanged => (isActive) async {
        timer?.cancel();
        timer = null;
        if (isActive) {
          await compute(
            _setTestnetWrapper,
            coin == Coin.firoTestNet,
          );
        } else {
          await compute(
            _setTestnetWrapper,
            false,
          );
        }
        this.isActive = isActive;
      };

  Future<dynamic> getCoinsToJoinSplit(
    int required,
  ) async {
    List<DartLelantusEntry> coins = await _getLelantusEntry();
    if (required > LELANTUS_VALUE_SPEND_LIMIT_PER_TRANSACTION) {
      return false;
    }

    int availableBalance = coins.fold(
        0, (previousValue, element) => previousValue + element.amount);

    if (required > availableBalance) {
      return false;
    }

    // sort by biggest amount. if it is same amount we will prefer the older block
    coins.sort((a, b) =>
        (a.amount != b.amount ? a.amount > b.amount : a.height < b.height)
            ? -1
            : 1);
    int spendVal = 0;

    List<DartLelantusEntry> coinsToSpend = [];

    while (spendVal < required) {
      if (coins.isEmpty) {
        break;
      }

      DartLelantusEntry? chosen;
      int need = required - spendVal;

      var itr = coins.first;
      if (need >= itr.amount) {
        chosen = itr;
        coins.remove(itr);
      } else {
        for (int index = coins.length - 1; index != 0; index--) {
          var coinIt = coins[index];
          var nextItr = coins[index - 1];

          if (coinIt.amount >= need &&
              (index - 1 == 0 || nextItr.amount != coinIt.amount)) {
            chosen = coinIt;
            coins.remove(chosen);
            break;
          }
        }
      }

      // TODO: investigate the bug here where chosen is null, conditions, given one mint
      spendVal += chosen!.amount;
      coinsToSpend.insert(coinsToSpend.length, chosen);
    }

    // sort by group id ay ascending order. it is mandatory for creating proper joinsplit
    coinsToSpend.sort((a, b) => a.anonymitySetId < b.anonymitySetId ? 1 : -1);

    int changeToMint = spendVal - required;
    List<int> indices = [];
    for (var l in coinsToSpend) {
      indices.add(l.index);
    }
    List<DartLelantusEntry> coinsToBeSpentOut = [];
    coinsToBeSpentOut.addAll(coinsToSpend);

    return {"changeToMint": changeToMint, "coinsToSpend": coinsToBeSpentOut};
  }

  Future<int> estimateJoinSplitFee(
    int spendAmount,
  ) async {
    var lelantusEntry = await _getLelantusEntry();
    final balance = availablePrivateBalance().decimal;
    int spendAmount = (balance * Decimal.fromInt(Constants.satsPerCoin(coin)))
        .toBigInt()
        .toInt();
    if (spendAmount == 0 || lelantusEntry.isEmpty) {
      return LelantusFeeData(0, 0, []).fee;
    }
    ReceivePort receivePort = await getIsolate({
      "function": "estimateJoinSplit",
      "spendAmount": spendAmount,
      "subtractFeeFromAmount": true,
      "lelantusEntries": lelantusEntry,
      "coin": coin,
    });

    final message = await receivePort.first;
    if (message is String) {
      Logging.instance.log("this is a string", level: LogLevel.Error);
      stop(receivePort);
      throw Exception("_fetchMaxFee isolate failed");
    }
    stop(receivePort);
    Logging.instance.log('Closing estimateJoinSplit!', level: LogLevel.Info);
    return (message as LelantusFeeData).fee;
  }
  // int fee;
  // int size;
  //
  // for (fee = 0;;) {
  //   int currentRequired = spendAmount;
  //
  // TODO: investigate the bug here
  //   var map = await getCoinsToJoinSplit(currentRequired);
  //   if (map is bool && !map) {
  //     return 0;
  //   }
  //
  //   List<DartLelantusEntry> coinsToBeSpent =
  //       map['coinsToSpend'] as List<DartLelantusEntry>;
  //
  //   // 1054 is constant part, mainly Schnorr and Range proofs, 2560 is for each sigma/aux data
  //   // 179 other parts of tx, assuming 1 utxo and 1 jmint
  //   size = 1054 + 2560 * coinsToBeSpent.length + 180;
  //   //        uint64_t feeNeeded = GetMinimumFee(size, DEFAULT_TX_CONFIRM_TARGET);
  //   int feeNeeded =
  //       size; //TODO(Levon) temporary, use real estimation methods here
  //
  //   if (fee >= feeNeeded) {
  //     break;
  //   }
  //
  //   fee = feeNeeded;
  // }
  //
  // return fee;

  @override
  Future<Amount> estimateFeeFor(Amount amount, int feeRate) async {
    int fee = await estimateJoinSplitFee(amount.raw.toInt());
    return Amount(rawValue: BigInt.from(fee), fractionDigits: coin.decimals);
  }

  Future<Amount> estimateFeeForPublic(Amount amount, int feeRate) async {
    final available = balance.spendable;

    if (available == amount) {
      return amount - (await sweepAllEstimate(feeRate));
    } else if (amount <= Amount.zero || amount > available) {
      return roughFeeEstimate(1, 2, feeRate);
    }

    Amount runningBalance = Amount(
      rawValue: BigInt.zero,
      fractionDigits: coin.decimals,
    );
    int inputCount = 0;
    for (final output in (await utxos)) {
      if (!output.isBlocked) {
        runningBalance = runningBalance +
            Amount(
              rawValue: BigInt.from(output.value),
              fractionDigits: coin.decimals,
            );
        inputCount++;
        if (runningBalance > amount) {
          break;
        }
      }
    }

    final oneOutPutFee = roughFeeEstimate(inputCount, 1, feeRate);
    final twoOutPutFee = roughFeeEstimate(inputCount, 2, feeRate);

    final dustLimitAmount = Amount(
      rawValue: BigInt.from(DUST_LIMIT),
      fractionDigits: coin.decimals,
    );

    if (runningBalance - amount > oneOutPutFee) {
      if (runningBalance - amount > oneOutPutFee + dustLimitAmount) {
        final change = runningBalance - amount - twoOutPutFee;
        if (change > dustLimitAmount &&
            runningBalance - amount - change == twoOutPutFee) {
          return runningBalance - amount - change;
        } else {
          return runningBalance - amount;
        }
      } else {
        return runningBalance - amount;
      }
    } else if (runningBalance - amount == oneOutPutFee) {
      return oneOutPutFee;
    } else {
      return twoOutPutFee;
    }
  }

  // TODO: correct formula for firo?
  Amount roughFeeEstimate(int inputCount, int outputCount, int feeRatePerKB) {
    return Amount(
      rawValue: BigInt.from(((181 * inputCount) + (34 * outputCount) + 10) *
          (feeRatePerKB / 1000).ceil()),
      fractionDigits: coin.decimals,
    );
  }

  Future<Amount> sweepAllEstimate(int feeRate) async {
    int available = 0;
    int inputCount = 0;
    for (final output in (await utxos)) {
      if (!output.isBlocked &&
          output.isConfirmed(storedChainHeight, MINIMUM_CONFIRMATIONS)) {
        available += output.value;
        inputCount++;
      }
    }

    // transaction will only have 1 output minus the fee
    final estimatedFee = roughFeeEstimate(inputCount, 1, feeRate);

    return Amount(
          rawValue: BigInt.from(available),
          fractionDigits: coin.decimals,
        ) -
        estimatedFee;
  }

  Future<List<Map<String, dynamic>>> fastFetch(List<String> allTxHashes) async {
    List<Map<String, dynamic>> allTransactions = [];

    const futureLimit = 30;
    List<Future<Map<String, dynamic>>> transactionFutures = [];
    int currentFutureCount = 0;
    for (final txHash in allTxHashes) {
      Future<Map<String, dynamic>> transactionFuture =
          cachedElectrumXClient.getTransaction(
        txHash: txHash,
        verbose: true,
        coin: coin,
      );
      transactionFutures.add(transactionFuture);
      currentFutureCount++;
      if (currentFutureCount > futureLimit) {
        currentFutureCount = 0;
        await Future.wait(transactionFutures);
        for (final fTx in transactionFutures) {
          final tx = await fTx;
          // delete unused large parts
          tx.remove("hex");
          tx.remove("lelantusData");

          allTransactions.add(tx);
        }
      }
    }
    if (currentFutureCount != 0) {
      currentFutureCount = 0;
      await Future.wait(transactionFutures);
      for (final fTx in transactionFutures) {
        final tx = await fTx;
        // delete unused large parts
        tx.remove("hex");
        tx.remove("lelantusData");

        allTransactions.add(tx);
      }
    }
    return allTransactions;
  }

  Future<Map<isar_models.Address, isar_models.Transaction>>
      getJMintTransactions(
    CachedElectrumX cachedClient,
    List<String> transactions,
    // String currency,
    Coin coin,
    // Decimal currentPrice,
    // String locale,
  ) async {
    try {
      Map<isar_models.Address, isar_models.Transaction> txs = {};
      List<Map<String, dynamic>> allTransactions =
          await fastFetch(transactions);

      for (int i = 0; i < allTransactions.length; i++) {
        try {
          final tx = allTransactions[i];

          var sendIndex = 1;
          if (tx["vout"][0]["value"] != null &&
              Decimal.parse(tx["vout"][0]["value"].toString()) > Decimal.zero) {
            sendIndex = 0;
          }
          tx["amount"] = tx["vout"][sendIndex]["value"];
          tx["address"] = tx["vout"][sendIndex]["scriptPubKey"]["addresses"][0];
          tx["fees"] = tx["vin"][0]["nFees"];

          final Amount amount = Amount.fromDecimal(
            Decimal.parse(tx["amount"].toString()),
            fractionDigits: coin.decimals,
          );

          final txn = isar_models.Transaction(
            walletId: walletId,
            txid: tx["txid"] as String,
            timestamp: tx["time"] as int? ??
                (DateTime.now().millisecondsSinceEpoch ~/ 1000),
            type: isar_models.TransactionType.outgoing,
            subType: isar_models.TransactionSubType.join,
            amount: amount.raw.toInt(),
            amountString: amount.toJsonString(),
            fee: Amount.fromDecimal(
              Decimal.parse(tx["fees"].toString()),
              fractionDigits: coin.decimals,
            ).raw.toInt(),
            height: tx["height"] as int?,
            isCancelled: false,
            isLelantus: true,
            slateId: null,
            otherData: null,
            nonce: null,
            inputs: [],
            outputs: [],
          );

          final address = await db
                  .getAddresses(walletId)
                  .filter()
                  .valueEqualTo(tx["address"] as String)
                  .findFirst() ??
              isar_models.Address(
                walletId: walletId,
                value: tx["address"] as String,
                derivationIndex: -2,
                derivationPath: null,
                type: isar_models.AddressType.nonWallet,
                subType: isar_models.AddressSubType.unknown,
                publicKey: [],
              );

          txs[address] = txn;
        } catch (e, s) {
          Logging.instance.log(
              "Exception caught in getJMintTransactions(): $e\n$s",
              level: LogLevel.Info);
          rethrow;
        }
      }
      return txs;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown in getJMintTransactions(): $e\n$s",
          level: LogLevel.Info);
      rethrow;
    }
  }

  @override
  Future<bool> generateNewAddress() async {
    try {
      final currentReceiving = await _currentReceivingAddress;

      final newReceivingIndex = currentReceiving.derivationIndex + 1;

      // Use new index to derive a new receiving address
      final newReceivingAddress = await _generateAddressForChain(
        0,
        newReceivingIndex,
      );

      // Add that new receiving address
      await db.putAddress(newReceivingAddress);

      return true;
    } catch (e, s) {
      Logging.instance.log(
          "Exception rethrown from generateNewAddress(): $e\n$s",
          level: LogLevel.Error);
      return false;
    }
  }

  Amount availablePrivateBalance() {
    return balancePrivate.spendable;
  }

  Amount availablePublicBalance() {
    return balance.spendable;
  }

  Future<int> get chainHeight async {
    try {
      final result = await _electrumXClient.getBlockHeadTip();
      final height = result["height"] as int;
      await updateCachedChainHeight(height);
      if (height > storedChainHeight) {
        GlobalEventBus.instance.fire(
          UpdatedInBackgroundEvent(
            "Updated current chain height in $walletId $walletName!",
            walletId,
          ),
        );
      }
      return height;
    } catch (e, s) {
      Logging.instance.log("Exception caught in chainHeight: $e\n$s",
          level: LogLevel.Error);
      return storedChainHeight;
    }
  }

  @override
  int get storedChainHeight => getCachedChainHeight();

  @override
  Balance get balance => _balance ??= getCachedBalance();
  Balance? _balance;

  Balance get balancePrivate => _balancePrivate ??= getCachedBalanceSecondary();
  Balance? _balancePrivate;

  @override
  Future<List<isar_models.UTXO>> get utxos => db.getUTXOs(walletId).findAll();

  @override
  Future<List<isar_models.Transaction>> get transactions =>
      db.getTransactions(walletId).findAll();

  @override
  Future<String> get xpub async {
    final node = await Bip32Utils.getBip32Root(
      (await mnemonic).join(" "),
      await mnemonicPassphrase ?? "",
      _network,
    );

    return node.neutered().toBase58();
  }
}
