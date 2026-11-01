import 'package:flutter/widgets.dart';
import 'package:injectable/injectable.dart';

/// Язык интерфейса. null — как в системе; иначе код `ru` или `en`.
@singleton
class LocaleController extends ValueNotifier<Locale?> {
  LocaleController() : super(null);

  static const supported = [Locale('en'), Locale('ru')];

  void apply(String? code) {
    value = code == null || code.isEmpty || code == 'system'
        ? null
        : Locale(code);
  }
}
