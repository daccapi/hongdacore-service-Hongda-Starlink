#include <winsock2.h>

#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <shellapi.h>
#include <wininet.h>
#include <windows.h>
#include <windowsx.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayCallbackMessage = WM_APP + 0x41;
constexpr UINT kTrayOpenCommand = 0x7101;
constexpr UINT kTrayExitCommand = 0x7102;
constexpr wchar_t kInternetSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kProxyRecoveryKey[] =
    L"Software\\HongdaStarlink\\ProxyRecovery";
constexpr wchar_t kTunProxyRecoveryKey[] =
    L"Software\\HongdaStarlink\\TunProxyRecovery";

bool g_proxy_managed = false;
bool g_proxy_previous_enabled = false;
std::wstring g_proxy_previous_server;
std::wstring g_proxy_previous_bypass;
std::wstring g_proxy_managed_server;

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) return std::wstring();
  int count = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (count <= 0) return std::wstring();
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), count);
  if (!result.empty() && result.back() == L'\0') result.pop_back();
  return result;
}

std::string Utf8FromUtf16String(const std::wstring& value) {
  if (value.empty()) return std::string();
  int count = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0,
                                  nullptr, nullptr);
  if (count <= 0) return std::string();
  std::string result(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), count,
                      nullptr, nullptr);
  if (!result.empty() && result.back() == '\0') result.pop_back();
  return result;
}

bool IsAdministrator() {
  BOOL is_member = FALSE;
  SID_IDENTIFIER_AUTHORITY nt_authority = SECURITY_NT_AUTHORITY;
  PSID admin_group = nullptr;
  if (AllocateAndInitializeSid(&nt_authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                               DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                               &admin_group)) {
    CheckTokenMembership(nullptr, admin_group, &is_member);
    FreeSid(admin_group);
  }
  return is_member == TRUE;
}

bool AnyBestRouteUsesInterface(const std::vector<IPAddr>& probes,
                               ULONG interface_index) {
  for (const auto probe : probes) {
    DWORD best_if_index = 0;
    if (GetBestInterface(probe, &best_if_index) == NO_ERROR &&
        best_if_index == interface_index) {
      return true;
    }
  }
  return false;
}

flutter::EncodableMap InspectTunRouting() {
  flutter::EncodableMap result;
  bool adapter_found = false;
  bool adapter_up = false;
  bool default_route = false;
  bool low_half_route = false;
  bool high_half_route = false;
  bool effective_route = false;
  int split_route_count = 0;
  ULONG tun_if_index = 0;

  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer(size);
  auto* addresses =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG status = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX,
                                      nullptr, addresses, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, nullptr,
                                  addresses, &size);
  }
  if (status == NO_ERROR) {
    for (auto* item = addresses; item != nullptr; item = item->Next) {
      if (item->FriendlyName == nullptr) continue;
      if (_wcsicmp(item->FriendlyName, L"HongdaTun") != 0) continue;
      adapter_found = true;
      adapter_up = item->OperStatus == IfOperStatusUp;
      tun_if_index = item->IfIndex;
      break;
    }
  }

  if (adapter_found) {
    ULONG route_size = sizeof(MIB_IPFORWARDTABLE);
    std::vector<unsigned char> route_buffer(route_size);
    auto* table =
        reinterpret_cast<MIB_IPFORWARDTABLE*>(route_buffer.data());
    DWORD route_status = GetIpForwardTable(table, &route_size, FALSE);
    if (route_status == ERROR_INSUFFICIENT_BUFFER) {
      route_buffer.resize(route_size);
      table = reinterpret_cast<MIB_IPFORWARDTABLE*>(route_buffer.data());
      route_status = GetIpForwardTable(table, &route_size, FALSE);
    }
    if (route_status == NO_ERROR) {
      for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        const auto& row = table->table[i];
        if (row.dwForwardIfIndex != tun_if_index) continue;
        if (row.dwForwardDest == 0 && row.dwForwardMask == 0) {
          default_route = true;
        }
        if (ntohl(row.dwForwardMask) == 0x80000000UL) {
          ++split_route_count;
        }
      }
    }
    // HongdaCore excludes proxy server /32 addresses from TUN auto-route so
    // the outbound connection stays on the physical adapter.  Windows then
    // decomposes each configured /1 into smaller prefixes.  Checking for two
    // literal /1 rows therefore produces a false negative even though the TUN
    // owns the complete public IPv4 space.  Probe both halves of 0/0 instead.
    // Values are converted to the network byte order required by
    // GetBestInterface.
    const std::vector<IPAddr> low_half_probes = {
        htonl(0x01010101UL),  // 1.1.1.1
        htonl(0x08080808UL),  // 8.8.8.8
    };
    const std::vector<IPAddr> high_half_probes = {
        htonl(0x81060F1CUL),  // 129.6.15.28
        htonl(0xD043DEDEUL),  // 208.67.222.222
    };
    low_half_route =
        AnyBestRouteUsesInterface(low_half_probes, tun_if_index);
    high_half_route =
        AnyBestRouteUsesInterface(high_half_probes, tun_if_index);
    effective_route = low_half_route && high_half_route;
  }

  const bool route_ready =
      default_route || split_route_count >= 2 || effective_route;
  result[flutter::EncodableValue("adapterFound")] =
      flutter::EncodableValue(adapter_found);
  result[flutter::EncodableValue("adapterUp")] =
      flutter::EncodableValue(adapter_up);
  result[flutter::EncodableValue("defaultRoute")] =
      flutter::EncodableValue(default_route);
  result[flutter::EncodableValue("splitRouteCount")] =
      flutter::EncodableValue(split_route_count);
  result[flutter::EncodableValue("lowHalfRoute")] =
      flutter::EncodableValue(low_half_route);
  result[flutter::EncodableValue("highHalfRoute")] =
      flutter::EncodableValue(high_half_route);
  result[flutter::EncodableValue("effectiveRoute")] =
      flutter::EncodableValue(effective_route);
  result[flutter::EncodableValue("ready")] =
      flutter::EncodableValue(adapter_found && adapter_up && route_ready &&
                              effective_route);
  return result;
}

bool SetStringValue(HKEY key, const wchar_t* name, const std::wstring& value) {
  const BYTE* data = reinterpret_cast<const BYTE*>(value.c_str());
  const DWORD bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, name, 0, REG_SZ, data, bytes) == ERROR_SUCCESS;
}

std::wstring ReadStringValue(HKEY key, const wchar_t* name) {
  DWORD type = 0;
  DWORD bytes = 0;
  if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes) !=
          ERROR_SUCCESS ||
      type != REG_SZ || bytes == 0) {
    return std::wstring();
  }
  std::wstring result(bytes / sizeof(wchar_t), L'\0');
  if (RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<LPBYTE>(result.data()), &bytes) !=
      ERROR_SUCCESS) {
    return std::wstring();
  }
  while (!result.empty() && result.back() == L'\0') result.pop_back();
  return result;
}


bool SetDwordValue(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
                        reinterpret_cast<const BYTE*>(&value),
                        sizeof(value)) == ERROR_SUCCESS;
}

bool ReadDwordValue(HKEY key, const wchar_t* name, DWORD* value) {
  if (!value) return false;
  DWORD type = 0;
  DWORD bytes = sizeof(*value);
  return RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<LPBYTE>(value), &bytes) ==
             ERROR_SUCCESS &&
         type == REG_DWORD;
}

bool SaveProxyRecovery(bool previous_enabled,
                       const std::wstring& previous_server,
                       const std::wstring& previous_bypass,
                       const std::wstring& managed_server) {
  HKEY key = nullptr;
  DWORD disposition = 0;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kProxyRecoveryKey, 0, nullptr, 0,
                      KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &key,
                      &disposition) != ERROR_SUCCESS) {
    return false;
  }
  bool ok = SetDwordValue(key, L"Managed", 1) &&
            SetDwordValue(key, L"PreviousEnabled", previous_enabled ? 1 : 0) &&
            SetStringValue(key, L"PreviousServer", previous_server) &&
            SetStringValue(key, L"PreviousBypass", previous_bypass) &&
            SetStringValue(key, L"ManagedServer", managed_server);
  RegCloseKey(key);
  return ok;
}

bool LoadProxyRecovery(bool* previous_enabled,
                       std::wstring* previous_server,
                       std::wstring* previous_bypass,
                       std::wstring* managed_server) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kProxyRecoveryKey, 0, KEY_QUERY_VALUE,
                    &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD managed = 0;
  DWORD enabled = 0;
  const bool ok = ReadDwordValue(key, L"Managed", &managed) && managed == 1 &&
                  ReadDwordValue(key, L"PreviousEnabled", &enabled);
  if (ok) {
    if (previous_enabled) *previous_enabled = enabled != 0;
    if (previous_server) *previous_server = ReadStringValue(key, L"PreviousServer");
    if (previous_bypass) *previous_bypass = ReadStringValue(key, L"PreviousBypass");
    if (managed_server) *managed_server = ReadStringValue(key, L"ManagedServer");
  }
  RegCloseKey(key);
  return ok;
}

void ClearProxyRecovery() {
  RegDeleteTreeW(HKEY_CURRENT_USER, kProxyRecoveryKey);
}

bool SaveTunProxyRecovery(bool previous_enabled,
                          const std::wstring& previous_server,
                          const std::wstring& previous_bypass) {
  HKEY key = nullptr;
  DWORD disposition = 0;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kTunProxyRecoveryKey, 0, nullptr, 0,
                      KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &key,
                      &disposition) != ERROR_SUCCESS) {
    return false;
  }
  const bool ok =
      SetDwordValue(key, L"PreviousEnabled", previous_enabled ? 1 : 0) &&
      SetStringValue(key, L"PreviousServer", previous_server) &&
      SetStringValue(key, L"PreviousBypass", previous_bypass);
  RegCloseKey(key);
  return ok;
}

bool LoadTunProxyRecovery(bool* previous_enabled,
                          std::wstring* previous_server,
                          std::wstring* previous_bypass) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kTunProxyRecoveryKey, 0,
                    KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD enabled = 0;
  const bool ok = ReadDwordValue(key, L"PreviousEnabled", &enabled);
  if (ok) {
    if (previous_enabled) *previous_enabled = enabled != 0;
    if (previous_server)
      *previous_server = ReadStringValue(key, L"PreviousServer");
    if (previous_bypass)
      *previous_bypass = ReadStringValue(key, L"PreviousBypass");
  }
  RegCloseKey(key);
  return ok;
}

void ClearTunProxyRecovery() {
  RegDeleteTreeW(HKEY_CURRENT_USER, kTunProxyRecoveryKey);
}

bool SuspendSystemProxyForTun(bool suspend) {
  bool previous_enabled = false;
  std::wstring previous_server;
  std::wstring previous_bypass;
  const bool has_recovery = LoadTunProxyRecovery(
      &previous_enabled, &previous_server, &previous_bypass);
  if (suspend && has_recovery) return true;

  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD current_enabled = 0;
  DWORD bytes = sizeof(current_enabled);
  RegQueryValueExW(key, L"ProxyEnable", nullptr, nullptr,
                   reinterpret_cast<LPBYTE>(&current_enabled), &bytes);
  bool ok = true;
  if (suspend) {
    if (current_enabled != 0) {
      previous_server = ReadStringValue(key, L"ProxyServer");
      previous_bypass = ReadStringValue(key, L"ProxyOverride");
      ok = SaveTunProxyRecovery(true, previous_server, previous_bypass);
      if (ok) {
        const DWORD disabled = 0;
        ok = RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD,
                            reinterpret_cast<const BYTE*>(&disabled),
                            sizeof(disabled)) == ERROR_SUCCESS;
      }
    }
  } else if (has_recovery) {
    // Preserve a proxy the user deliberately enabled while TUN was running.
    if (current_enabled == 0) {
      const DWORD restored = previous_enabled ? 1 : 0;
      ok = RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD,
                          reinterpret_cast<const BYTE*>(&restored),
                          sizeof(restored)) == ERROR_SUCCESS;
      if (ok) ok = SetStringValue(key, L"ProxyServer", previous_server);
      if (ok) ok = SetStringValue(key, L"ProxyOverride", previous_bypass);
    }
    ClearTunProxyRecovery();
  }
  RegCloseKey(key);

  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return ok;
}

bool SetSystemProxy(bool enabled, const std::wstring& server,
                    const std::wstring& bypass) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }

  if (enabled && !g_proxy_managed) {
    DWORD previous = 0;
    DWORD bytes = sizeof(previous);
    if (RegQueryValueExW(key, L"ProxyEnable", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(&previous), &bytes) ==
        ERROR_SUCCESS) {
      g_proxy_previous_enabled = previous != 0;
    } else {
      g_proxy_previous_enabled = false;
    }
    g_proxy_previous_server = ReadStringValue(key, L"ProxyServer");
    g_proxy_previous_bypass = ReadStringValue(key, L"ProxyOverride");
    if (!SaveProxyRecovery(g_proxy_previous_enabled, g_proxy_previous_server,
                           g_proxy_previous_bypass, server)) {
      RegCloseKey(key);
      return false;
    }
    g_proxy_managed_server = server;
    g_proxy_managed = true;
  }

  // A previous process may have crashed after enabling Hongda's proxy. Recover
  // the persisted snapshot only when the current proxy still points at the
  // exact server Hongda recorded, so a later manual/user proxy is never
  // overwritten accidentally.
  if (!enabled && !g_proxy_managed) {
    bool previous_enabled = false;
    std::wstring previous_server;
    std::wstring previous_bypass;
    std::wstring managed_server;
    if (LoadProxyRecovery(&previous_enabled, &previous_server, &previous_bypass,
                          &managed_server)) {
      DWORD current_enabled = 0;
      DWORD bytes = sizeof(current_enabled);
      RegQueryValueExW(key, L"ProxyEnable", nullptr, nullptr,
                       reinterpret_cast<LPBYTE>(&current_enabled), &bytes);
      const std::wstring current_server = ReadStringValue(key, L"ProxyServer");
      if (current_enabled != 0 && !managed_server.empty() &&
          current_server == managed_server) {
        g_proxy_previous_enabled = previous_enabled;
        g_proxy_previous_server = previous_server;
        g_proxy_previous_bypass = previous_bypass;
        g_proxy_managed_server = managed_server;
        g_proxy_managed = true;
      } else {
        ClearProxyRecovery();
        RegCloseKey(key);
        return true;
      }
    } else {
      RegCloseKey(key);
      return true;
    }
  }

  DWORD flag = enabled ? 1 : (g_proxy_previous_enabled ? 1 : 0);
  bool ok = RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD,
                           reinterpret_cast<const BYTE*>(&flag),
                           sizeof(flag)) == ERROR_SUCCESS;

  if (enabled) {
    if (ok && !server.empty()) ok = SetStringValue(key, L"ProxyServer", server);
    if (ok && !bypass.empty()) ok = SetStringValue(key, L"ProxyOverride", bypass);
  } else {
    // Preserve a proxy the user deliberately changed while Hongda was
    // managing it. The stale-recovery path above already checks the same
    // condition; apply the same guard to the in-process disable path.
    const std::wstring current_server = ReadStringValue(key, L"ProxyServer");
    if (g_proxy_managed && !g_proxy_managed_server.empty() &&
        current_server != g_proxy_managed_server) {
      ClearProxyRecovery();
      g_proxy_managed = false;
      g_proxy_managed_server.clear();
      g_proxy_previous_enabled = false;
      g_proxy_previous_server.clear();
      g_proxy_previous_bypass.clear();
      RegCloseKey(key);
      InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
      InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
      return true;
    }
    if (ok) ok = SetStringValue(key, L"ProxyServer", g_proxy_previous_server);
    if (ok) ok = SetStringValue(key, L"ProxyOverride", g_proxy_previous_bypass);
    if (ok) ClearProxyRecovery();
    g_proxy_managed = false;
    g_proxy_managed_server.clear();
    g_proxy_previous_enabled = false;
    g_proxy_previous_server.clear();
    g_proxy_previous_bypass.clear();
  }
  RegCloseKey(key);

  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return ok;
}

void RecoverStaleSystemProxy() {
  if (g_proxy_managed) return;
  bool previous_enabled = false;
  std::wstring previous_server;
  std::wstring previous_bypass;
  std::wstring managed_server;
  if (!LoadProxyRecovery(&previous_enabled, &previous_server, &previous_bypass,
                         &managed_server)) {
    return;
  }

  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0, KEY_QUERY_VALUE,
                    &key) != ERROR_SUCCESS) {
    return;
  }
  DWORD current_enabled = 0;
  DWORD bytes = sizeof(current_enabled);
  RegQueryValueExW(key, L"ProxyEnable", nullptr, nullptr,
                   reinterpret_cast<LPBYTE>(&current_enabled), &bytes);
  const std::wstring current_server = ReadStringValue(key, L"ProxyServer");
  RegCloseKey(key);

  if (current_enabled != 0 && !managed_server.empty() &&
      current_server == managed_server) {
    g_proxy_previous_enabled = previous_enabled;
    g_proxy_previous_server = previous_server;
    g_proxy_previous_bypass = previous_bypass;
    g_proxy_managed = true;
    SetSystemProxy(false, L"", L"");
  } else {
    ClearProxyRecovery();
  }
}

flutter::EncodableMap GetSystemProxy() {
  flutter::EncodableMap result;
  HKEY key = nullptr;
  DWORD enabled = 0;
  DWORD bytes = sizeof(enabled);
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0, KEY_QUERY_VALUE,
                    &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"ProxyEnable", nullptr, nullptr,
                     reinterpret_cast<LPBYTE>(&enabled), &bytes);
    const std::wstring server = ReadStringValue(key, L"ProxyServer");
    const std::wstring bypass = ReadStringValue(key, L"ProxyOverride");
    result[flutter::EncodableValue("enabled")] =
        flutter::EncodableValue(enabled != 0);
    result[flutter::EncodableValue("server")] =
        flutter::EncodableValue(Utf8FromUtf16String(server));
    result[flutter::EncodableValue("bypass")] =
        flutter::EncodableValue(Utf8FromUtf16String(bypass));
    RegCloseKey(key);
  } else {
    result[flutter::EncodableValue("enabled")] = flutter::EncodableValue(false);
    result[flutter::EncodableValue("server")] = flutter::EncodableValue("");
    result[flutter::EncodableValue("bypass")] = flutter::EncodableValue("");
  }
  return result;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  RecoverStaleSystemProxy();
  SuspendSystemProxyForTun(false);

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }

  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "hongda_starlink/windows",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "isAdministrator") {
          result->Success(flutter::EncodableValue(IsAdministrator()));
          return;
        }

        if (call.method_name() == "inspectTunRouting") {
          result->Success(flutter::EncodableValue(InspectTunRouting()));
          return;
        }

        if (call.method_name() == "restartAsAdministrator") {
          wchar_t exe_path[MAX_PATH]{};
          GetModuleFileNameW(nullptr, exe_path, MAX_PATH);

          std::wstring exe_dir(exe_path);
          const auto slash = exe_dir.find_last_of(L"\\/");
          if (slash != std::wstring::npos) exe_dir.resize(slash);

          SHELLEXECUTEINFOW launch{};
          launch.cbSize = sizeof(launch);
          launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
          launch.hwnd = GetHandle();
          launch.lpVerb = L"runas";
          launch.lpFile = exe_path;
          launch.lpParameters = L"--elevated-relaunch --resume-connect";
          launch.lpDirectory = exe_dir.empty() ? nullptr : exe_dir.c_str();
          launch.nShow = SW_SHOWNORMAL;

          const bool success = ShellExecuteExW(&launch) == TRUE;
          // The elevated child waits for the singleton mutex in main.cpp.
          // Close the standard-rights UI immediately so the child can acquire it
          // without an artificial WaitForInputIdle timeout.
          if (launch.hProcess) CloseHandle(launch.hProcess);
          result->Success(flutter::EncodableValue(success));
          if (success) {
            // WM_CLOSE normally hides to tray. An elevation hand-off must really
            // terminate the standard-rights process so the elevated singleton
            // can take ownership and resume the requested connection.
            force_close_ = true;
            PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
          }
          return;
        }

        if (call.method_name() == "setSystemProxy") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "Expected map arguments");
            return;
          }
          bool enabled = false;
          std::string server;
          std::string bypass;
          auto enabled_it = args->find(flutter::EncodableValue("enabled"));
          if (enabled_it != args->end()) {
            if (const auto* value = std::get_if<bool>(&enabled_it->second))
              enabled = *value;
          }
          auto server_it = args->find(flutter::EncodableValue("server"));
          if (server_it != args->end()) {
            if (const auto* value = std::get_if<std::string>(&server_it->second))
              server = *value;
          }
          auto bypass_it = args->find(flutter::EncodableValue("bypass"));
          if (bypass_it != args->end()) {
            if (const auto* value = std::get_if<std::string>(&bypass_it->second))
              bypass = *value;
          }
          const bool ok = SetSystemProxy(enabled, Utf16FromUtf8(server),
                                         Utf16FromUtf8(bypass));
          if (ok)
            result->Success(flutter::EncodableValue(true));
          else
            result->Error("proxy_failed", "Failed to update Windows proxy");
          return;
        }

        if (call.method_name() == "getSystemProxy") {
          result->Success(flutter::EncodableValue(GetSystemProxy()));
          return;
        }

        if (call.method_name() == "setTunProxySuspended") {
          bool suspended = false;
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            const auto it =
                args->find(flutter::EncodableValue("suspended"));
            if (it != args->end()) {
              if (const auto* value = std::get_if<bool>(&it->second)) {
                suspended = *value;
              }
            }
          }
          const bool ok = SuspendSystemProxyForTun(suspended);
          if (ok)
            result->Success(flutter::EncodableValue(true));
          else
            result->Error("proxy_failed",
                          "Failed to suspend Windows proxy for TUN");
          return;
        }

        if (call.method_name() == "isWindowMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(GetHandle()) == TRUE));
          return;
        }

        if (call.method_name() == "startWindowDrag") {
          // Let Windows own the move loop. This gives native snapping, multi-monitor
          // behavior and avoids reserving a visible caption strip in Flutter.
          ReleaseCapture();
          SendMessageW(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "windowAction") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "Expected map arguments");
            return;
          }
          std::string action;
          auto it = args->find(flutter::EncodableValue("action"));
          if (it != args->end()) {
            if (const auto* value = std::get_if<std::string>(&it->second)) action = *value;
          }
          if (action == "minimize") {
            ShowWindow(GetHandle(), SW_MINIMIZE);
          } else if (action == "toggleMaximize") {
            ShowWindow(GetHandle(), IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
          } else if (action == "close") {
            PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
          } else {
            result->Error("bad_action", "Unknown window action");
            return;
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }

        result->NotImplemented();
      });

  AddTrayIcon();
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::AddTrayIcon() {
  if (tray_added_ || !GetHandle()) return;
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"鸿达星轨智连");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_added_ = false;
}

void FlutterWindow::RestoreFromTray() {
  ShowWindow(GetHandle(), SW_SHOW);
  if (IsIconic(GetHandle())) ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"打开主界面");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"退出鸿达星轨智连");
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                 cursor.x, cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessageW(GetHandle(), WM_NULL, 0, 0);
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  // Restore the user's previous proxy state on a normal window close.
  if (g_proxy_managed) SetSystemProxy(false, L"", L"");
  SuspendSystemProxyForTun(false);
  channel_.reset();
  flutter_controller_.reset();
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
  }

  switch (message) {
    case WM_CLOSE:
      if (!force_close_ && tray_added_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case kTrayCallbackMessage:
      if (LOWORD(lparam) == WM_LBUTTONUP || LOWORD(lparam) == WM_LBUTTONDBLCLK) {
        RestoreFromTray();
        return 0;
      }
      if (LOWORD(lparam) == WM_RBUTTONUP || LOWORD(lparam) == WM_CONTEXTMENU) {
        ShowTrayMenu();
        return 0;
      }
      break;
    case WM_COMMAND:
      if (LOWORD(wparam) == kTrayOpenCommand) {
        RestoreFromTray();
        return 0;
      }
      if (LOWORD(wparam) == kTrayExitCommand) {
        force_close_ = true;
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;
    case WM_NCHITTEST: {
      const bool maximized = IsZoomed(hwnd) == TRUE;
      RECT rect{};
      GetWindowRect(hwnd, &rect);
      const LONG x = GET_X_LPARAM(lparam);
      const LONG y = GET_Y_LPARAM(lparam);
      constexpr LONG edge = 7;
      if (!maximized) {
        const bool left = x >= rect.left && x < rect.left + edge;
        const bool right = x < rect.right && x >= rect.right - edge;
        const bool top = y >= rect.top && y < rect.top + edge;
        const bool bottom = y < rect.bottom && y >= rect.bottom - edge;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
      }

      // Drag regions are explicit Flutter widgets that call startWindowDrag.
      // Do not reserve any visible top caption area here; only native resize
      // edges are handled by WM_NCHITTEST.
      return HTCLIENT;
    }
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = 760;
      info->ptMinTrackSize.y = 520;
      return 0;
    }
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
