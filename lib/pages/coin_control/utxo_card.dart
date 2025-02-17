import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/isar_models.dart';
import 'package:stackwallet/providers/global/locale_provider.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/enums/coin_enum.dart';
import 'package:stackwallet/utilities/text_styles.dart';
import 'package:stackwallet/widgets/conditional_parent.dart';
import 'package:stackwallet/widgets/icon_widgets/utxo_status_icon.dart';
import 'package:stackwallet/widgets/rounded_container.dart';

class UtxoCard extends ConsumerStatefulWidget {
  const UtxoCard({
    Key? key,
    required this.utxo,
    required this.walletId,
    required this.onSelectedChanged,
    required this.initialSelectedState,
    required this.canSelect,
    this.onPressed,
  }) : super(key: key);

  final String walletId;
  final UTXO utxo;
  final void Function(bool) onSelectedChanged;
  final bool initialSelectedState;
  final VoidCallback? onPressed;
  final bool canSelect;

  @override
  ConsumerState<UtxoCard> createState() => _UtxoCardState();
}

class _UtxoCardState extends ConsumerState<UtxoCard> {
  late Stream<UTXO?> stream;
  late UTXO utxo;

  late bool _selected;

  @override
  void initState() {
    _selected = widget.initialSelectedState;
    utxo = widget.utxo;

    stream = MainDB.instance.watchUTXO(id: utxo.id);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("BUILD: $runtimeType");

    final coin = ref.watch(walletsChangeNotifierProvider
        .select((value) => value.getManager(widget.walletId).coin));

    final currentChainHeight = ref.watch(walletsChangeNotifierProvider
        .select((value) => value.getManager(widget.walletId).currentHeight));

    return ConditionalParent(
      condition: widget.onPressed != null,
      builder: (child) => MaterialButton(
        padding: const EdgeInsets.all(0),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        color: Theme.of(context).extension<StackColors>()!.popupBG,
        elevation: 0,
        disabledElevation: 0,
        hoverElevation: 0,
        focusElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(Constants.size.circularBorderRadius),
        ),
        onPressed: widget.onPressed,
        child: child,
      ),
      child: RoundedContainer(
        color: widget.onPressed == null
            ? Theme.of(context).extension<StackColors>()!.popupBG
            : Colors.transparent,
        child: StreamBuilder<UTXO?>(
            stream: stream,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                utxo = snapshot.data!;
              }
              return Row(
                children: [
                  ConditionalParent(
                    condition: widget.canSelect,
                    builder: (child) => GestureDetector(
                      onTap: () {
                        _selected = !_selected;
                        widget.onSelectedChanged(_selected);
                        setState(() {});
                      },
                      child: child,
                    ),
                    child: UTXOStatusIcon(
                      blocked: utxo.isBlocked,
                      status: utxo.isConfirmed(
                        currentChainHeight,
                        coin.requiredConfirmations,
                      )
                          ? UTXOStatusIconStatus.confirmed
                          : UTXOStatusIconStatus.unconfirmed,
                      background:
                          Theme.of(context).extension<StackColors>()!.popupBG,
                      selected: _selected,
                      width: 32,
                      height: 32,
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "${utxo.value.toAmountAsRaw(
                                fractionDigits: coin.decimals,
                              ).localizedStringAsFixed(
                                locale: ref.watch(
                                  localeServiceChangeNotifierProvider.select(
                                    (value) => value.locale,
                                  ),
                                ),
                              )} ${coin.ticker}",
                          style: STextStyles.w600_14(context),
                        ),
                        const SizedBox(
                          height: 2,
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                utxo.name.isNotEmpty
                                    ? utxo.name
                                    : utxo.address ?? utxo.txid,
                                style: STextStyles.w500_12(context).copyWith(
                                  color: Theme.of(context)
                                      .extension<StackColors>()!
                                      .textSubtitle1,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
      ),
    );
  }
}
