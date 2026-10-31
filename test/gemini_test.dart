import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/gemini.dart';
import 'package:wallet_log/parser.dart';

const _items = [
  AiItem(id: 11, wallet: 'Vodafone Cash', body: 'sms one'),
  AiItem(id: 12, wallet: 'InstaPay', body: 'sms two'),
];

void main() {
  test('free tier families are detected', () {
    expect(isFreeModel('gemini-2.5-flash'), isTrue);
    expect(isFreeModel('gemini-2.5-flash-lite'), isTrue);
    expect(isFreeModel('gemma-3-27b-it'), isTrue);
    expect(isFreeModel('gemini-2.5-pro'), isFalse);
  });

  test('parses an answer wrapped in a code fence', () {
    final out = parseAiResponse(
      '```json\n[{"id":11,"type":"transfer","dir":"in","confidence":0.93,'
      '"reason":"استلام تحويل"},\n'
      '{"id":"12","type":"fee","dir":"out","confidence":0.4,"reason":"رسوم"}]```',
      _items,
    );
    expect(out, hasLength(2));
    expect(out[0].id, 11);
    expect(out[0].type, TxType.transfer);
    expect(out[0].dir, Dir.inFlow);
    expect(out[0].confidence, 0.93);
    expect(out[0].reason, 'استلام تحويل');
    expect(out[1].type, TxType.fee);
    expect(out[1].dir, Dir.outFlow);
  });

  test('accepts Arabic type and direction words', () {
    final out = parseAiResponse(
      '[{"id":11,"type":"تحويل","dir":"خارج","confidence":"0.8"}]',
      _items,
    );
    expect(out.single.type, TxType.transfer);
    expect(out.single.dir, Dir.outFlow);
    expect(out.single.confidence, 0.8);
  });

  test('clamps confidence and ignores unknown ids', () {
    final out = parseAiResponse(
      '[{"id":11,"type":"transfer","dir":"in","confidence":4},'
      '{"id":999,"type":"fee","dir":"out","confidence":0.9}]',
      _items,
    );
    expect(out, hasLength(1));
    expect(out.single.confidence, 1);
  });

  test('a response with no usable classification throws', () {
    expect(
      () => parseAiResponse('sorry, I cannot help', _items),
      throwsA(isA<GeminiException>()),
    );
    expect(
      () => parseAiResponse('[{"id":999,"type":"fee","dir":"out"}]', _items),
      throwsA(isA<GeminiException>()),
    );
  });

  test('an empty key is rejected before any request', () async {
    await expectLater(
      listGeminiModels('   '),
      throwsA(isA<GeminiException>()),
    );
    await expectLater(
      classifyMessages(
          apiKey: '', model: 'gemini-2.5-flash', items: _items),
      throwsA(isA<GeminiException>()),
    );
  });
}
