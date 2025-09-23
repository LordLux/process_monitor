#include "include/process_monitor/process_monitor_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "process_monitor_plugin.h"

void ProcessMonitorPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  process_monitor::ProcessMonitorPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
