/// Квотирование аргумента для POSIX sh: одинарные кавычки, внутренние `'` экранируются.
String shQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Квотирование для PowerShell: одинарные кавычки удваиваются.
String psQuote(String value) => "'${value.replaceAll("'", "''")}'";
