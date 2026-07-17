//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <nitro_webgpu/nitro_webgpu_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) nitro_webgpu_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "NitroWebgpuPlugin");
  nitro_webgpu_plugin_register_with_registrar(nitro_webgpu_registrar);
}
