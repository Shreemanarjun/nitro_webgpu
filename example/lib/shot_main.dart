// Scratch entrypoint for capturing a screenshot of ShaderUiPage.
import 'package:flutter/material.dart';

import 'src/demos/shader_ui_page.dart';

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const ShaderUiPage(),
    ));
