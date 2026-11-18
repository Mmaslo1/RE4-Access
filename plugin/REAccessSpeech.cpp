// REAccessSpeech - REFramework plugin that speaks text through the player's screen reader.
// 0.4.0 (2026-11-17): speech goes through Prism 0.18.2 (prism.dll next to the game exe,
// https://github.com/ethindp/prism, MPL-2.0): NVDA, JAWS, Narrator, ZoomText and more,
// Windows OneCore voice when no reader runs. If prism.dll is missing or fails, the old
// built-in route is used (JAWS COM, NVDA controller client, SAPI).
// Shared RE Engine core: the Lua side writes messages to
//   <game>\reframework\data\REAccess_speech.txt
// in this format (whole file rewritten each time):
//   session <number>
//   <id>\t<interrupt 0/1>\t<text>
//   ...
//   END
// This plugin polls that file on its own thread and speaks every new id.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <ole2.h>
#include <sapi.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <atomic>
#include "prism.h"

static std::wstring g_gameDir;
static std::wstring g_speechFile;
static std::wstring g_logFile;
static std::atomic<bool> g_started{false};

static void Log(const std::string& msg) {
    SYSTEMTIME t; GetLocalTime(&t);
    char stamp[32];
    sprintf_s(stamp, "[%02d:%02d:%02d.%03d] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    std::ofstream f(g_logFile, std::ios::app);
    f << stamp << msg << "\n";
}

static std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

// ---------------- speech back ends ----------------

static IDispatch* g_jaws = nullptr;
static DISPID g_saystring = 0;
static ISpVoice* g_sapi = nullptr;

static bool JawsRunning() {
    return FindWindowW(L"JFWUI2", nullptr) != nullptr;
}

static bool InitJaws() {
    if (g_jaws) return true;
    CLSID clsid;
    if (FAILED(CLSIDFromProgID(L"FreedomSci.JawsApi", &clsid))) return false;
    if (FAILED(CoCreateInstance(clsid, nullptr, CLSCTX_ALL, IID_IDispatch, (void**)&g_jaws))) {
        g_jaws = nullptr;
        return false;
    }
    LPOLESTR name = (LPOLESTR)L"SayString";
    if (FAILED(g_jaws->GetIDsOfNames(IID_NULL, &name, 1, LOCALE_USER_DEFAULT, &g_saystring))) {
        g_jaws->Release(); g_jaws = nullptr;
        return false;
    }
    Log("JAWS API connected");
    return true;
}

static bool JawsSay(const std::wstring& text, bool interrupt) {
    if (!JawsRunning() && FindWindowW(L"JFWUI", nullptr) == nullptr) {
        // Window class differs between JAWS versions; still try the API.
    }
    if (!InitJaws()) return false;
    VARIANT args[2];
    VariantInit(&args[0]); VariantInit(&args[1]);
    // Arguments are passed in reverse order.
    args[1].vt = VT_BSTR; args[1].bstrVal = SysAllocString(text.c_str());
    args[0].vt = VT_BOOL; args[0].boolVal = interrupt ? VARIANT_TRUE : VARIANT_FALSE;
    DISPPARAMS dp = { args, nullptr, 2, 0 };
    VARIANT result; VariantInit(&result);
    HRESULT hr = g_jaws->Invoke(g_saystring, IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_METHOD, &dp, &result, nullptr, nullptr);
    SysFreeString(args[1].bstrVal);
    bool spoke = SUCCEEDED(hr) && !(result.vt == VT_BOOL && result.boolVal == VARIANT_FALSE);
    VariantClear(&result);
    if (!spoke) {
        // JAWS may have restarted; reconnect next time.
        g_jaws->Release(); g_jaws = nullptr;
        return false;
    }
    return true;
}

static bool SapiSay(const std::wstring& text, bool interrupt) {
    if (!g_sapi) {
        if (FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice, (void**)&g_sapi))) {
            g_sapi = nullptr;
            return false;
        }
        Log("SAPI voice ready (JAWS not found)");
    }
    DWORD flags = SPF_ASYNC | SPF_IS_NOT_XML;
    if (interrupt) flags |= SPF_PURGEBEFORESPEAK;
    return SUCCEEDED(g_sapi->Speak(text.c_str(), flags, nullptr));
}

// NVDA (0.3.0): nvdaControllerClient64.dll next to the game exe, loaded when first needed.
// Not in reframework\plugins, because REFramework loads every DLL there as a plugin.
typedef unsigned long (__stdcall *NvdaTest)();
typedef unsigned long (__stdcall *NvdaCancel)();
typedef unsigned long (__stdcall *NvdaSpeak)(const wchar_t*);
static NvdaTest g_nvdaTest = nullptr;
static NvdaCancel g_nvdaCancel = nullptr;
static NvdaSpeak g_nvdaSpeak = nullptr;
static bool g_nvdaTried = false;

static bool NvdaRunning() {
    if (!g_nvdaTried) {
        g_nvdaTried = true;
        HMODULE m = LoadLibraryW((g_gameDir + L"\\nvdaControllerClient64.dll").c_str());
        if (m) {
            g_nvdaTest = (NvdaTest)GetProcAddress(m, "nvdaController_testIfRunning");
            g_nvdaCancel = (NvdaCancel)GetProcAddress(m, "nvdaController_cancelSpeech");
            g_nvdaSpeak = (NvdaSpeak)GetProcAddress(m, "nvdaController_speakText");
        }
        Log(g_nvdaTest && g_nvdaCancel && g_nvdaSpeak ? "NVDA client loaded" : "NVDA client not available");
    }
    return g_nvdaTest && g_nvdaCancel && g_nvdaSpeak && g_nvdaTest() == 0;
}

static bool NvdaSay(const std::wstring& text, bool interrupt) {
    if (!NvdaRunning()) return false;
    if (interrupt) g_nvdaCancel();
    return g_nvdaSpeak(text.c_str()) == 0;
}

static bool g_comInit = false;

static void OldSpeak(const std::string& utf8, bool interrupt) {
    if (!g_comInit) { CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); g_comInit = true; }
    std::wstring w = Utf8ToWide(utf8);
    // NVDA first when it runs without JAWS. JAWS can stay installed and still answer
    // its API, so an installed JAWS must not take speech away from a running NVDA.
    if (!JawsRunning() && NvdaSay(w, interrupt)) { Log("NVDA: " + utf8); return; }
    if (JawsSay(w, interrupt)) { Log("JAWS: " + utf8); return; }
    if (NvdaSay(w, interrupt)) { Log("NVDA: " + utf8); return; }
    if (SapiSay(w, interrupt)) { Log("SAPI: " + utf8); return; }
    Log("NO SPEECH: " + utf8);
}

// ---------------- Prism (0.4.0) ----------------
// Loaded by full path from the game folder (not reframework\plugins: REFramework would
// treat it as a plugin). Only the worker thread touches Prism.
static decltype(&prism_init) p_init = nullptr;
static decltype(&prism_registry_create_best) p_create_best = nullptr;
static decltype(&prism_backend_name) p_name = nullptr;
static decltype(&prism_backend_speak) p_speak = nullptr;
static decltype(&prism_backend_free) p_free = nullptr;
static decltype(&prism_error_string) p_errstr = nullptr;
static decltype(&prism_version_string) p_version = nullptr;
static PrismContext* g_prism = nullptr;
static PrismBackend* g_backend = nullptr;
static std::string g_backendName;
static DWORD g_lastCreate = 0;

static bool PrismLoad() {
    HMODULE m = LoadLibraryW((g_gameDir + L"\\prism.dll").c_str());
    if (!m) { Log("prism.dll not found next to the game exe - using the old speech route"); return false; }
    p_init = (decltype(p_init))GetProcAddress(m, "prism_init");
    p_create_best = (decltype(p_create_best))GetProcAddress(m, "prism_registry_create_best");
    p_name = (decltype(p_name))GetProcAddress(m, "prism_backend_name");
    p_speak = (decltype(p_speak))GetProcAddress(m, "prism_backend_speak");
    p_free = (decltype(p_free))GetProcAddress(m, "prism_backend_free");
    p_errstr = (decltype(p_errstr))GetProcAddress(m, "prism_error_string");
    p_version = (decltype(p_version))GetProcAddress(m, "prism_version_string");
    if (!(p_init && p_create_best && p_name && p_speak && p_free && p_errstr && p_version)) {
        Log("prism.dll is missing functions - using the old speech route");
        return false;
    }
    g_prism = p_init(nullptr);
    if (!g_prism) { Log("prism_init failed - using the old speech route"); return false; }
    Log(std::string("Prism ") + p_version() + " loaded");
    return true;
}

static void PrismCreate() {
    if (g_backend) { p_free(g_backend); g_backend = nullptr; }
    g_lastCreate = GetTickCount();
    g_backend = p_create_best(g_prism);
    std::string name = g_backend ? p_name(g_backend) : "(none)";
    if (name != g_backendName) Log("Prism speech: " + name);
    g_backendName = name;
}

// True when Prism found no screen reader, only a plain Windows voice.
static bool PrismOnPlainVoice() {
    return g_backendName == "(none)" || g_backendName.find("OneCore") != std::string::npos
        || g_backendName.find("SAPI") != std::string::npos || g_backendName.find("UIA") != std::string::npos
        || g_backendName.find("Automation") != std::string::npos;
}

static void Speak(const std::string& utf8, bool interrupt) {
    if (!g_prism) { OldSpeak(utf8, interrupt); return; }
    // A screen reader started after the game: look again every 10 s while on a plain voice.
    if (!g_backend || (PrismOnPlainVoice() && GetTickCount() - g_lastCreate > 10000)) PrismCreate();
    if (!g_backend) { OldSpeak(utf8, interrupt); return; }
    PrismError e = p_speak(g_backend, utf8.c_str(), interrupt);
    if (e == PRISM_OK) { Log(g_backendName + ": " + utf8); return; }
    // The reader may have restarted (Prism keeps a dead connection): reconnect, try once more.
    Log(g_backendName + " ERROR " + p_errstr(e) + ": " + utf8);
    if (e == PRISM_ERROR_INVALID_UTF8) return;
    PrismCreate();
    if (g_backend && p_speak(g_backend, utf8.c_str(), interrupt) == PRISM_OK) { Log(g_backendName + " (retry): " + utf8); return; }
    OldSpeak(utf8, interrupt);
}

// ---------------- file channel ----------------

struct Message { long long id; bool interrupt; std::string text; };

static bool ReadChannel(std::string& session, std::vector<Message>& msgs) {
    std::ifstream f(g_speechFile, std::ios::binary);
    if (!f) return false;
    std::stringstream ss; ss << f.rdbuf();
    std::string all = ss.str();
    // Only trust a complete file (Lua may be mid-write).
    if (all.size() < 4 || all.find("\nEND") == std::string::npos) return false;
    std::istringstream in(all);
    std::string line;
    if (!std::getline(in, line)) return false;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.rfind("session ", 0) != 0) return false;
    session = line.substr(8);
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line == "END") break;
        size_t a = line.find('\t');
        size_t b = (a == std::string::npos) ? a : line.find('\t', a + 1);
        if (b == std::string::npos) continue;
        Message m;
        m.id = _atoi64(line.substr(0, a).c_str());
        m.interrupt = line.substr(a + 1, b - a - 1) == "1";
        m.text = line.substr(b + 1);
        msgs.push_back(m);
    }
    return true;
}

static FILETIME FileTimeOf(const std::wstring& path, bool& exists) {
    WIN32_FILE_ATTRIBUTE_DATA d;
    exists = GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &d) != 0;
    if (!exists) return FILETIME{};
    return d.ftLastWriteTime;
}

// Diagnostic (10/12): the game window lost focus twice right after a dynamite
// warning. Log which window takes the foreground whenever it changes.
static std::string WindowInfo(HWND w) {
    if (!w) return "(none)";
    wchar_t title[256] = L""; GetWindowTextW(w, title, 256);
    DWORD pid = 0; GetWindowThreadProcessId(w, &pid);
    wchar_t exe[MAX_PATH] = L"?";
    HANDLE ph = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (ph) { DWORD n = MAX_PATH; QueryFullProcessImageNameW(ph, 0, exe, &n); CloseHandle(ph); }
    std::wstring e = exe; e = e.substr(e.find_last_of(L"\\/") + 1);
    char buf[700];
    sprintf_s(buf, "%ls [%ls pid %lu]", title, e.c_str(), pid);
    return buf;
}

static DWORD WINAPI Worker(LPVOID) {
    Log("REAccessSpeech worker started");
    if (PrismLoad()) PrismCreate();

    std::string lastSession;
    long long lastId = 0;
    FILETIME lastTime{};

    // A file left over from an earlier game run must not be re-spoken.
    {
        bool exists;
        FILETIME ft = FileTimeOf(g_speechFile, exists);
        std::string s; std::vector<Message> msgs;
        if (exists && ReadChannel(s, msgs)) {
            lastSession = s;
            for (auto& m : msgs) if (m.id > lastId) lastId = m.id;
            lastTime = ft;
            Log("Old speech file skipped (session " + s + ")");
        }
    }

    HWND lastFg = nullptr;
    for (;;) {
        Sleep(25);
        HWND fg = GetForegroundWindow();
        if (fg != lastFg) {
            DWORD pid = 0; GetWindowThreadProcessId(fg, &pid);
            Log(std::string(pid == GetCurrentProcessId() ? "FOCUS game: " : "FOCUS LOST to: ") + WindowInfo(fg));
            lastFg = fg;
        }
        bool exists;
        FILETIME ft = FileTimeOf(g_speechFile, exists);
        if (!exists || CompareFileTime(&ft, &lastTime) == 0) continue;

        std::string session; std::vector<Message> msgs;
        if (!ReadChannel(session, msgs)) continue;   // incomplete; retry next poll
        lastTime = ft;
        if (session != lastSession) { lastSession = session; lastId = 0; }
        for (auto& m : msgs) {
            if (m.id <= lastId) continue;
            lastId = m.id;
            // "#sound <name>": play reframework\data\REAccess_<name>.wav (warning cues).
            if (m.text.rfind("#sound ", 0) == 0) {
                std::wstring wav = g_gameDir + L"\\reframework\\data\\REAccess_" + Utf8ToWide(m.text.substr(7)) + L".wav";
                BOOL ok = PlaySoundW(wav.c_str(), nullptr, SND_FILENAME | SND_ASYNC | SND_NODEFAULT);
                Log(std::string(ok ? "SOUND: " : "SOUND FAILED: ") + m.text.substr(7));
                continue;
            }
            Speak(m.text, m.interrupt);
        }
    }
    return 0;
}

static void Start() {
    if (g_started.exchange(true)) return;
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    g_gameDir = exe;
    g_gameDir = g_gameDir.substr(0, g_gameDir.find_last_of(L"\\/"));
    g_speechFile = g_gameDir + L"\\reframework\\data\\REAccess_speech.txt";
    g_logFile = g_gameDir + L"\\REAccess_speech_log.txt";
    CreateDirectoryW((g_gameDir + L"\\reframework\\data").c_str(), nullptr);
    // keep the previous run's log (10/12: an earlier fight's log was lost on restart)
    MoveFileExW(g_logFile.c_str(), (g_gameDir + L"\\REAccess_speech_log_prev.txt").c_str(), MOVEFILE_REPLACE_EXISTING);
    { std::ofstream f(g_logFile, std::ios::trunc); }
    Log("REAccessSpeech 0.4.0 loaded");
    HANDLE h = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr);
    if (h) CloseHandle(h);
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const void*) {
    Start();
    return true;
}

BOOL APIENTRY DllMain(HMODULE mod, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(mod);
    return TRUE;
}
