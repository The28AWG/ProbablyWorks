import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/app.dart';
import 'package:probably_works/app/bootstrap/web_bootstrap.dart';

Future<void> main() async {
  await bootstrapWeb();
  runApp(const ProbablyWorksApp());
}
