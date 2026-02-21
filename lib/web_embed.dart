import 'dart:html' as html;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

Widget buildEmbeddedWebView(String url) {
  final viewType = 'iframe-${DateTime.now().microsecondsSinceEpoch}';
  ui.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
    final iframe = html.IFrameElement()
      ..src = url
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..setAttribute('allow', 'fullscreen')
      ..setAttribute('loading', 'lazy');
    return iframe;
  });
  return HtmlElementView(viewType: viewType);
}
