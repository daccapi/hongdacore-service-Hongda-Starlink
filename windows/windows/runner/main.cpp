#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>

#include "flutter_window.h"
#include "utils.h"


int APIENTRY wWinMain(_In_ HINSTANCE instance,
                      _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line,
                      _In_ int show_command) {
  const bool elevated_relaunch =
      wcsstr(GetCommandLineW(), L"--elevated-relaunch") != nullptr;
  HANDLE single_instance =
      CreateMutexW(nullptr, TRUE, L"Local\\HongdaStarlink.SingleInstance");
  if (single_instance && GetLastError() == ERROR_ALREADY_EXISTS) {
    if (elevated_relaunch) {
      // The non-elevated process launches this elevated copy before it can
      // finish closing. Wait for that process to release the singleton mutex
      // instead of treating the elevated copy as an unwanted second launch.
      const DWORD wait = WaitForSingleObject(single_instance, 8000);
      if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
        CloseHandle(single_instance);
        return EXIT_FAILURE;
      }
    } else {
      HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW",
                                  L"鸿达星轨智连 V1.6.15");
      if (existing) {
        ShowWindow(existing, SW_RESTORE);
        SetForegroundWindow(existing);
      }
      CloseHandle(single_instance);
      return EXIT_SUCCESS;
    }
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Always resolve Flutter assets and bundled runtime relative to the EXE.
  // This is especially important for a UAC relaunch: ShellExecute can inherit
  // an arbitrary working directory from the non-elevated process.
  wchar_t exe_path[MAX_PATH]{};
  if (GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {
    std::wstring exe_dir(exe_path);
    const auto slash = exe_dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      exe_dir.resize(slash);
      SetCurrentDirectoryW(exe_dir.c_str());
    }
  }

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());

  FlutterWindow window(project);

  // Pick a comfortable window size from the current Windows work area instead
  // of assuming a large monitor. This keeps the client usable in normal
  // windowed mode on 1366x768-class displays while still using more space on
  // larger monitors.
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int work_width = work_area.right - work_area.left;
  const int work_height = work_area.bottom - work_area.top;
  // Open as a large normal window, not maximized. Avoid a fixed pixel cap:
  // on high-DPI / high-resolution screens that cap made the app look much
  // smaller than intended. The dashboard now reflows across wide, medium, and narrow layouts.
  const int max_width_px = std::max(760, work_width - 48);
  const int max_height_px = std::max(560, work_height - 48);
  const int min_width_px = std::min(1040, max_width_px);
  const int min_height_px = std::min(660, max_height_px);
  const int initial_width_px = std::clamp(static_cast<int>(work_width * 0.86), min_width_px, max_width_px);
  const int initial_height_px = std::clamp(static_cast<int>(work_height * 0.86), min_height_px, max_height_px);
  const int origin_x_px = work_area.left + std::max(0, (work_width - initial_width_px) / 2);
  const int origin_y_px = work_area.top + std::max(0, (work_height - initial_height_px) / 2);

  // SPI_GETWORKAREA returns physical coordinates for this DPI-aware process,
  // while Win32Window::Create expects logical coordinates and applies DPI
  // scaling itself. Convert once here to avoid scaling the centered position a
  // second time (which pushed the window down/right on 125%-200% displays).
  const double initial_scale = std::max(1.0, GetDpiForSystem() / 96.0);
  Win32Window::Point origin(
      static_cast<int>(origin_x_px / initial_scale),
      static_cast<int>(origin_y_px / initial_scale));
  Win32Window::Size size(
      static_cast<int>(initial_width_px / initial_scale),
      static_cast<int>(initial_height_px / initial_scale));
  if (!window.Create(L"鸿达星轨智连 V1.6.15", origin, size)) {
    if (single_instance) CloseHandle(single_instance);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.Show();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance) CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
