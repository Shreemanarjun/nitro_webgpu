import 'dart:typed_data';
import 'package:nitro_webgpu/nitro_webgpu.dart';

/// Measures real on-GPU pass duration with timestamp queries.
///
/// Usage per sampled frame:
///  1. `final writes = timer.begin();` — attach to a pass via
///     `timestampWrites:` (skip the sample when null: a readback is still
///     in flight).
///  2. Submit the pass as usual.
///  3. `final ms = await timer.finish();` — resolves the query slots,
///     reads them back, and returns the pass duration in milliseconds.
class GpuPassTimer {
  GpuPassTimer._(this._device, this._querySet, this._resolve, this._staging);

  final GpuDevice _device;
  final GpuQuerySet _querySet;
  final GpuBuffer _resolve;
  final GpuBuffer _staging;
  bool _busy = false;
  bool _disposed = false;

  /// Returns null when the device lacks the `timestamp-query` feature.
  static Future<GpuPassTimer?> create(GpuDevice device) async {
    if (!device.hasTimestampQueries) return null;
    final querySet = await device.createTimestampQuerySet(2);
    final resolve = device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.queryResolve | GpuBufferUsage.copySrc,
      label: 'pass-timer-resolve',
    );
    final staging = device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst,
      label: 'pass-timer-staging',
    );
    return GpuPassTimer._(device, querySet, resolve, staging);
  }

  /// Timestamp writes for the pass to be measured, or null while the
  /// previous sample's readback is still in flight.
  GpuTimestampWrites? begin() {
    if (_busy || _disposed) return null;
    return GpuTimestampWrites(querySet: _querySet);
  }

  /// Call after the timed pass was submitted. Returns the GPU duration in
  /// milliseconds, or null if the readback could not run.
  Future<double?> finish() async {
    if (_busy || _disposed) return null;
    _busy = true;
    try {
      final encoder = _device.createCommandEncoder(label: 'pass-timer');
      encoder.resolveQuerySet(_querySet, destination: _resolve);
      encoder.copyBufferToBuffer(_resolve, _staging);
      _device.queue.submit([encoder.finish()]);
      final Uint8List bytes;
      try {
        bytes = await _staging.mapRead();
      } on Exception {
        // "Buffer map aborted": the timer was disposed (scene switch/page
        // close) while the readback was in flight — drop the sample.
        return null;
      }
      final stamps = bytes.buffer.asUint64List(bytes.offsetInBytes, 2);
      if (_disposed) return null;
      final deltaTicks = stamps[1] - stamps[0];
      return deltaTicks * _device.queue.timestampPeriod / 1e6;
    } finally {
      _busy = false;
      if (_disposed) _release();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // A readback may still be in flight — destroying its buffer now aborts
    // the map (throws in finish); the finally block releases instead.
    if (!_busy) _release();
  }

  void _release() {
    _staging.dispose();
    _resolve.dispose();
    _querySet.dispose();
  }
}
