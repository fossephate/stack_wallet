import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stackwallet/pages/exchange_view/exchange_form.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_exchange/desktop_all_trades_view.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_exchange/subwidgets/desktop_trade_history.dart';
import 'package:stackwallet/providers/exchange/exchange_form_state_provider.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/services/exchange/exchange_data_loading_service.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/text_styles.dart';
import 'package:stackwallet/widgets/conditional_parent.dart';
import 'package:stackwallet/widgets/custom_buttons/blue_text_button.dart';
import 'package:stackwallet/widgets/custom_loading_overlay.dart';
import 'package:stackwallet/widgets/desktop/desktop_app_bar.dart';
import 'package:stackwallet/widgets/desktop/desktop_scaffold.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';

class DesktopExchangeView extends ConsumerStatefulWidget {
  const DesktopExchangeView({Key? key}) : super(key: key);

  static const String routeName = "/desktopExchange";

  @override
  ConsumerState<DesktopExchangeView> createState() =>
      _DesktopExchangeViewState();
}

class _DesktopExchangeViewState extends ConsumerState<DesktopExchangeView> {
  bool _initialCachePopulationUnderway = false;

  @override
  void initState() {
    if (!ref.read(prefsChangeNotifierProvider).externalCalls) {
      if (ExchangeDataLoadingService.currentCacheVersion <
          ExchangeDataLoadingService.cacheVersion) {
        _initialCachePopulationUnderway = true;
        ExchangeDataLoadingService.instance.onLoadingComplete = () {
          WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
            await ExchangeDataLoadingService.instance.setCurrenciesIfEmpty(
              ref.read(efCurrencyPairProvider),
              ref.read(efRateTypeProvider),
            );
            setState(() {
              _initialCachePopulationUnderway = false;
            });
          });
        };
      }
      ExchangeDataLoadingService.instance.loadAll();
    } else if (ExchangeDataLoadingService.instance.isLoading &&
        ExchangeDataLoadingService.currentCacheVersion <
            ExchangeDataLoadingService.cacheVersion) {
      _initialCachePopulationUnderway = true;
      ExchangeDataLoadingService.instance.onLoadingComplete = () {
        WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
          await ExchangeDataLoadingService.instance.setCurrenciesIfEmpty(
            ref.read(efCurrencyPairProvider),
            ref.read(efRateTypeProvider),
          );
          setState(() {
            _initialCachePopulationUnderway = false;
          });
        });
      };
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return ConditionalParent(
      condition: _initialCachePopulationUnderway,
      builder: (child) {
        return Stack(
          children: [
            child,
            Material(
              color: Theme.of(context)
                  .extension<StackColors>()!
                  .overlay
                  .withOpacity(0.6),
              child: const CustomLoadingOverlay(
                message: "Updating exchange data",
                subMessage: "This could take a few minutes",
                eventBus: null,
              ),
            )
          ],
        );
      },
      child: DesktopScaffold(
        appBar: DesktopAppBar(
          isCompactHeight: true,
          leading: Padding(
            padding: const EdgeInsets.only(
              left: 24,
            ),
            child: Text(
              "Swap",
              style: STextStyles.desktopH3(context),
            ),
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.only(
            left: 24,
            right: 24,
            bottom: 24,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "Exchange details",
                      style: STextStyles.desktopTextExtraExtraSmall(context),
                    ),
                  ),
                  const SizedBox(
                    width: 16,
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Recent trades",
                          style:
                              STextStyles.desktopTextExtraExtraSmall(context),
                        ),
                        CustomTextButton(
                          text: "See all",
                          onTap: () {
                            Navigator.of(context).pushNamed(
                              DesktopAllTradesView.routeName,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 16,
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ListView(
                        children: const [
                          RoundedWhiteContainer(
                            padding: EdgeInsets.all(24),
                            child: ExchangeForm(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(
                      width: 16,
                    ),
                    Expanded(
                      child: Row(
                        children: const [
                          Expanded(
                            child: DesktopTradeHistory(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
