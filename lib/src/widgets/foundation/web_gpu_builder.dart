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
/// )
/// ```
class WebGpuBuilder extends StatelessWidget {
  const WebGpuBuilder({
    super.key,
    required this.builder,
    this.loading,
    this.error,
  });

  /// Built once the device is ready.
  final Widget Function(BuildContext context, GpuDevice device) builder;

  /// Shown while the device boots (defaults to an empty box — device
  /// creation is fast enough that a spinner usually just flashes).
  final Widget? loading;

  /// Built when device creation fails (no GPU, driver failure).
  final Widget Function(BuildContext context, Object error)? error;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<GpuDevice>(
      future: WebGpu.device(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return error?.call(context, snapshot.error!) ??
              Center(
                child: Text(
                  'WebGPU unavailable: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              );
        }
        final device = snapshot.data;
        if (device == null) return loading ?? const SizedBox.expand();
        return builder(context, device);
      },
    );
  }
}
