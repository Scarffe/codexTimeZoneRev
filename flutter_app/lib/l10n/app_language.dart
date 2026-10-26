import 'package:flutter/widgets.dart';

enum AppLanguage {
  zh('zh', Locale('zh', 'CN')),
  en('en', Locale('en', 'US'));

  const AppLanguage(this.code, this.locale);
  final String code;
  final Locale locale;

  static AppLanguage parse(Object? value) => value == 'en' ? en : zh;
}
