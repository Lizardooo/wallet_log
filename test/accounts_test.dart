import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';

Account acc(String wallet, {String number = '', int? subId, int? slot}) =>
    Account(
      name: '$wallet ${subId ?? '-'}',
      wallet: wallet,
      number: number,
      subId: subId,
      slot: slot,
    );

Tx tx(String wallet, {int? subId}) => Tx(
      id: 1,
      ts: 0,
      wallet: wallet,
      type: TxType.transfer,
      dir: Dir.inFlow,
      amount: 10,
      subId: subId,
    );

void main() {
  group('smsBelongsToAccounts', () {
    test('rejects wallets the owner did not choose', () {
      final accounts = [acc('Vodafone Cash', subId: 1)];
      expect(smsBelongsToAccounts('InstaPay', 1, accounts), isFalse);
      expect(smsBelongsToAccounts('Vodafone Cash', 1, accounts), isTrue);
    });

    test('rejects a known SIM that owns no chosen number', () {
      final accounts = [acc('Vodafone Cash', subId: 1)];
      expect(smsBelongsToAccounts('Vodafone Cash', 2, accounts), isFalse);
    });

    test('keeps messages when a SIM is unknown', () {
      final accounts = [
        acc('Vodafone Cash', subId: 1),
        acc('Vodafone Cash', subId: null),
      ];
      expect(smsBelongsToAccounts('Vodafone Cash', 2, accounts), isTrue);
      expect(smsBelongsToAccounts('Vodafone Cash', null, accounts), isTrue);
    });
  });

  group('accountFor', () {
    test('matches the exact SIM when two numbers share a wallet type', () {
      final accounts = [
        acc('Vodafone Cash', subId: 1),
        acc('Vodafone Cash', subId: 2),
      ];
      expect(accountFor(tx('Vodafone Cash', subId: 2), accounts)?.subId, 2);
    });

    test('does not attach a known SIM to a number on another SIM', () {
      final accounts = [
        acc('Vodafone Cash', subId: 1),
        acc('Vodafone Cash', subId: 2),
      ];
      expect(accountFor(tx('Vodafone Cash', subId: 3), accounts), isNull);
    });

    test('uses the only number of a wallet type when the SIM is unknown', () {
      final only = acc('Vodafone Cash', subId: null);
      final accounts = [only];
      expect(accountFor(tx('Vodafone Cash', subId: 7), accounts), same(only));
      expect(accountFor(tx('Vodafone Cash'), accounts), same(only));
    });

    test('does not guess between a known different SIM and an unknown one', () {
      final accounts = [
        acc('Vodafone Cash', subId: 1),
        acc('Vodafone Cash', subId: null),
      ];
      expect(accountFor(tx('Vodafone Cash', subId: 2), accounts), isNull);
    });

    test('links Excel rows by the wallet number', () {
      final accounts = [
        acc('Vodafone Cash', number: '01012345678'),
        acc('InstaPay', number: '01098765432'),
      ];
      expect(accountFor(tx('01098765432'), accounts)?.wallet, 'InstaPay');
    });
  });
}
