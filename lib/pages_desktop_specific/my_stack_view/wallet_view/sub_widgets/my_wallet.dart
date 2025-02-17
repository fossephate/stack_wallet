import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stackwallet/pages/wallet_view/sub_widgets/transactions_list.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_receive.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_send.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_token_send.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/utilities/enums/coin_enum.dart';
import 'package:stackwallet/widgets/custom_tab_view.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';

class MyWallet extends ConsumerStatefulWidget {
  const MyWallet({
    Key? key,
    required this.walletId,
    this.contractAddress,
  }) : super(key: key);

  final String walletId;
  final String? contractAddress;

  @override
  ConsumerState<MyWallet> createState() => _MyWalletState();
}

class _MyWalletState extends ConsumerState<MyWallet> {
  final titles = [
    "Send",
    "Receive",
  ];

  late final bool isEth;

  @override
  void initState() {
    isEth = ref
            .read(walletsChangeNotifierProvider)
            .getManager(widget.walletId)
            .coin ==
        Coin.ethereum;

    if (isEth && widget.contractAddress == null) {
      titles.add("Transactions");
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      primary: false,
      children: [
        RoundedWhiteContainer(
          padding: EdgeInsets.zero,
          child: CustomTabView(
            titles: titles,
            children: [
              widget.contractAddress == null
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: DesktopSend(
                        walletId: widget.walletId,
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(20),
                      child: DesktopTokenSend(
                        walletId: widget.walletId,
                      ),
                    ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: DesktopReceive(
                  walletId: widget.walletId,
                  contractAddress: widget.contractAddress,
                ),
              ),
              if (isEth && widget.contractAddress == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height - 362,
                    ),
                    child: TransactionsList(
                      walletId: widget.walletId,
                      managerProvider: ref.watch(
                        walletsChangeNotifierProvider.select(
                          (value) => value.getManagerProvider(
                            widget.walletId,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
