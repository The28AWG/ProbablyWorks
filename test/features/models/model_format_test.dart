import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';

void main() {
  test('llama.cpp id loses the routing prefix', () {
    expect(
      modelIdForDisplay(
        'llamacpp:Hy-MT2-1.8B-Q4_K_M',
        providers: const [llamaCppDescriptor],
      ),
      'Hy-MT2-1.8B-Q4_K_M',
    );
  });

  test('other ids are unchanged', () {
    expect(
      modelIdForDisplay('openai/gpt-4o', providers: const [llamaCppDescriptor]),
      'openai/gpt-4o',
    );
  });
}
