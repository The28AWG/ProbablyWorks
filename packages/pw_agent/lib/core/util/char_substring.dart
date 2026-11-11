import 'package:characters/characters.dart';

String charPrefix(String text, int count) => text.characters.take(count).string;

String charSuffix(String text, int count) {
  final chars = text.characters;
  if (count >= chars.length) return text;
  return chars.skip(chars.length - count).string;
}

String charRange(String text, int start, int end) =>
    text.characters.getRange(start, end).string;

String charFrom(String text, int start) => text.characters.skip(start).string;
