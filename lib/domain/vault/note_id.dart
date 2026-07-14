import 'package:uuid/uuid.dart';

final class NoteId {
  const NoteId._(this.value);

  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final String value;

  factory NoteId.generate() => NoteId._(const Uuid().v4());

  factory NoteId.parse(Object? value) {
    final parsed = tryParse(value);
    if (parsed == null) {
      throw FormatException('Invalid Synapse note UUID v4: $value');
    }
    return parsed;
  }

  static NoteId? tryParse(Object? value) {
    if (value is! String || !_uuidV4Pattern.hasMatch(value)) {
      return null;
    }
    return NoteId._(value);
  }

  @override
  bool operator ==(Object other) => other is NoteId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
