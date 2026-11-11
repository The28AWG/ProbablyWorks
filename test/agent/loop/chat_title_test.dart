import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/loop/chat_title.dart';

void main() {
  group('ChatTitle.sanitize', () {
    test('strips quotes and trailing punctuation', () {
      expect(ChatTitle.sanitize('"Счётчик от 1 до 40".'), 'Счётчик от 1 до 40');
      expect(ChatTitle.sanitize('«Сборка Flutter»'), 'Сборка Flutter');
    });

    test('takes the first non-empty line without a label', () {
      expect(
        ChatTitle.sanitize('\n  Title: Build fix  \nextra line'),
        'Build fix',
      );
      expect(
        ChatTitle.sanitize('**Заголовок:** Настройка SSH'),
        'Настройка SSH',
      );
    });

    test('drops reasoning blocks before the title', () {
      expect(
        ChatTitle.sanitize('<think>Need a short name</think>\nОтладка логов'),
        'Отладка логов',
      );
    });

    test('rejects empty replies and unfinished reasoning', () {
      expect(ChatTitle.sanitize('   \n  '), isNull);
      expect(ChatTitle.sanitize('<think>still thinking'), isNull);
    });

    test('rejects replies that describe the task instead of naming it', () {
      expect(
        ChatTitle.sanitize(
          'The user wants a short chat title for their request',
        ),
        isNull,
      );
      expect(
        ChatTitle.sanitize('Пользователь хочет запустить счётчик'),
        isNull,
      );
    });

    test('rejects titles longer than the word limit', () {
      final long = List.generate(12, (i) => 'слово$i').join(' ');
      expect(ChatTitle.sanitize(long), isNull);
    });
  });

  test('fallback keeps short prompts and clips long ones', () {
    expect(ChatTitle.fallback('  привет\n  мир '), 'привет мир');
    final clipped = ChatTitle.fallback('a' * 100);
    expect(clipped.length, ChatTitle.maxChars + 1);
    expect(clipped.endsWith('…'), isTrue);
  });
}
