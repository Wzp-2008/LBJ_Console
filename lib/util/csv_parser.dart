/// Parses one CSV row, including quoted fields that contain commas or escaped
/// quotes. All CSV readers in the app use this implementation so assets and
/// imported files follow the same rules.
List<String> parseCsvLine(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char == ',' && !inQuotes) {
      fields.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  fields.add(buffer.toString().trim());
  return fields;
}

Map<String, String> parseLocoTypeMap(String csv) {
  final map = <String, String>{};
  for (final line in csv.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    final fields = parseCsvLine(line);
    if (fields.length >= 2 && fields[0].isNotEmpty) {
      map[fields[0]] = fields[1];
    }
  }
  return map;
}
