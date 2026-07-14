import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/note_id.dart';

void main() {
  test('accepts canonical lowercase UUID v4 note ids', () {
    final id = NoteId.tryParse('550e8400-e29b-41d4-a716-446655440000');

    expect(id?.value, '550e8400-e29b-41d4-a716-446655440000');
    expect(id.toString(), '550e8400-e29b-41d4-a716-446655440000');
  });

  test('rejects uppercase non-v4 and malformed note ids', () {
    expect(NoteId.tryParse('550E8400-E29B-41D4-A716-446655440000'), isNull);
    expect(NoteId.tryParse('550e8400-e29b-11d4-a716-446655440000'), isNull);
    expect(NoteId.tryParse('not-a-uuid'), isNull);
    expect(NoteId.tryParse(null), isNull);
  });

  test('compares note ids by value', () {
    final first = NoteId.parse('550e8400-e29b-41d4-a716-446655440000');
    final second = NoteId.parse('550e8400-e29b-41d4-a716-446655440000');

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}
