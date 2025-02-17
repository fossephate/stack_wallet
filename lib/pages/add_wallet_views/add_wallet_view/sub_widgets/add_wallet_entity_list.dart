import 'package:flutter/material.dart';
import 'package:stackwallet/models/add_wallet_list_entity/add_wallet_list_entity.dart';
import 'package:stackwallet/pages/add_wallet_views/add_wallet_view/sub_widgets/coin_select_item.dart';

class AddWalletEntityList extends StatelessWidget {
  const AddWalletEntityList({
    Key? key,
    required this.entities,
    this.trailing,
  }) : super(key: key);

  final List<AddWalletListEntity> entities;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      primary: false,
      itemCount: trailing != null ? entities.length + 1 : entities.length,
      itemBuilder: (ctx, index) {
        if (trailing != null && index == entities.length) {
          return Padding(
            padding: const EdgeInsets.all(4),
            child: trailing,
          );
        } else {
          return Padding(
            padding: const EdgeInsets.all(4),
            child: CoinSelectItem(
              entity: entities[index],
            ),
          );
        }
      },
    );
  }
}
