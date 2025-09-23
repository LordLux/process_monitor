#ifndef FLUTTER_PLUGIN_PROCESS_MONITOR_PLUGIN_H_
#define FLUTTER_PLUGIN_PROCESS_MONITOR_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace process_monitor
{

    class ProcessMonitorPlugin : public flutter::Plugin
    {
    public:
        static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

        ProcessMonitorPlugin();

        virtual ~ProcessMonitorPlugin();

        // Disallow copy and assign.
        ProcessMonitorPlugin(const ProcessMonitorPlugin &) = delete;
        ProcessMonitorPlugin &operator=(const ProcessMonitorPlugin &) = delete;

    private:
        // Called when a method is called on this plugin's channel from Dart.
        void HandleMethodCall(
            const flutter::MethodCall<flutter::EncodableValue> &method_call,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result //
        );
    };

} // namespace process_monitor

#endif // FLUTTER_PLUGIN_PROCESS_MONITOR_PLUGIN_H_