import 'package:cw_core/monero_transaction_priority.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stackwallet/models/paymint/fee_object_model.dart';
import 'package:stackwallet/pages/token_view/token_view.dart';
import 'package:stackwallet/providers/providers.dart';
import 'package:stackwallet/providers/ui/fee_rate_type_state_provider.dart';
import 'package:stackwallet/providers/wallet/public_private_balance_state_provider.dart';
import 'package:stackwallet/services/coins/firo/firo_wallet.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/enums/coin_enum.dart';
import 'package:stackwallet/utilities/enums/fee_rate_type_enum.dart';
import 'package:stackwallet/utilities/logger.dart';
import 'package:stackwallet/utilities/text_styles.dart';
import 'package:stackwallet/widgets/animated_text.dart';

final feeSheetSessionCacheProvider =
    ChangeNotifierProvider<FeeSheetSessionCache>((ref) {
  return FeeSheetSessionCache();
});

class FeeSheetSessionCache extends ChangeNotifier {
  final Map<Amount, Amount> fast = {};
  final Map<Amount, Amount> average = {};
  final Map<Amount, Amount> slow = {};

  void notify() => notifyListeners();
}

class TransactionFeeSelectionSheet extends ConsumerStatefulWidget {
  const TransactionFeeSelectionSheet({
    Key? key,
    required this.walletId,
    required this.amount,
    required this.updateChosen,
    this.isToken = false,
  }) : super(key: key);

  final String walletId;
  final Amount amount;
  final Function updateChosen;
  final bool isToken;

  @override
  ConsumerState<TransactionFeeSelectionSheet> createState() =>
      _TransactionFeeSelectionSheetState();
}

class _TransactionFeeSelectionSheetState
    extends ConsumerState<TransactionFeeSelectionSheet> {
  late final String walletId;
  late final Amount amount;

  FeeObject? feeObject;

  final stringsToLoopThrough = [
    "Calculating",
    "Calculating.",
    "Calculating..",
    "Calculating...",
  ];

  Future<Amount> feeFor({
    required Amount amount,
    required FeeRateType feeRateType,
    required int feeRate,
    required Coin coin,
  }) async {
    switch (feeRateType) {
      case FeeRateType.fast:
        if (ref.read(feeSheetSessionCacheProvider).fast[amount] == null) {
          if (widget.isToken == false) {
            final manager =
                ref.read(walletsChangeNotifierProvider).getManager(walletId);

            if (coin == Coin.monero || coin == Coin.wownero) {
              final fee = await manager.estimateFeeFor(
                  amount, MoneroTransactionPriority.fast.raw!);
              ref.read(feeSheetSessionCacheProvider).fast[amount] = fee;
            } else if ((coin == Coin.firo || coin == Coin.firoTestNet) &&
                ref.read(publicPrivateBalanceStateProvider.state).state !=
                    "Private") {
              ref.read(feeSheetSessionCacheProvider).fast[amount] =
                  await (manager.wallet as FiroWallet)
                      .estimateFeeForPublic(amount, feeRate);
            } else {
              ref.read(feeSheetSessionCacheProvider).fast[amount] =
                  await manager.estimateFeeFor(amount, feeRate);
            }
          } else {
            final tokenWallet = ref.read(tokenServiceProvider)!;
            final fee = tokenWallet.estimateFeeFor(feeRate);
            ref.read(feeSheetSessionCacheProvider).fast[amount] = fee;
          }
        }
        return ref.read(feeSheetSessionCacheProvider).fast[amount]!;

      case FeeRateType.average:
        if (ref.read(feeSheetSessionCacheProvider).average[amount] == null) {
          if (widget.isToken == false) {
            final manager =
                ref.read(walletsChangeNotifierProvider).getManager(walletId);
            if (coin == Coin.monero || coin == Coin.wownero) {
              final fee = await manager.estimateFeeFor(
                  amount, MoneroTransactionPriority.regular.raw!);
              ref.read(feeSheetSessionCacheProvider).average[amount] = fee;
            } else if ((coin == Coin.firo || coin == Coin.firoTestNet) &&
                ref.read(publicPrivateBalanceStateProvider.state).state !=
                    "Private") {
              ref.read(feeSheetSessionCacheProvider).average[amount] =
                  await (manager.wallet as FiroWallet)
                      .estimateFeeForPublic(amount, feeRate);
            } else {
              ref.read(feeSheetSessionCacheProvider).average[amount] =
                  await manager.estimateFeeFor(amount, feeRate);
            }
          } else {
            final tokenWallet = ref.read(tokenServiceProvider)!;
            final fee = tokenWallet.estimateFeeFor(feeRate);
            ref.read(feeSheetSessionCacheProvider).average[amount] = fee;
          }
        }
        return ref.read(feeSheetSessionCacheProvider).average[amount]!;

      case FeeRateType.slow:
        if (ref.read(feeSheetSessionCacheProvider).slow[amount] == null) {
          if (widget.isToken == false) {
            final manager =
                ref.read(walletsChangeNotifierProvider).getManager(walletId);
            if (coin == Coin.monero || coin == Coin.wownero) {
              final fee = await manager.estimateFeeFor(
                  amount, MoneroTransactionPriority.slow.raw!);
              ref.read(feeSheetSessionCacheProvider).slow[amount] = fee;
            } else if ((coin == Coin.firo || coin == Coin.firoTestNet) &&
                ref.read(publicPrivateBalanceStateProvider.state).state !=
                    "Private") {
              ref.read(feeSheetSessionCacheProvider).slow[amount] =
                  await (manager.wallet as FiroWallet)
                      .estimateFeeForPublic(amount, feeRate);
            } else {
              ref.read(feeSheetSessionCacheProvider).slow[amount] =
                  await manager.estimateFeeFor(amount, feeRate);
            }
          } else {
            final tokenWallet = ref.read(tokenServiceProvider)!;
            final fee = tokenWallet.estimateFeeFor(feeRate);
            ref.read(feeSheetSessionCacheProvider).slow[amount] = fee;
          }
        }
        return ref.read(feeSheetSessionCacheProvider).slow[amount]!;
    }
  }

  String estimatedTimeToBeIncludedInNextBlock(
      int targetBlockTime, int estimatedNumberOfBlocks) {
    int time = targetBlockTime * estimatedNumberOfBlocks;

    int hours = (time / 3600).floor();
    if (hours > 1) {
      return "~$hours hours";
    } else if (hours == 1) {
      return "~$hours hour";
    }

    // less than an hour

    final string = (time / 60).toStringAsFixed(1);

    if (string == "1.0") {
      return "~1 minute";
    } else {
      if (string.endsWith(".0")) {
        return "~${(time / 60).floor()} minutes";
      }
      return "~$string minutes";
    }
  }

  @override
  void initState() {
    walletId = widget.walletId;
    amount = widget.amount;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("BUILD: $runtimeType");

    final manager = ref.watch(walletsChangeNotifierProvider
        .select((value) => value.getManager(walletId)));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).extension<StackColors>()!.popupBG,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(20),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(
          left: 24,
          right: 24,
          top: 10,
          bottom: 0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(
                    Constants.size.circularBorderRadius,
                  ),
                ),
                width: 60,
                height: 4,
              ),
            ),
            const SizedBox(
              height: 36,
            ),
            FutureBuilder(
              future: widget.isToken
                  ? ref.read(tokenServiceProvider)!.fees
                  : manager.fees,
              builder: (context, AsyncSnapshot<FeeObject> snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasData) {
                  feeObject = snapshot.data!;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Fee rate",
                      style: STextStyles.pageTitleH2(context),
                      textAlign: TextAlign.left,
                    ),
                    const SizedBox(
                      height: 16,
                    ),
                    GestureDetector(
                      onTap: () {
                        final state =
                            ref.read(feeRateTypeStateProvider.state).state;
                        if (state != FeeRateType.fast) {
                          ref.read(feeRateTypeStateProvider.state).state =
                              FeeRateType.fast;
                        }
                        String? fee = getAmount(FeeRateType.fast, manager.coin);
                        if (fee != null) {
                          widget.updateChosen(fee);
                        }
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        color: Colors.transparent,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: Radio(
                                    activeColor: Theme.of(context)
                                        .extension<StackColors>()!
                                        .radioButtonIconEnabled,
                                    value: FeeRateType.fast,
                                    groupValue: ref
                                        .watch(feeRateTypeStateProvider.state)
                                        .state,
                                    onChanged: (x) {
                                      ref
                                          .read(feeRateTypeStateProvider.state)
                                          .state = FeeRateType.fast;

                                      Navigator.of(context).pop();
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(
                              width: 12,
                            ),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        FeeRateType.fast.prettyName,
                                        style: STextStyles.titleBold12(context),
                                        textAlign: TextAlign.left,
                                      ),
                                      const SizedBox(
                                        width: 2,
                                      ),
                                      if (feeObject == null)
                                        AnimatedText(
                                          stringsToLoopThrough:
                                              stringsToLoopThrough,
                                          style:
                                              STextStyles.itemSubtitle(context),
                                        ),
                                      if (feeObject != null)
                                        FutureBuilder(
                                          future: feeFor(
                                            coin: manager.coin,
                                            feeRateType: FeeRateType.fast,
                                            feeRate: feeObject!.fast,
                                            amount: amount,
                                          ),
                                          // future: manager.estimateFeeFor(
                                          //     Format.decimalAmountToSatoshis(
                                          //         amount),
                                          //     feeObject!.fast),
                                          builder: (_,
                                              AsyncSnapshot<Amount> snapshot) {
                                            if (snapshot.connectionState ==
                                                    ConnectionState.done &&
                                                snapshot.hasData) {
                                              return Text(
                                                "(~${snapshot.data!.decimal.toStringAsFixed(
                                                  manager.coin.decimals,
                                                )}"
                                                " ${manager.coin.ticker})",
                                                style: STextStyles.itemSubtitle(
                                                    context),
                                                textAlign: TextAlign.left,
                                              );
                                            } else {
                                              return AnimatedText(
                                                stringsToLoopThrough:
                                                    stringsToLoopThrough,
                                                style: STextStyles.itemSubtitle(
                                                    context),
                                              );
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                  const SizedBox(
                                    height: 2,
                                  ),
                                  if (feeObject == null &&
                                      manager.coin != Coin.ethereum)
                                    AnimatedText(
                                      stringsToLoopThrough:
                                          stringsToLoopThrough,
                                      style: STextStyles.itemSubtitle(context),
                                    ),
                                  if (feeObject != null &&
                                      manager.coin != Coin.ethereum)
                                    Text(
                                      estimatedTimeToBeIncludedInNextBlock(
                                        Constants.targetBlockTimeInSeconds(
                                            manager.coin),
                                        feeObject!.numberOfBlocksFast,
                                      ),
                                      style: STextStyles.itemSubtitle(context),
                                      textAlign: TextAlign.left,
                                    ),
                                ],
                              ),
                            )
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 16,
                    ),
                    GestureDetector(
                      onTap: () {
                        final state =
                            ref.read(feeRateTypeStateProvider.state).state;
                        if (state != FeeRateType.average) {
                          ref.read(feeRateTypeStateProvider.state).state =
                              FeeRateType.average;
                        }
                        String? fee =
                            getAmount(FeeRateType.average, manager.coin);
                        if (fee != null) {
                          widget.updateChosen(fee);
                        }
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        color: Colors.transparent,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: Radio(
                                    activeColor: Theme.of(context)
                                        .extension<StackColors>()!
                                        .radioButtonIconEnabled,
                                    value: FeeRateType.average,
                                    groupValue: ref
                                        .watch(feeRateTypeStateProvider.state)
                                        .state,
                                    onChanged: (x) {
                                      ref
                                          .read(feeRateTypeStateProvider.state)
                                          .state = FeeRateType.average;
                                      Navigator.of(context).pop();
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(
                              width: 12,
                            ),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        FeeRateType.average.prettyName,
                                        style: STextStyles.titleBold12(context),
                                        textAlign: TextAlign.left,
                                      ),
                                      const SizedBox(
                                        width: 2,
                                      ),
                                      if (feeObject == null)
                                        AnimatedText(
                                          stringsToLoopThrough:
                                              stringsToLoopThrough,
                                          style:
                                              STextStyles.itemSubtitle(context),
                                        ),
                                      if (feeObject != null)
                                        FutureBuilder(
                                          future: feeFor(
                                            coin: manager.coin,
                                            feeRateType: FeeRateType.average,
                                            feeRate: feeObject!.medium,
                                            amount: amount,
                                          ),
                                          // future: manager.estimateFeeFor(
                                          //     Format.decimalAmountToSatoshis(
                                          //         amount),
                                          //     feeObject!.fast),
                                          builder: (_,
                                              AsyncSnapshot<Amount> snapshot) {
                                            if (snapshot.connectionState ==
                                                    ConnectionState.done &&
                                                snapshot.hasData) {
                                              return Text(
                                                "(~${snapshot.data!.decimal.toStringAsFixed(manager.coin.decimals)}"
                                                " ${manager.coin.ticker})",
                                                style: STextStyles.itemSubtitle(
                                                    context),
                                                textAlign: TextAlign.left,
                                              );
                                            } else {
                                              return AnimatedText(
                                                stringsToLoopThrough:
                                                    stringsToLoopThrough,
                                                style: STextStyles.itemSubtitle(
                                                    context),
                                              );
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                  const SizedBox(
                                    height: 2,
                                  ),
                                  if (feeObject == null &&
                                      manager.coin != Coin.ethereum)
                                    AnimatedText(
                                      stringsToLoopThrough:
                                          stringsToLoopThrough,
                                      style: STextStyles.itemSubtitle(context),
                                    ),
                                  if (feeObject != null &&
                                      manager.coin != Coin.ethereum)
                                    Text(
                                      estimatedTimeToBeIncludedInNextBlock(
                                        Constants.targetBlockTimeInSeconds(
                                            manager.coin),
                                        feeObject!.numberOfBlocksAverage,
                                      ),
                                      style: STextStyles.itemSubtitle(context),
                                      textAlign: TextAlign.left,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 16,
                    ),
                    GestureDetector(
                      onTap: () {
                        final state =
                            ref.read(feeRateTypeStateProvider.state).state;
                        if (state != FeeRateType.slow) {
                          ref.read(feeRateTypeStateProvider.state).state =
                              FeeRateType.slow;
                        }
                        String? fee = getAmount(FeeRateType.slow, manager.coin);
                        if (fee != null) {
                          widget.updateChosen(fee);
                        }
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        color: Colors.transparent,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: Radio(
                                    activeColor: Theme.of(context)
                                        .extension<StackColors>()!
                                        .radioButtonIconEnabled,
                                    value: FeeRateType.slow,
                                    groupValue: ref
                                        .watch(feeRateTypeStateProvider.state)
                                        .state,
                                    onChanged: (x) {
                                      //todo: check if print needed
                                      // debugPrint(x.toString());
                                      ref
                                          .read(feeRateTypeStateProvider.state)
                                          .state = FeeRateType.slow;
                                      Navigator.of(context).pop();
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(
                              width: 12,
                            ),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        FeeRateType.slow.prettyName,
                                        style: STextStyles.titleBold12(context),
                                        textAlign: TextAlign.left,
                                      ),
                                      const SizedBox(
                                        width: 2,
                                      ),
                                      if (feeObject == null)
                                        AnimatedText(
                                          stringsToLoopThrough:
                                              stringsToLoopThrough,
                                          style:
                                              STextStyles.itemSubtitle(context),
                                        ),
                                      if (feeObject != null)
                                        FutureBuilder(
                                          future: feeFor(
                                            coin: manager.coin,
                                            feeRateType: FeeRateType.slow,
                                            feeRate: feeObject!.slow,
                                            amount: amount,
                                          ),
                                          // future: manager.estimateFeeFor(
                                          //     Format.decimalAmountToSatoshis(
                                          //         amount),
                                          //     feeObject!.fast),
                                          builder: (_,
                                              AsyncSnapshot<Amount> snapshot) {
                                            if (snapshot.connectionState ==
                                                    ConnectionState.done &&
                                                snapshot.hasData) {
                                              return Text(
                                                "(~${snapshot.data!.decimal.toStringAsFixed(manager.coin.decimals)} ${manager.coin.ticker})",
                                                style: STextStyles.itemSubtitle(
                                                    context),
                                                textAlign: TextAlign.left,
                                              );
                                            } else {
                                              return AnimatedText(
                                                stringsToLoopThrough:
                                                    stringsToLoopThrough,
                                                style: STextStyles.itemSubtitle(
                                                    context),
                                              );
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                  const SizedBox(
                                    height: 2,
                                  ),
                                  if (feeObject == null &&
                                      manager.coin != Coin.ethereum)
                                    AnimatedText(
                                      stringsToLoopThrough:
                                          stringsToLoopThrough,
                                      style: STextStyles.itemSubtitle(context),
                                    ),
                                  if (feeObject != null &&
                                      manager.coin != Coin.ethereum)
                                    Text(
                                      estimatedTimeToBeIncludedInNextBlock(
                                        Constants.targetBlockTimeInSeconds(
                                            manager.coin),
                                        feeObject!.numberOfBlocksSlow,
                                      ),
                                      style: STextStyles.itemSubtitle(context),
                                      textAlign: TextAlign.left,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 24,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String? getAmount(FeeRateType feeRateType, Coin coin) {
    try {
      switch (feeRateType) {
        case FeeRateType.fast:
          if (ref.read(feeSheetSessionCacheProvider).fast[amount] != null) {
            return (ref.read(feeSheetSessionCacheProvider).fast[amount]
                    as Decimal)
                .toStringAsFixed(coin.decimals);
          }
          return null;

        case FeeRateType.average:
          if (ref.read(feeSheetSessionCacheProvider).average[amount] != null) {
            return (ref.read(feeSheetSessionCacheProvider).average[amount]
                    as Decimal)
                .toStringAsFixed(coin.decimals);
          }
          return null;

        case FeeRateType.slow:
          if (ref.read(feeSheetSessionCacheProvider).slow[amount] != null) {
            return (ref.read(feeSheetSessionCacheProvider).slow[amount]
                    as Decimal)
                .toStringAsFixed(coin.decimals);
          }
          return null;
      }
    } catch (e, s) {
      Logging.instance.log("$e $s", level: LogLevel.Warning);
      return null;
    }
  }
}
