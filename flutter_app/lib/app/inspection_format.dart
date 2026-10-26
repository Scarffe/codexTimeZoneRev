import '../l10n/app_copy.dart';
import '../l10n/app_language.dart';

/// Presentation only. Identifiers, timestamps and metadata never pass here.
String inspectionNumber(double value) =>
    value > 0 && value < .005 ? '<0.01' : value.toStringAsFixed(2);

String inspectionSeconds(
  int? milliseconds, {
  AppCopy copy = const AppCopy(AppLanguage.zh),
}) => milliseconds == null
    ? copy.text('common.unknown')
    : '${inspectionNumber(milliseconds / 1000)} s';
