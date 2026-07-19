import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One trigger for an action: any held key in [keys], or any pressed
/// mouse button in the [buttons] bitmask, activates it.
class GpuInputBinding {
  const GpuInputBinding({this.keys = const {}, this.buttons = 0});

  final Set<LogicalKeyboardKey> keys;

  /// Mouse-button bitmask ([kPrimaryButton], [kSecondaryButton],
  /// [kMiddleMouseButton], ...) — 0 means keys only.
  final int buttons;
}

/// A two-sided axis: reads -1 while [negative] is active, +1 for
/// [positive], 0 for neither or both.
class GpuInputAxis {
  const GpuInputAxis({required this.negative, required this.positive});

  final GpuInputBinding negative;
  final GpuInputBinding positive;
}

/// The custom mapper: your gameplay names on the left, whatever keys and
/// mouse buttons should trigger them on the right. Game code polls
/// `inputs.action('fire')` and never mentions a key again — rebinding is
/// swapping this map (it's a plain field on [GpuInputs], so a settings
/// screen can replace it at runtime).
///
/// ```dart
/// // (Not const — LogicalKeyboardKey overrides ==, which const sets
/// // disallow.)
/// final inputs = GpuInputs(
///   map: GpuInputMap(
///     actions: {
///       'fire': GpuInputBinding(
///           keys: {LogicalKeyboardKey.space}, buttons: kPrimaryButton),
///       'boost': GpuInputBinding(keys: {LogicalKeyboardKey.shiftLeft}),
///     },
///     axes: {
///       'steer': GpuInputAxis(
///         negative: GpuInputBinding(keys: {LogicalKeyboardKey.keyA}),
///         positive: GpuInputBinding(keys: {LogicalKeyboardKey.keyD}),
///       ),
///     },
///   ),
/// );
/// ```
class GpuInputMap {
  const GpuInputMap({this.actions = const {}, this.axes = const {}});

  final Map<String, GpuInputBinding> actions;
  final Map<String, GpuInputAxis> axes;
}

/// Live input state fed by a [WebGpuInputArea] and polled from a frame
/// callback — the natural shape for GPU content, where a loop already runs
/// every frame and per-event rebuilds would only cost performance:
///
/// ```dart
/// final inputs = GpuInputs();
///
/// WebGpuInputArea(
///   inputs: inputs,
///   child: WebGpuView(device: device, onFrame: _frame),
/// )
///
/// void _frame(GpuRenderTarget target, Duration elapsed) {
///   final move = inputs.moveAxis;          // arrows/WASD, -1..1 each axis
///   final aim = inputs.uv;                 // pointer, 0-1, y-down
///   if (inputs.isKeyDown(LogicalKeyboardKey.space)) fire();
///   ...
/// }
/// ```
///
/// Reading is allocation-free and nothing notifies: mutate-and-poll, not
/// streams. Fields are plain and writable, so tests (or replays) can inject
/// synthetic input by assigning them directly.
class GpuInputs {
  GpuInputs({this.map = const GpuInputMap()});

  /// Named action/axis bindings — swap at runtime to rebind.
  GpuInputMap map;

  /// Pointer position in logical pixels, local to the area.
  Offset position = Offset.zero;

  /// Pointer position normalized to 0–1 over the area, y-down — multiply
  /// by `(target.width, target.height)` for render-pixel coordinates that
  /// stay correct under any `renderScale`.
  Offset uv = Offset.zero;

  /// Whether any pointer button (or touch) is down.
  bool mouseDown = false;

  /// Whether the pointer is currently over the area (hover platforms;
  /// requires `trackHover`, the default).
  bool pointerInside = false;

  /// Raw [PointerEvent.buttons] bitmask of the last pointer event.
  int buttons = 0;

  /// Logical size of the area (updated at layout).
  Size size = Size.zero;

  double devicePixelRatio = 1.0;

  final Set<LogicalKeyboardKey> _keys = {};

  bool isKeyDown(LogicalKeyboardKey key) => _keys.contains(key);

  /// Whether any key at all is held.
  bool get anyKeyDown => _keys.isNotEmpty;

  /// The currently held keys (live, read-only view).
  Iterable<LogicalKeyboardKey> get keysDown => _keys;

  /// -1, 0, or 1 from a pair of keys — `axis(keyA, keyD)` for strafing.
  double axis(LogicalKeyboardKey negative, LogicalKeyboardKey positive) =>
      (isKeyDown(positive) ? 1.0 : 0.0) - (isKeyDown(negative) ? 1.0 : 0.0);

  /// Arrow keys and WASD merged into one -1..1 vector — x is
  /// right-positive, y is down-positive (screen convention, matching [uv]).
  Offset get moveAxis => Offset(
        axis(LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight) +
            axis(LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD),
        axis(LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown) +
            axis(LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyS),
      ).clampAxes();

  /// Whether any button in [buttonMask] is pressed —
  /// `isButtonDown(kSecondaryButton)` for right-click checks.
  bool isButtonDown(int buttonMask) => buttons & buttonMask != 0;

  bool _active(GpuInputBinding binding) {
    if (binding.buttons != 0 && (buttons & binding.buttons) != 0) {
      return true;
    }
    for (final key in binding.keys) {
      if (_keys.contains(key)) return true;
    }
    return false;
  }

  /// Whether the named action from [map] is currently triggered (any of
  /// its keys held, or any of its mouse buttons pressed). Unknown names
  /// read false.
  bool action(String name) {
    final binding = map.actions[name];
    return binding != null && _active(binding);
  }

  /// The -1..1 value of a named axis from [map]. Unknown names read 0.
  double axisValue(String name) {
    final axis = map.axes[name];
    if (axis == null) return 0;
    return (_active(axis.positive) ? 1.0 : 0.0) -
        (_active(axis.negative) ? 1.0 : 0.0);
  }

  Offset _scroll = Offset.zero;

  /// Scroll accumulated since the last call — call once per frame so
  /// wheel input isn't lost between ticks (frames and pointer events
  /// don't run in lockstep).
  Offset takeScroll() {
    final s = _scroll;
    _scroll = Offset.zero;
    return s;
  }

  Offset _pointerDelta = Offset.zero;

  /// Pointer movement accumulated since the last call — call once per
  /// frame for drag/look controls that must not lose motion between
  /// ticks.
  Offset takePointerDelta() {
    final d = _pointerDelta;
    _pointerDelta = Offset.zero;
    return d;
  }
}

extension on Offset {
  Offset clampAxes() =>
      Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
}

/// Binds pointer and keyboard input to a [GpuInputs] object for the GPU
/// content it wraps — typically a `WebGpuView`. The child renders
/// untouched; input lands as plain field writes on [inputs], so no widget
/// rebuilds and no frame drops, no matter how fast events arrive.
///
/// Keyboard events are captured through Flutter's focus system: the area
/// takes focus on [autofocus] (default) and on pointer-down, and never
/// consumes keys — app-level shortcuts keep working.
class WebGpuInputArea extends StatefulWidget {
  const WebGpuInputArea({
    super.key,
    required this.inputs,
    required this.child,
    this.autofocus = true,
    this.trackHover = true,
  });

  /// The state object this area writes into. Owned by the caller so the
  /// frame callback (and anything else) can read it directly.
  final GpuInputs inputs;

  final Widget child;

  /// Grab keyboard focus when first laid out.
  final bool autofocus;

  /// Track pointer position while hovering (not just while pressed).
  final bool trackHover;

  @override
  State<WebGpuInputArea> createState() => _WebGpuInputAreaState();
}

class _WebGpuInputAreaState extends State<WebGpuInputArea> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'WebGpuInputArea');

  void _position(PointerEvent event) {
    final inputs = widget.inputs;
    inputs.position = event.localPosition;
    inputs._pointerDelta += event.localDelta;
    final size = inputs.size;
    if (size.width > 0 && size.height > 0) {
      inputs.uv = Offset(
        event.localPosition.dx / size.width,
        event.localPosition.dy / size.height,
      );
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final keys = widget.inputs._keys;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      keys.add(event.logicalKey);
    } else if (event is KeyUpEvent) {
      keys.remove(event.logicalKey);
    }
    return KeyEventResult.ignored; // observe, never consume
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget result = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _focusNode.requestFocus();
        widget.inputs
          ..mouseDown = true
          ..buttons = event.buttons;
        _position(event);
      },
      onPointerMove: (event) {
        widget.inputs.buttons = event.buttons;
        _position(event);
      },
      onPointerUp: (event) {
        widget.inputs
          ..mouseDown = false
          ..buttons = 0;
        _position(event);
      },
      onPointerCancel: (_) {
        widget.inputs
          ..mouseDown = false
          ..buttons = 0;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          widget.inputs._scroll += event.scrollDelta;
        }
      },
      child: widget.child,
    );
    if (widget.trackHover) {
      result = MouseRegion(
        onHover: _position,
        onEnter: (_) => widget.inputs.pointerInside = true,
        onExit: (_) => widget.inputs.pointerInside = false,
        opaque: false,
        child: result,
      );
    }
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: LayoutBuilder(builder: (context, constraints) {
        widget.inputs
          ..size = Size(constraints.maxWidth, constraints.maxHeight)
          ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        return result;
      }),
    );
  }
}
