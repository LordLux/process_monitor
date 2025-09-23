#ifndef PROCESS_MONITOR_API_H_
#define PROCESS_MONITOR_API_H_

#ifdef _WIN32
  #ifdef BUILDING_PROCESS_MONITOR_DLL
    #define PROCESS_MONITOR_API __declspec(dllexport)
  #else
    #define PROCESS_MONITOR_API __declspec(dllimport)
  #endif
#else
  #define PROCESS_MONITOR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Process event structure for FFI
typedef struct {
    char event_type[32];     // "start" or "stop"
    char process_name[512];  // Process name
    int process_id;          // Process ID
    long long timestamp_ms;  // Timestamp in milliseconds since epoch
} ProcessEventData;

// Callback function type for process events
typedef void (*ProcessEventCallback)(const ProcessEventData* event_data, void* user_data);

// Initialize the process monitor
PROCESS_MONITOR_API bool initialize_process_monitor();

// Start monitoring processes (polling mode)
PROCESS_MONITOR_API bool start_monitoring();

// Start monitoring with callback (immediate notification)
PROCESS_MONITOR_API bool start_monitoring_with_callback(ProcessEventCallback callback, void* user_data);

// Stop monitoring processes
PROCESS_MONITOR_API bool stop_monitoring();

// Get the next available process event (returns false if no events)
PROCESS_MONITOR_API bool get_next_event(ProcessEventData* event_data);

// Wait for new events (blocks until events are available or timeout)
// Returns number of events available, or 0 on timeout, -1 on error
PROCESS_MONITOR_API int wait_for_events(int timeout_ms);

// Get all available events at once (up to max_events)
// Returns actual number of events retrieved
PROCESS_MONITOR_API int get_all_events(ProcessEventData* events_array, int max_events);

// Check if monitoring is currently active
PROCESS_MONITOR_API bool is_monitoring();

// Get count of pending events in queue
PROCESS_MONITOR_API int get_pending_event_count();

// Cleanup and release resources
PROCESS_MONITOR_API void cleanup_process_monitor();

// Get the last error message (if any)
PROCESS_MONITOR_API const char* get_last_error();

#ifdef __cplusplus
}
#endif

#endif // PROCESS_MONITOR_API_H_