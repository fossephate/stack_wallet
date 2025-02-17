import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:stackwallet/pages/add_wallet_views/add_token_view/edit_wallet_tokens_view.dart';
import 'package:stackwallet/pages/token_view/sub_widgets/my_tokens_list.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/services/coins/ethereum/ethereum_wallet.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/assets.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/text_styles.dart';
import 'package:stackwallet/utilities/util.dart';
import 'package:stackwallet/widgets/background.dart';
import 'package:stackwallet/widgets/conditional_parent.dart';
import 'package:stackwallet/widgets/custom_buttons/app_bar_icon_button.dart';
import 'package:stackwallet/widgets/icon_widgets/x_icon.dart';
import 'package:stackwallet/widgets/stack_text_field.dart';
import 'package:stackwallet/widgets/textfield_icon_button.dart';

class MyTokensView extends ConsumerStatefulWidget {
  const MyTokensView({
    Key? key,
    required this.walletId,
  }) : super(key: key);

  static const String routeName = "/myTokens";
  final String walletId;

  @override
  ConsumerState<MyTokensView> createState() => _MyTokensViewState();
}

class _MyTokensViewState extends ConsumerState<MyTokensView> {
  final bool isDesktop = Util.isDesktop;

  late final String walletAddress;
  late final TextEditingController _searchController;
  final searchFieldFocusNode = FocusNode();
  String _searchString = "";

  @override
  void initState() {
    _searchController = TextEditingController();
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    searchFieldFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("BUILD: $runtimeType");

    return ConditionalParent(
      condition: !isDesktop,
      builder: (child) => Background(
        child: Scaffold(
          backgroundColor:
              Theme.of(context).extension<StackColors>()!.background,
          appBar: AppBar(
            backgroundColor:
                Theme.of(context).extension<StackColors>()!.background,
            leading: AppBarBackButton(
              onPressed: () async {
                if (FocusScope.of(context).hasFocus) {
                  FocusScope.of(context).unfocus();
                  await Future<void>.delayed(const Duration(milliseconds: 75));
                }
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
            ),
            title: Text(
              "${ref.watch(
                walletsChangeNotifierProvider.select(
                    (value) => value.getManager(widget.walletId).walletName),
              )} Tokens",
              style: STextStyles.navBarTitle(context),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(
                  top: 10,
                  bottom: 10,
                  right: 20,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: AppBarIconButton(
                    key: const Key("addTokenAppBarIconButtonKey"),
                    size: 36,
                    shadows: const [],
                    color:
                        Theme.of(context).extension<StackColors>()!.background,
                    icon: SvgPicture.asset(
                      Assets.svg.circlePlusFilled,
                      color: Theme.of(context)
                          .extension<StackColors>()!
                          .topNavIconPrimary,
                      width: 20,
                      height: 20,
                    ),
                    onPressed: () async {
                      final result = await Navigator.of(context).pushNamed(
                        EditWalletTokensView.routeName,
                        arguments: widget.walletId,
                      );

                      if (mounted && result == 42) {
                        setState(() {});
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.only(
              left: 12,
              top: 12,
              right: 12,
            ),
            child: child,
          ),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(isDesktop ? 0 : 4),
            child: Row(
              children: [
                ConditionalParent(
                  condition: isDesktop,
                  builder: (child) => Expanded(
                    child: child,
                  ),
                  child: ConditionalParent(
                    condition: !isDesktop,
                    builder: (child) => Expanded(
                      child: child,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        Constants.size.circularBorderRadius,
                      ),
                      child: TextField(
                        autocorrect: !isDesktop,
                        enableSuggestions: !isDesktop,
                        controller: _searchController,
                        focusNode: searchFieldFocusNode,
                        onChanged: (value) {
                          setState(() {
                            _searchString = value;
                          });
                        },
                        style: isDesktop
                            ? STextStyles.desktopTextExtraSmall(context)
                                .copyWith(
                                color: Theme.of(context)
                                    .extension<StackColors>()!
                                    .textFieldActiveText,
                                height: 1.8,
                              )
                            : STextStyles.field(context),
                        decoration: standardInputDecoration(
                          "Search...",
                          searchFieldFocusNode,
                          context,
                          desktopMed: isDesktop,
                        ).copyWith(
                          prefixIcon: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: isDesktop ? 12 : 10,
                              vertical: isDesktop ? 18 : 16,
                            ),
                            child: SvgPicture.asset(
                              Assets.svg.search,
                              width: isDesktop ? 20 : 16,
                              height: isDesktop ? 20 : 16,
                            ),
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? Padding(
                                  padding: const EdgeInsets.only(right: 0),
                                  child: UnconstrainedBox(
                                    child: Row(
                                      children: [
                                        TextFieldIconButton(
                                          child: const XIcon(),
                                          onTap: () async {
                                            setState(() {
                                              _searchController.text = "";
                                              _searchString = "";
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(
            height: 8,
          ),
          Expanded(
            child: MyTokensList(
              walletId: widget.walletId,
              searchTerm: _searchString,
              tokenContracts: ref
                  .watch(walletsChangeNotifierProvider.select((value) => value
                      .getManager(widget.walletId)
                      .wallet as EthereumWallet))
                  .getWalletTokenContractAddresses(),
            ),
          ),
        ],
      ),
    );
  }
}
