#ifndef PROCESS_EVENT_SINK_H_
#define PROCESS_EVENT_SINK_H_

#include <flutter/event_stream_handler.h>
#include <flutter/encodable_value.h>

#define _WIN32_DCOM
#include <Wbemidl.h>
#include <windows.h>
#include <atlbase.h>

#include <string>
#include <thread>
#include <mutex>

class ProcessEventSink : public IWbemObjectSink
{
public:
    ProcessEventSink();
    virtual ~ProcessEventSink();

    // EventSink methods for handling Flutter events
    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListen(
        const flutter::EncodableValue *arguments,
        std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> &&events //
    );

    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancel(
        const flutter::EncodableValue *arguments //
    );

    // IWbemObjectSink
    ULONG STDMETHODCALLTYPE AddRef();
    ULONG STDMETHODCALLTYPE Release();
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv);
    HRESULT STDMETHODCALLTYPE Indicate(LONG lObjectCount, IWbemClassObject **apObjArray);
    HRESULT STDMETHODCALLTYPE SetStatus(LONG lFlags, HRESULT hResult, BSTR strParam, IWbemClassObject *pObjParam);

private:
    LONG m_lRef;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> m_sink;
    IWbemServices *m_pSvc = nullptr;
    IUnsecuredApartment *m_pUnsecApp = nullptr;
    IWbemObjectSink *m_pStubSink = nullptr;

    void Cleanup();
};

#endif // PROCESS_EVENT_SINK_H_