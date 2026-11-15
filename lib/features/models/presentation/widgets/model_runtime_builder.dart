import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Точечная подписка на runtime моделей.
///
/// Прогресс загрузки приходит несколько раз в секунду. Держать его в
/// `ChatState` нельзя: тогда перестраивалась бы вся лента чата. Этот виджет
/// перестраивает только свой маленький участок — чип модели или баннер дока.
class ModelRuntimeBuilder extends StatefulWidget {
  const ModelRuntimeBuilder({
    required this.source,
    required this.builder,
    super.key,
  });

  final ModelRuntimeSource source;
  final Widget Function(BuildContext context, ModelRuntimeState runtime)
  builder;

  @override
  State<ModelRuntimeBuilder> createState() => _ModelRuntimeBuilderState();
}

class _ModelRuntimeBuilderState extends State<ModelRuntimeBuilder> {
  late ModelRuntimeState _runtime = widget.source.runtime;
  StreamSubscription<ModelRuntimeState>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant ModelRuntimeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source == widget.source) return;
    unawaited(_sub?.cancel());
    _runtime = widget.source.runtime;
    _listen();
  }

  void _listen() {
    _sub = widget.source.watchRuntime().listen((runtime) {
      if (mounted) setState(() => _runtime = runtime);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _runtime);
}
