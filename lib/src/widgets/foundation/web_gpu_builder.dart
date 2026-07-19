import 'package:flutter/widgets.dart';

import '../../api/gpu.dart';
import 'web_gpu.dart';

/// Boots (or reuses) the shared GPU device and rebuilds with it — the
/// loading and error states every hand-rolled `initState` boot duplicates,
/// as one widget:
///
/// ```dart
/// WebGpuBuilder(
///   builder: (context, device) =>
///       WebGpuView(device: device, onFrame: myFrame),
///   loadingBuilder: (context) => const CircularProgressIndicator(),
///   errorBuilder: (context, error) => Text('No GPU: $error'),
/// )
/// ```
///
/// The three builders cover the full lifecycle: [builder] once the device
/// is ready (the "data" state), [loadingBuilder] while it boots, and
/// [errorBuilder] when creation fails. The device itself is the shared
/// app-lifetime [WebGpu.device] — created once, reused by every builder.
class WebGpuBuilder extends StatelessWidget {
  const WebGpuBuilder({
    super.key,
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
  });

  /// Built once the device is ready.
  final Widget Function(BuildContext context, GpuDevice device) builder;

  /// Built while the device boots. Defaults to an empty box — device
  /// creation is fast enough that a spinner usually just flashes.
  final WidgetBuilder? loadingBuilder;

  /// Built when device creation fails (no GPU, driver failure).
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<GpuDevice>(
      future: WebGpu.device(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return errorBuilder?.call(context, snapshot.error!) ??
              Center(
                child: Text(
                  'WebGPU unavailable: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              );
        }
        final device = snapshot.data;
        if (device == null) {
          return loadingBuilder?.call(context) ?? const SizedBox.expand();
        }
        return builder(context, device);
      },
    );
  }
}
