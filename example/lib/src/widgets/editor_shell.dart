import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shared building blocks for the shader-editor pages (WGSL toy, compute
/// toy, Shadertoy player, particles): the responsive render/panel split,
/// the monospace source editor, and the inline compile-error box.

/// Responsive scaffold: render view beside the panel on wide layouts,
/// stacked above it on narrow ones.
class EditorPageScaffold extends StatelessWidget {
  const EditorPageScaffold({
    super.key,
    required this.title,
    required this.render,
    required this.panel,
  });

  final String title;
  final Widget render;
  final Widget panel;

  @override
  Widget build(BuildContext context) {
    final clipped =
        ClipRRect(borderRadius: BorderRadius.circular(8), child: render);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth > 900) {
            return Row(children: [
              Expanded(flex: 3, child: clipped),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: panel),
            ]);
          }
          return Column(children: [
            Expanded(flex: 3, child: clipped),
            const SizedBox(height: 12),
            Expanded(flex: 4, child: panel),
          ]);
        }),
      ),
    );
  }
}

/// Monospace, expandable shader source editor.
class ShaderEditorField extends StatelessWidget {
  const ShaderEditorField({
    super.key,
    required this.controller,
    required this.hint,
  });

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: true,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.all(12),
          border: InputBorder.none,
          hintText: hint,
        ),
      ),
    );
  }
}

/// Inline naga-diagnostics box; collapses to nothing while the source is
/// clean.
class CompileErrorBox extends StatelessWidget {
  const CompileErrorBox({super.key, required this.error});

  final ValueListenable<String?> error;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: error,
      builder: (context, message, _) => message == null
          ? const SizedBox.shrink()
          : Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(maxHeight: 140),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
              ),
              child: SingleChildScrollView(
                child: Text(
                  message,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
    );
  }
}
