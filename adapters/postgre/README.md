# Overview
Provides an adapter for using the package [database](https://pub.dev/packages/database) with
[PostgreSQL](https://www.postgresql.org/). The implementation uses the package
[postgres](https://pub.dev/packages/postgres).

# Getting started
## 1.Add dependency
```yaml
dependencies:
  database: any
  database_adapter_postgre: any
```

## 2.Configure
```dart
import 'package:database_adapter_postgre/database_adapter_postgre.dart';

Future main() async {
  final database = Postgre(
    host: 'localhost',
    port: 5432,
    user: 'your username',
    password: 'your password',
    databaseName: 'example',
  );

  final result = await database.querySql('SELECT (name) FROM employee');
  for (var row in result.rows) {
    print('Name: ${row[0]}');
  }
}
```