#include "process_monitor_api.h"
#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>

#define _WIN32_DCOM
#include <Wbemidl.h>
#include <windows.h>
#include <atlbase.h>
#include <comdef.h>

// Global state for FFI
static std::string g_last_error;
static std::atomic<bool> g_monitoring = false;
static std::thread g_monitor_thread;
static ProcessEventCallback g_callback = nullptr;
static void* g_user_data = nullptr;
static std::mutex g_callback_mutex;

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
    virtual ~FFIProcessEventSink() { Cleanup(); }

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
        std::lock_guard<std::mutex> lock(g_callback_mutex);
        
        if (!g_callback) return WBEM_S_NO_ERROR;

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
                
                // Use high resolution timestamp
                auto now = std::chrono::high_resolution_clock::now();
                auto duration = now.time_since_epoch();
                auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
                event_data.timestamp_ms = millis;

                if (wcscmp(vtClass.bstrVal, L"__InstanceCreationEvent") == 0)
                    strncpy_s(event_data.event_type, sizeof(event_data.event_type), "start", _TRUNCATE);
                else
                    strncpy_s(event_data.event_type, sizeof(event_data.event_type), "stop", _TRUNCATE);

                // Call the user callback
                g_callback(&event_data, g_user_data);

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

        hres = CoInitializeEx(0, COINIT_MULTITHREADED);
        if (FAILED(hres))
        {
            g_last_error = "Failed to initialize COM library. Error code = 0x" + std::to_string(hres);
            return false;
        }

        hres = CoInitializeSecurity(NULL, -1, NULL, NULL, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE, NULL);
        if (FAILED(hres))
        {
            CoUninitialize();
            g_last_error = "Failed to initialize security. Error code = 0x" + std::to_string(hres);
            return false;
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
        Sleep(100); // Sleep for 100ms
    }

    // Cleanup
    delete g_event_sink;
    g_event_sink = nullptr;
}

// C API Implementation
extern "C" {

PROCESS_MONITOR_API bool initialize_process_monitor()
{
    g_last_error.clear();
    return true;
}

PROCESS_MONITOR_API bool start_monitoring(ProcessEventCallback callback, void* user_data)
{
    if (g_monitoring)
    {
        g_last_error = "Process monitor is already running";
        return false;
    }

    if (!callback)
    {
        g_last_error = "Callback function cannot be null";
        return false;
    }

    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_callback = callback;
    g_user_data = user_data;
    g_monitoring = true;

    // Start the monitoring thread
    g_monitor_thread = std::thread(monitor_thread_function);

    return true;
}

PROCESS_MONITOR_API bool stop_monitoring()
{
    if (!g_monitoring)
    {
        return true; // Already stopped
    }

    g_monitoring = false;

    if (g_monitor_thread.joinable())
    {
        g_monitor_thread.join();
    }

    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_callback = nullptr;
    g_user_data = nullptr;

    return true;
}

PROCESS_MONITOR_API void cleanup_process_monitor()
{
    stop_monitoring();
    g_last_error.clear();
}

PROCESS_MONITOR_API const char* get_last_error()
{
    return g_last_error.c_str();
}

} // extern "C"