#include "process_event_sink.h"
#include <comdef.h>

ProcessEventSink::ProcessEventSink() : m_lRef(0) {}

ProcessEventSink::~ProcessEventSink() { Cleanup(); }

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> ProcessEventSink::OnListen(
    const flutter::EncodableValue *arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> &&events //
)
{
    m_sink = std::move(events);

    HRESULT hres;

    hres = CoInitializeEx(0, COINIT_MULTITHREADED);
    if (FAILED(hres))
    {
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_INIT_COM", "Failed to initialize COM library. Error code = 0x" + std::to_string(hres), nullptr //
        );
    }

    hres = CoInitializeSecurity(NULL, -1, NULL, NULL, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE, NULL);
    if (FAILED(hres))
    {
        CoUninitialize();
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_INIT_SECURITY", "Failed to initialize security. Error code = 0x" + std::to_string(hres), nullptr //
        );
    }

    IWbemLocator *pLoc = NULL;
    hres = CoCreateInstance(CLSID_WbemLocator, 0, CLSCTX_INPROC_SERVER, IID_IWbemLocator, (LPVOID *)&pLoc);
    if (FAILED(hres))
    {
        CoUninitialize();
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_CREATE_LOCATOR", "Failed to create IWbemLocator object. Err code = 0x" + std::to_string(hres), nullptr //
        );
    }

    hres = pLoc->ConnectServer(_bstr_t(L"ROOT\\CIMV2"), NULL, NULL, 0, NULL, 0, 0, &m_pSvc);
    if (FAILED(hres))
    {
        pLoc->Release();
        CoUninitialize();
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_CONNECT_SERVER", "Could not connect. Error code = 0x" + std::to_string(hres), nullptr //
        );
    }

    hres = CoSetProxyBlanket(m_pSvc, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE, NULL, RPC_C_AUTHN_LEVEL_CALL, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE);
    if (FAILED(hres))
    {
        m_pSvc->Release();
        pLoc->Release();
        CoUninitialize();
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_PROXY_BLANKET", "Could not set proxy blanket. Error code = 0x" + std::to_string(hres), nullptr //
        );
    }

    IUnsecuredApartment *pUnsecApp = NULL;
    hres = CoCreateInstance(CLSID_UnsecuredApartment, NULL, CLSCTX_LOCAL_SERVER, IID_IUnsecuredApartment, (void **)&pUnsecApp);
    if (FAILED(hres))
    {
        m_pSvc->Release();
        pLoc->Release();
        CoUninitialize();
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_UNSECURED_APARTMENT", "Failed to create IUnsecuredApartment. Error code = 0x" + std::to_string(hres), nullptr //
        );
    }

    pUnsecApp->CreateObjectStub(this, (IUnknown**)&m_pStubSink);
    pUnsecApp->Release();
    pLoc->Release();

    // Creation events
    hres = m_pSvc->ExecNotificationQueryAsync(
        _bstr_t("WQL"),
        _bstr_t(
            "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'"),
        WBEM_FLAG_SEND_STATUS,
        NULL,
        m_pStubSink //
    );

    // Deletion events
    hres = m_pSvc->ExecNotificationQueryAsync(
        _bstr_t("WQL"),
        _bstr_t(
            "SELECT * FROM __InstanceDeletionEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'"),
        WBEM_FLAG_SEND_STATUS,
        NULL,
        m_pStubSink //
    );

    if (FAILED(hres))
    {
        Cleanup();
        return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
            "ERROR_QUERY_ASYNC", "ExecNotificationQueryAsync failed. Error code = 0x" + std::to_string(hres), nullptr //
        );
    }

    return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> ProcessEventSink::OnCancel(
    const flutter::EncodableValue *arguments //
)
{
    Cleanup();
    return nullptr;
}

void ProcessEventSink::Cleanup()
{
    if (m_pSvc)
    {
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

ULONG ProcessEventSink::AddRef() { return InterlockedIncrement(&m_lRef); }

ULONG ProcessEventSink::Release()
{
    LONG lRef = InterlockedDecrement(&m_lRef);
    if (lRef == 0)
        delete this;
    return lRef;
}

HRESULT ProcessEventSink::QueryInterface(REFIID riid, void **ppv)
{
    if (riid == IID_IUnknown || riid == IID_IWbemObjectSink)
    {
        *ppv = (IWbemObjectSink *)this;
        AddRef();
        return WBEM_S_NO_ERROR;
    }
    // else
    return E_NOINTERFACE;
}

HRESULT ProcessEventSink::Indicate(LONG lObjectCount, IWbemClassObject **apObjArray)
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
            std::string utf8_processName(utf8_length - 1, 0); // -1 to exclude null terminator
            WideCharToMultiByte(CP_UTF8, 0, processName.c_str(), -1, &utf8_processName[0], utf8_length, nullptr, nullptr);

            flutter::EncodableMap event;
            event[flutter::EncodableValue("processName")] = flutter::EncodableValue(utf8_processName);
            event[flutter::EncodableValue("processId")] = flutter::EncodableValue((int64_t)processId);

            _variant_t vtClass;
            apObjArray[i]->Get(_bstr_t(L"__CLASS"), 0, &vtClass, NULL, NULL);

            if (wcscmp(vtClass.bstrVal, L"__InstanceCreationEvent") == 0)
                event[flutter::EncodableValue("eventType")] = flutter::EncodableValue("start");

            else
                event[flutter::EncodableValue("eventType")] = flutter::EncodableValue("stop");

            m_sink->Success(flutter::EncodableValue(event));

            VariantClear(&vtProcessName);
            VariantClear(&vtProcessId);
            VariantClear(&vtClass);
            pTargetInstance->Release();
        }
        VariantClear(&vtProp);
    }

    return WBEM_S_NO_ERROR;
}

HRESULT __stdcall ProcessEventSink::SetStatus(LONG lFlags, HRESULT hResult, BSTR strParam, IWbemClassObject *pObjParam)
{
    return WBEM_S_NO_ERROR;
}