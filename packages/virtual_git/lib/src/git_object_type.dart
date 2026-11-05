// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
enum GitObjectType {
  blob('blob'),
  tree('tree'),
  commit('commit'),
  tag('tag');

  const GitObjectType(this.headerName);

  final String headerName;

  static GitObjectType parse(String value) => GitObjectType.values.firstWhere(
    (type) => type.headerName == value,
    orElse: () => throw FormatException('Unsupported Git object type.', value),
  );
}
