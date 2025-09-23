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

// Initialize the process monitor
PROCESS_MONITOR_API bool initialize_process_monitor();

// Start monitoring processes (no callback - use polling instead)
PROCESS_MONITOR_API bool start_monitoring();

// Stop monitoring processes
PROCESS_MONITOR_API bool stop_monitoring();

// Poll for the next available process event (returns false if no events available)
PROCESS_MONITOR_API bool get_next_event(ProcessEventData* event_data);

// Check if monitoring is currently active
PROCESS_MONITOR_API bool is_monitoring();

// Get the number of pending events in the queue
PROCESS_MONITOR_API int get_pending_event_count();

// Cleanup and release resources
PROCESS_MONITOR_API void cleanup_process_monitor();

// Get the last error message (if any)
PROCESS_MONITOR_API const char* get_last_error();

#ifdef __cplusplus
}
#endif

#endif // PROCESS_MONITOR_API_H_