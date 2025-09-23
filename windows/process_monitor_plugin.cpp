#include "process_monitor_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "process_event_sink.h"

namespace process_monitor
{

  // static
  void ProcessMonitorPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar)
  {
    auto plugin = std::make_unique<ProcessMonitorPlugin>();

    auto event_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        registrar->messenger(), "process_monitor/process_events",
        &flutter::StandardMethodCodec::GetInstance() //
    );

    // Create a shared pointer to the ProcessEventSink to keep it alive
    static auto sink = std::make_shared<ProcessEventSink>();
    
    // Create stream handler with lambda functions
    event_channel->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
            [](const flutter::EncodableValue* arguments,
               std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
               -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
                return sink->OnListen(arguments, std::move(events));
            },
            [](const flutter::EncodableValue* arguments)
               -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
                return sink->OnCancel(arguments);
            }
        )
    );

    registrar->AddPlugin(std::move(plugin));
  }

  ProcessMonitorPlugin::ProcessMonitorPlugin() {}

  ProcessMonitorPlugin::~ProcessMonitorPlugin() {}

} // namespace process_monitor