/// WebGPU for Flutter, powered by wgpu-native.
library;

export 'src/api/gpu.dart';
// Widgets, tiered by how much control you want:
//  - foundation: shared device + boot ([WebGpu], [WebGpuBuilder])
//  - presentation: bring-your-own-frame rendering ([WebGpuView])
//  - effects: one-liner shaders ([WebGpuShaderView])
export 'src/widgets/foundation/web_gpu.dart' show WebGpu;
export 'src/widgets/foundation/web_gpu_builder.dart' show WebGpuBuilder;
export 'src/widgets/presentation/web_gpu_view.dart' show WebGpuView;
export 'src/widgets/effects/web_gpu_shader_view.dart'
    show WebGpuShaderView, ShaderViewLanguage;
