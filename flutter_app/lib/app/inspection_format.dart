/// Presentation only. Identifiers, timestamps and metadata never pass here.
String inspectionNumber(double value) =>
    value > 0 && value < .005 ? '<0.01' : value.toStringAsFixed(2);

String inspectionSeconds(int? milliseconds) =>
    milliseconds == null ? '未知' : '${inspectionNumber(milliseconds / 1000)} s';
