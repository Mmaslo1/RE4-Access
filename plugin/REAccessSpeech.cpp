// REAccessSpeech - REFramework plugin that speaks text through the player's screen reader.
// 0.5.0 (2026-11-25): update check - asks GitHub for a newer RE4 Access, downloads it
// on Shift+F1 and installs it after the game closes (see "updater" below).
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
#include <winhttp.h>
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

// ---------------- updater (0.5.0) ----------------
// On game start: ask GitHub for the newest RE4 Access release. The Lua side
// (RE4Access\update.lua) reads reframework\data\REAccess_update.txt:
//   checking | off | error\t<have> | current\t<have> | available\t<new>\t<have>
//   downloading\t<new> | failed\t<new> | ready\t<new>
// Nothing is downloaded until the player presses Shift+F1 (Lua writes
// REAccess_update_go.txt). The installer runs after the game closes.
// No update check at all: create reframework\data\REAccess_update_off.txt.
static const wchar_t* kReleaseApi = L"https://api.github.com/repos/Mmaslo1/RE4-Access/releases/latest";
static std::wstring g_dataDir;

static void WriteStatus(const std::string& s) {
    std::wstring path = g_dataDir + L"\\REAccess_update.txt";
    std::wstring tmp = path + L".tmp";
    { std::ofstream f(tmp, std::ios::binary | std::ios::trunc); f << s << "\n"; }
    MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
    Log("Update status: " + s);
}

// GET url; the body goes to `body` or, when saveTo is given, into that file.
static bool HttpGet(const std::wstring& url, std::string* body, const std::wstring& saveTo, std::string& err) {
    URL_COMPONENTS uc{}; uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = L"", path[2048] = L"";
    uc.lpszHostName = host; uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path; uc.dwUrlPathLength = 2048;
    wchar_t extra[2048] = L""; uc.lpszExtraInfo = extra; uc.dwExtraInfoLength = 2048;
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) { err = "bad url"; return false; }
    std::wstring full = std::wstring(path) + extra;
    HINTERNET s = WinHttpOpen(L"RE4Access-updater", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nullptr, nullptr, 0);
    if (!s) s = WinHttpOpen(L"RE4Access-updater", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nullptr, nullptr, 0);
    if (!s) { err = "WinHttpOpen failed"; return false; }
    WinHttpSetTimeouts(s, 15000, 15000, 20000, 60000);
    bool ok = false;
    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    HINTERNET r = nullptr;
    if (c) {
        r = WinHttpOpenRequest(c, L"GET", full.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                               uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
    }
    if (r && WinHttpSendRequest(r, L"Accept: application/vnd.github+json\r\n", (DWORD)-1, nullptr, 0, 0, 0)
          && WinHttpReceiveResponse(r, nullptr)) {
        DWORD code = 0, sz = sizeof(code);
        WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &code, &sz, nullptr);
        if (code != 200) err = "HTTP " + std::to_string(code);
        else {
            std::ofstream file;
            if (!saveTo.empty()) file.open(saveTo, std::ios::binary | std::ios::trunc);
            ok = saveTo.empty() || file.is_open();
            if (!ok) err = "cannot write file";
            for (DWORD avail = 0; ok && WinHttpQueryDataAvailable(r, &avail) && avail > 0; ) {
                std::string buf(avail, '\0'); DWORD got = 0;
                if (!WinHttpReadData(r, &buf[0], avail, &got)) { ok = false; err = "read failed"; break; }
                buf.resize(got);
                if (file.is_open()) file << buf; else if (body) *body += buf;
            }
        }
    } else if (err.empty()) err = "no connection (error " + std::to_string(GetLastError()) + ")";
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return ok;
}

// Value of "key": "value" (first match) in a JSON text. Enough for GitHub's release reply.
static std::string JsonString(const std::string& json, const std::string& key, size_t from = 0) {
    size_t k = json.find("\"" + key + "\"", from);
    if (k == std::string::npos) return "";
    size_t q1 = json.find('"', json.find(':', k) + 1);
    size_t q2 = json.find('"', q1 + 1);
    return (q1 == std::string::npos || q2 == std::string::npos) ? "" : json.substr(q1 + 1, q2 - q1 - 1);
}

static std::vector<int> VersionParts(std::string v) {
    if (!v.empty() && (v[0] == 'v' || v[0] == 'V')) v = v.substr(1);
    std::vector<int> p; std::stringstream ss(v); std::string x;
    while (std::getline(ss, x, '.')) p.push_back(atoi(x.c_str()));
    return p;
}
static bool IsNewer(const std::string& a, const std::string& b) {   // a > b ?
    auto pa = VersionParts(a), pb = VersionParts(b);
    for (size_t i = 0; i < pa.size() || i < pb.size(); i++) {
        int x = i < pa.size() ? pa[i] : 0, y = i < pb.size() ? pb[i] : 0;
        if (x != y) return x > y;
    }
    return false;
}

static std::string LocalVersion() {
    std::ifstream f(g_gameDir + L"\\reframework\\autorun\\RE4Access.lua");
    std::string line;
    while (std::getline(f, line)) {
        size_t p = line.find("VERSION = \"");
        if (p != std::string::npos) { p += 11; return line.substr(p, line.find('"', p) - p); }
    }
    return "";
}

static std::string Narrow(const std::wstring& w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
    return s;
}

// A hidden PowerShell waits for the game to close, then runs the installer
// silently (Windows asks for permission once) and speaks the result.
static bool StartInstallWhenGameCloses(const std::wstring& setup, const std::string& ver) {
    auto q = [](std::wstring s) { std::wstring o; for (wchar_t ch : s) { o += ch; if (ch == L'\'') o += L'\''; } return o; };
    std::wstring dir = setup.substr(0, setup.find_last_of(L"\\"));
    std::wstring ps1 = dir + L"\\install_when_game_closes.ps1";
    std::wstring wver = Utf8ToWide(ver);
    std::wstring script =
        L"$ErrorActionPreference = 'SilentlyContinue'\r\n"
        L"Wait-Process -Id " + std::to_wstring(GetCurrentProcessId()) + L"\r\n"
        L"Start-Sleep -Seconds 3\r\n"
        L"Add-Type -AssemblyName System.Speech\r\n"
        L"$v = New-Object System.Speech.Synthesis.SpeechSynthesizer\r\n"
        L"$v.Speak('Installing the RE4 Access update, version " + wver + L". Windows will ask for permission. Press Alt plus Y.')\r\n"
        L"$p = Start-Process -FilePath '" + q(setup) + L"' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/DIR=\"" + q(g_gameDir) + L"\"' -Verb RunAs -Wait -PassThru\r\n"
        L"if ($p -and $p.ExitCode -eq 0) { $v.Speak('RE4 Access update installed. Start the game when you are ready.') }\r\n"
        L"else { $v.Speak('The RE4 Access update was not installed. You can install it later from the RE4 Access page on GitHub.') }\r\n";
    {
        std::ofstream f(ps1, std::ios::binary | std::ios::trunc);
        f << "\xEF\xBB\xBF" << Narrow(script);   // BOM so Windows PowerShell reads UTF-8
    }
    std::wstring cmd = L"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + L"\"";
    STARTUPINFOW si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    DWORD flags = CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB;
    BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, flags, nullptr, dir.c_str(), &si, &pi);
    if (!ok) ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, dir.c_str(), &si, &pi);
    if (ok) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); Log("Installer waits for the game to close"); }
    else Log("Could not start the install helper, error " + std::to_string(GetLastError()));
    return ok != FALSE;
}

static DWORD WINAPI UpdateWorker(LPVOID) {
    std::wstring goFile = g_dataDir + L"\\REAccess_update_go.txt";
    DeleteFileW(goFile.c_str());
    if (GetFileAttributesW((g_dataDir + L"\\REAccess_update_off.txt").c_str()) != INVALID_FILE_ATTRIBUTES) {
        WriteStatus("off"); return 0;
    }
    WriteStatus("checking");
    Sleep(3000);
    std::string have = LocalVersion();
    std::string json, err;
    if (!HttpGet(kReleaseApi, &json, L"", err)) { Log("Update check failed: " + err); WriteStatus("error\t" + have); return 0; }
    std::string tag = JsonString(json, "tag_name");
    std::string ver = (!tag.empty() && (tag[0] == 'v' || tag[0] == 'V')) ? tag.substr(1) : tag;
    std::string url;
    for (size_t p = 0; (p = json.find("\"browser_download_url\"", p)) != std::string::npos; p++) {
        std::string u = JsonString(json, "browser_download_url", p);
        if (u.find("RE4Access_Setup_") != std::string::npos && u.size() > 4 && u.substr(u.size() - 4) == ".exe") { url = u; break; }
    }
    Log("Newest release " + ver + ", installed " + have + (url.empty() ? ", no installer in it" : ""));
    if (ver.empty() || url.empty() || have.empty() || !IsNewer(ver, have)) { WriteStatus("current\t" + have); return 0; }
    WriteStatus("available\t" + ver + "\t" + have);

    for (;;) {
        Sleep(500);
        if (GetFileAttributesW(goFile.c_str()) == INVALID_FILE_ATTRIBUTES) continue;
        DeleteFileW(goFile.c_str());
        WriteStatus("downloading\t" + ver);
        wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);
        std::wstring dir = std::wstring(tmp) + L"RE4Access_update";
        CreateDirectoryW(dir.c_str(), nullptr);
        std::wstring setup = dir + L"\\RE4Access_Setup_" + Utf8ToWide(ver) + L".exe";
        err.clear();
        bool ok = HttpGet(Utf8ToWide(url), nullptr, setup, err);
        if (ok) {   // must be a real program of sensible size
            std::ifstream f(setup, std::ios::binary | std::ios::ate);
            long long size = f ? (long long)f.tellg() : 0;
            char mz[2] = {}; f.seekg(0); f.read(mz, 2);
            if (size < 500000 || mz[0] != 'M' || mz[1] != 'Z') { ok = false; err = "download incomplete (" + std::to_string(size) + " bytes)"; }
        }
        if (!ok) { Log("Update download failed: " + err); WriteStatus("failed\t" + ver); continue; }
        Log("Update downloaded: " + Narrow(setup));
        if (!StartInstallWhenGameCloses(setup, ver)) { WriteStatus("failed\t" + ver); continue; }
        WriteStatus("ready\t" + ver);
        return 0;
    }
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
    Log("REAccessSpeech 0.5.0 loaded");
    g_dataDir = g_gameDir + L"\\reframework\\data";
    HANDLE h = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr);
    if (h) CloseHandle(h);
    h = CreateThread(nullptr, 0, UpdateWorker, nullptr, 0, nullptr);
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
