#include "process_monitor_api.h"
#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <queue>
#include <chrono>

#define _WIN32_DCOM
#include <Wbemidl.h>
#include <windows.h>
#include <comdef.h>

// Global state for FFI
static std::string g_last_error;
static std::atomic<bool> g_monitoring = false;
static std::thread g_monitor_thread;
static std::queue<ProcessEventData> g_event_queue;
static std::mutex g_queue_mutex;
static std::atomic<bool> g_com_initialized = false;

// Event signaling mechanism
static HANDLE g_event_available = nullptr;

// Callback mechanism (kept for compatibility)
static ProcessEventCallback g_event_callback = nullptr;
static void* g_callback_user_data = nullptr;

// Forward declaration
class FFIProcessEventSink;
static FFIProcessEventSink* g_event_sink = nullptr;

class FFIProcessEventSink : public IWbemObjectSink
{
private:
    LONG m_lRef;
    IWbemServices *m_pSvc = nullptr;
    IUnsecuredApartment *m_pUnsecApp = nullptr;
    IWbemObjectSink *m_pStubSink = nullptr;

public:
    FFIProcessEventSink() : m_lRef(0) {}
    virtual ~FFIProcessEventSink() { 
        // Don't call Cleanup() in destructor - this can cause crashes
        // We'll call it explicitly when safe
    }

    // IUnknown methods
    ULONG STDMETHODCALLTYPE AddRef()
    {
        return InterlockedIncrement(&m_lRef);
    }

    ULONG STDMETHODCALLTYPE Release()
    {
        LONG lRef = InterlockedDecrement(&m_lRef);
        if (lRef == 0)
            delete this;
        return lRef;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv)
    {
        if (riid == IID_IUnknown || riid == IID_IWbemObjectSink)
        {
            *ppv = (IWbemObjectSink *)this;
            AddRef();
            return WBEM_S_NO_ERROR;
        }
        return E_NOINTERFACE;
    }

    // IWbemObjectSink methods
    HRESULT STDMETHODCALLTYPE Indicate(LONG lObjectCount, IWbemClassObject **apObjArray)
    {
        for (long i = 0; i < lObjectCount; i++)
        {
            VARIANT vtProp;
            VariantInit(&vtProp);
            HRESULT hr = apObjArray[i]->Get(_bstr_t(L"TargetInstance"), 0, &vtProp, 0, 0);

            if (SUCCEEDED(hr))
            {
                IWbemClassObject *pTargetInstance = (IWbemClassObject *)vtProp.punkVal;

                VARIANT vtProcessName;
                VariantInit(&vtProcessName);
                pTargetInstance->Get(L"Name", 0, &vtProcessName, 0, 0);

                VARIANT vtProcessId;
                VariantInit(&vtProcessId);
                pTargetInstance->Get(L"ProcessId", 0, &vtProcessId, 0, 0);

                std::wstring processName = vtProcessName.bstrVal;
                uint32_t processId = vtProcessId.uintVal;

                // Convert wide string to UTF-8
                int utf8_length = WideCharToMultiByte(CP_UTF8, 0, processName.c_str(), -1, nullptr, 0, nullptr, nullptr);
                std::string utf8_processName(utf8_length - 1, 0);
                WideCharToMultiByte(CP_UTF8, 0, processName.c_str(), -1, &utf8_processName[0], utf8_length, nullptr, nullptr);

                // Get event type
                _variant_t vtClass;
                apObjArray[i]->Get(_bstr_t(L"__CLASS"), 0, &vtClass, NULL, NULL);

                ProcessEventData event_data = {0};
                strncpy_s(event_data.process_name, sizeof(event_data.process_name), utf8_processName.c_str(), _TRUNCATE);
                event_data.process_id = (int)processId;
                
                // Use system clock to get proper Unix epoch timestamp
                auto now = std::chrono::system_clock::now();
                auto duration = now.time_since_epoch();
                auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
                event_data.timestamp_ms = millis;

                if (wcscmp(vtClass.bstrVal, L"__InstanceCreationEvent") == 0)
                    strncpy_s(event_data.event_type, sizeof(event_data.event_type), "start", _TRUNCATE);
                else
                    strncpy_s(event_data.event_type, sizeof(event_data.event_type), "stop", _TRUNCATE);

                // Add to queue and signal event availability
                {
                    std::lock_guard<std::mutex> lock(g_queue_mutex);
                    g_event_queue.push(event_data);
                    
                    // Limit queue size to prevent memory issues
                    while (g_event_queue.size() > 1000) {
                        g_event_queue.pop();
                    }
                }
                
                // Signal that new events are available
                if (g_event_available != nullptr) {
                    SetEvent(g_event_available);
                }
                
                // If we have a callback, call it immediately (kept for compatibility)
                if (g_event_callback != nullptr) {
                    try {
                        g_event_callback(&event_data, g_callback_user_data);
                    }
                    catch (...) {
                        // Ignore callback errors to prevent crashes
                    }
                }

                VariantClear(&vtProcessName);
                VariantClear(&vtProcessId);
                VariantClear(&vtClass);
                pTargetInstance->Release();
            }
            VariantClear(&vtProp);
        }

        return WBEM_S_NO_ERROR;
    }

    HRESULT STDMETHODCALLTYPE SetStatus(LONG lFlags, HRESULT hResult, BSTR strParam, IWbemClassObject *pObjParam)
    {
        return WBEM_S_NO_ERROR;
    }

    bool Initialize()
    {
        HRESULT hres;

        // Only initialize COM if it hasn't been initialized yet
        if (!g_com_initialized.exchange(true)) {
            hres = CoInitializeEx(0, COINIT_MULTITHREADED);
            if (FAILED(hres) && hres != RPC_E_CHANGED_MODE)
            {
                g_com_initialized = false;
                g_last_error = "Failed to initialize COM library. Error code = 0x" + std::to_string(hres);
                return false;
            }

            hres = CoInitializeSecurity(NULL, -1, NULL, NULL, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE, NULL);
            if (FAILED(hres) && hres != RPC_E_TOO_LATE)
            {
                g_last_error = "Failed to initialize security. Error code = 0x" + std::to_string(hres);
                // Don't fail completely on security init failure
            }
        }

        IWbemLocator *pLoc = NULL;
        hres = CoCreateInstance(CLSID_WbemLocator, 0, CLSCTX_INPROC_SERVER, IID_IWbemLocator, (LPVOID *)&pLoc);
        if (FAILED(hres))
        {
            CoUninitialize();
            g_last_error = "Failed to create IWbemLocator object. Error code = 0x" + std::to_string(hres);
            return false;
        }

        hres = pLoc->ConnectServer(_bstr_t(L"ROOT\\CIMV2"), NULL, NULL, 0, NULL, 0, 0, &m_pSvc);
        if (FAILED(hres))
        {
            pLoc->Release();
            CoUninitialize();
            g_last_error = "Could not connect to WMI. Error code = 0x" + std::to_string(hres);
            return false;
        }

        hres = CoSetProxyBlanket(m_pSvc, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE, NULL, RPC_C_AUTHN_LEVEL_CALL, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE);
        if (FAILED(hres))
        {
            m_pSvc->Release();
            pLoc->Release();
            CoUninitialize();
            g_last_error = "Could not set proxy blanket. Error code = 0x" + std::to_string(hres);
            return false;
        }

        IUnsecuredApartment *pUnsecApp = NULL;
        hres = CoCreateInstance(CLSID_UnsecuredApartment, NULL, CLSCTX_LOCAL_SERVER, IID_IUnsecuredApartment, (void **)&pUnsecApp);
        if (FAILED(hres))
        {
            m_pSvc->Release();
            pLoc->Release();
            CoUninitialize();
            g_last_error = "Failed to create IUnsecuredApartment. Error code = 0x" + std::to_string(hres);
            return false;
        }

        pUnsecApp->CreateObjectStub(this, (IUnknown**)&m_pStubSink);
        pUnsecApp->Release();
        pLoc->Release();

        // Creation events
        hres = m_pSvc->ExecNotificationQueryAsync(
            _bstr_t("WQL"),
            _bstr_t("SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'"),
            WBEM_FLAG_SEND_STATUS,
            NULL,
            m_pStubSink
        );

        if (FAILED(hres))
        {
            Cleanup();
            g_last_error = "ExecNotificationQueryAsync (creation) failed. Error code = 0x" + std::to_string(hres);
            return false;
        }

        // Deletion events
        hres = m_pSvc->ExecNotificationQueryAsync(
            _bstr_t("WQL"),
            _bstr_t("SELECT * FROM __InstanceDeletionEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'"),
            WBEM_FLAG_SEND_STATUS,
            NULL,
            m_pStubSink
        );

        if (FAILED(hres))
        {
            Cleanup();
            g_last_error = "ExecNotificationQueryAsync (deletion) failed. Error code = 0x" + std::to_string(hres);
            return false;
        }

        return true;
    }

    void Cleanup()
    {
        if (m_pSvc)
        {
            if (m_pStubSink)
                m_pSvc->CancelAsyncCall(m_pStubSink);
            m_pSvc->Release();
            m_pSvc = nullptr;
        }
        if (m_pStubSink)
        {
            m_pStubSink->Release();
            m_pStubSink = nullptr;
        }
        CoUninitialize();
    }
};

// Monitor thread function
void monitor_thread_function()
{
    g_event_sink = new FFIProcessEventSink();
    
    if (!g_event_sink->Initialize())
    {
        delete g_event_sink;
        g_event_sink = nullptr;
        g_monitoring = false;
        return;
    }

    // Keep the thread alive while monitoring
    while (g_monitoring)
    {
        Sleep(50); // Sleep for 50ms - more responsive to stop signal
    }

    // DO NOT call Cleanup() here - this causes crashes
    // Just set the pointer to nullptr - cleanup will happen in cleanup_process_monitor()
    g_event_sink = nullptr;
}

// C API Implementation
extern "C" {

PROCESS_MONITOR_API bool initialize_process_monitor()
{
    g_last_error.clear();
    return true;
}

PROCESS_MONITOR_API bool start_monitoring()
{
    if (g_monitoring)
    {
        g_last_error = "Process monitor is already running";
        return false;
    }

    // Create event handle for signaling
    if (g_event_available == nullptr) {
        g_event_available = CreateEvent(nullptr, FALSE, FALSE, nullptr); // Auto-reset event
        if (g_event_available == nullptr) {
            g_last_error = "Failed to create event handle";
            return false;
        }
    }

    // Clear any existing events
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        while (!g_event_queue.empty()) {
            g_event_queue.pop();
        }
    }

    g_monitoring = true;

    // Wait for any previous thread to finish
    if (g_monitor_thread.joinable()) {
        g_monitor_thread.join();
    }

    // Start the monitoring thread
    try {
        g_monitor_thread = std::thread(monitor_thread_function);
    }
    catch (...) {
        g_monitoring = false;
        g_last_error = "Failed to start monitoring thread";
        return false;
    }

    return true;
}

PROCESS_MONITOR_API bool start_monitoring_with_callback(ProcessEventCallback callback, void* user_data)
{
    if (g_monitoring)
    {
        g_last_error = "Process monitor is already running";
        return false;
    }

    // Set the callback
    g_event_callback = callback;
    g_callback_user_data = user_data;

    // Clear any existing events
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        while (!g_event_queue.empty()) {
            g_event_queue.pop();
        }
    }

    g_monitoring = true;

    // Wait for any previous thread to finish
    if (g_monitor_thread.joinable()) {
        g_monitor_thread.join();
    }

    // Start the monitoring thread
    try {
        g_monitor_thread = std::thread(monitor_thread_function);
    }
    catch (...) {
        g_monitoring = false;
        g_event_callback = nullptr;
        g_callback_user_data = nullptr;
        g_last_error = "Failed to start monitoring thread";
        return false;
    }

    return true;
}

PROCESS_MONITOR_API bool stop_monitoring()
{
    // Simply set the flag - no blocking operations at all
    g_monitoring = false;
    
    // Clear callback
    g_event_callback = nullptr;
    g_callback_user_data = nullptr;
    
    return true;
}

PROCESS_MONITOR_API bool get_next_event(ProcessEventData* event_data)
{
    if (!event_data) return false;

    std::lock_guard<std::mutex> lock(g_queue_mutex);
    if (g_event_queue.empty()) {
        return false;
    }

    *event_data = g_event_queue.front();
    g_event_queue.pop();
    return true;
}

PROCESS_MONITOR_API bool is_monitoring()
{
    return g_monitoring;
}

PROCESS_MONITOR_API int get_pending_event_count()
{
    std::lock_guard<std::mutex> lock(g_queue_mutex);
    return (int)g_event_queue.size();
}

PROCESS_MONITOR_API int wait_for_events(int timeout_ms)
{
    if (g_event_available == nullptr) {
        return -1; // Not initialized
    }
    
    DWORD result = WaitForSingleObject(g_event_available, timeout_ms);
    if (result == WAIT_OBJECT_0) {
        // Event was signaled, return number of available events
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        return (int)g_event_queue.size();
    } else if (result == WAIT_TIMEOUT) {
        return 0; // Timeout
    } else {
        return -1; // Error
    }
}

PROCESS_MONITOR_API int get_all_events(ProcessEventData* events_array, int max_events)
{
    if (!events_array || max_events <= 0) {
        return 0;
    }
    
    std::lock_guard<std::mutex> lock(g_queue_mutex);
    int count = 0;
    
    while (!g_event_queue.empty() && count < max_events) {
        events_array[count] = g_event_queue.front();
        g_event_queue.pop();
        count++;
    }
    
    return count;
}

PROCESS_MONITOR_API void cleanup_process_monitor()
{
    // Set flag to prevent any new operations
    static std::atomic<bool> cleanup_in_progress{false};
    if (cleanup_in_progress.exchange(true)) {
        // Cleanup already in progress, don't do it again
        return;
    }
    
    try {
        // Stop monitoring first (non-blocking)
        if (g_monitoring) {
            g_monitoring = false;
        }
        
        // Wait for thread to finish safely
        if (g_monitor_thread.joinable()) {
            try {
                // Give thread time to see the stop signal
                Sleep(100);
                
                // Try to join with timeout
                auto start_time = GetTickCount64();
                while (g_monitor_thread.joinable() && (GetTickCount64() - start_time) < 1000) {
                    Sleep(50);
                }
                
                // If still running, detach it (don't force terminate)
                if (g_monitor_thread.joinable()) {
                    g_monitor_thread.detach();
                }
            }
            catch (...) {
                // If anything fails, just detach safely
                try {
                    if (g_monitor_thread.joinable()) {
                        g_monitor_thread.detach();
                    }
                }
                catch (...) {
                    // Ignore any detach errors
                }
            }
        }
        
        // Clean up any remaining event sink (if the thread didn't finish cleanly)
        if (g_event_sink) {
            try {
                g_event_sink->Cleanup();
                delete g_event_sink;
            }
            catch (...) {
                // Ignore cleanup errors - just set to null
            }
            g_event_sink = nullptr;
        }
        
        // Clear the queue safely
        try {
            std::lock_guard<std::mutex> lock(g_queue_mutex);
            while (!g_event_queue.empty()) {
                g_event_queue.pop();
            }
        }
        catch (...) {
            // Ignore queue cleanup errors
        }
        
        // Clean up event handle
        if (g_event_available != nullptr) {
            try {
                CloseHandle(g_event_available);
            }
            catch (...) {
                // Ignore handle cleanup errors
            }
            g_event_available = nullptr;
        }
        
        // Clean up COM if we initialized it - but only if we're not in DLL unload
        if (g_com_initialized.exchange(false)) {
            try {
                // Don't uninitialize COM during process shutdown - can cause crashes
                // Just mark it as cleaned up
                // CoUninitialize();
            }
            catch (...) {
                // Ignore any COM cleanup errors
            }
        }
        
        g_last_error.clear();
    }
    catch (...) {
        // Ignore all cleanup errors to prevent crashes during app shutdown
    }
}

PROCESS_MONITOR_API const char* get_last_error()
{
    return g_last_error.c_str();
}

} // extern "C"