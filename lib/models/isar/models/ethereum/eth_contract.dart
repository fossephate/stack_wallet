import 'package:isar/isar.dart';
import 'package:stackwallet/models/isar/models/contract.dart';

part 'eth_contract.g.dart';

@collection
class EthContract extends Contract {
  EthContract({
    required this.address,
    required this.name,
    required this.symbol,
    required this.decimals,
    required this.type,
    this.abi,
  });

  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late final String address;

  late final String name;

  late final String symbol;

  late final int decimals;

  late final String? abi;

  @enumerated
  late final EthContractType type;

  EthContract copyWith({
    Id? id,
    String? address,
    String? name,
    String? symbol,
    int? decimals,
    EthContractType? type,
    List<String>? walletIds,
    String? abi,
    String? otherData,
  }) =>
      EthContract(
        address: address ?? this.address,
        name: name ?? this.name,
        symbol: symbol ?? this.symbol,
        decimals: decimals ?? this.decimals,
        type: type ?? this.type,
        abi: abi ?? this.abi,
      )..id = id ?? this.id;
}

// Used in Isar db and stored there as int indexes so adding/removing values
// in this definition should be done extremely carefully in production
enum EthContractType {
  unknown,
  erc20,
  erc721;
}
