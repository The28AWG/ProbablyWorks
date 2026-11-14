import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';

void main() {
  test('llama.cpp id loses the routing prefix', () {
    expect(
      modelIdForDisplay('llamacpp:Hy-MT2-1.8B-Q4_K_M'),
      'Hy-MT2-1.8B-Q4_K_M',
    );
  });

  test('other ids are unchanged', () {
    expect(modelIdForDisplay('openai/gpt-4o'), 'openai/gpt-4o');
  });
}
