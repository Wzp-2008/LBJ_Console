#include <windows.h>
#include <shellapi.h>

#include <fstream>
#include <string>
#include <vector>

namespace {

std::wstring PowerShellQuote(const std::wstring& value) {
  std::wstring result = L"'";
  for (const wchar_t character : value) {
    if (character == L'\'') {
      result += L"''";
    } else {
      result += character;
    }
  }
  result += L"'";
  return result;
}

std::wstring CommandLineQuote(const std::wstring& value) {
  return L"\"" + value + L"\"";
}

bool RunPowerShell(const std::wstring& command) {
  std::wstring commandLine =
      L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" +
      command + L"\"";
  std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
  mutableCommand.push_back(L'\0');

  STARTUPINFOW startupInfo{};
  startupInfo.cb = sizeof(startupInfo);
  PROCESS_INFORMATION processInfo{};
  const BOOL created = CreateProcessW(
      nullptr, mutableCommand.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startupInfo, &processInfo);
  if (!created) return false;

  WaitForSingleObject(processInfo.hProcess, INFINITE);
  DWORD exitCode = 1;
  GetExitCodeProcess(processInfo.hProcess, &exitCode);
  CloseHandle(processInfo.hThread);
  CloseHandle(processInfo.hProcess);
  return exitCode == 0;
}

bool StartApplication(const std::wstring& executable,
                      const std::wstring& cleanupDirectory) {
  std::wstring commandLine = CommandLineQuote(executable);
  if (!cleanupDirectory.empty()) {
    commandLine += L" --lbj-cleanup-dir=" + CommandLineQuote(cleanupDirectory);
  }
  std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
  mutableCommand.push_back(L'\0');

  STARTUPINFOW startupInfo{};
  startupInfo.cb = sizeof(startupInfo);
  PROCESS_INFORMATION processInfo{};
  const BOOL created = CreateProcessW(
      executable.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
      0, nullptr, nullptr, &startupInfo, &processInfo);
  if (!created) return false;
  CloseHandle(processInfo.hThread);
  CloseHandle(processInfo.hProcess);
  return true;
}

void Log(const std::wstring& message) {
  wchar_t tempPath[MAX_PATH]{};
  const DWORD length = GetTempPathW(MAX_PATH, tempPath);
  if (length == 0 || length >= MAX_PATH) return;
  std::wofstream log(std::wstring(tempPath) + L"LBJConsole-updater.log",
                     std::ios::app);
  log << message << L"\n";
}

int Fail(const std::wstring& executable, const std::wstring& message,
         int code) {
  Log(message);
  MessageBoxW(nullptr, message.c_str(), L"LBJ Console Update Failed",
              MB_OK | MB_ICONERROR);
  StartApplication(executable, L"");
  return code;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* commandLine, _In_ int showCommand) {
  int argumentCount = 0;
  wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
  if (arguments == nullptr || argumentCount < 4) {
    if (arguments != nullptr) LocalFree(arguments);
    return 2;
  }

  const std::wstring installDirectory = arguments[1];
  const std::wstring zipPath = arguments[2];
  const std::wstring cleanupDirectory = arguments[3];
  LocalFree(arguments);
  const std::wstring executable = installDirectory + L"\\lbjconsole.exe";

  const std::wstring stagingDirectory = cleanupDirectory + L"\\staging";
  const std::wstring extractCommand =
      L"Expand-Archive -LiteralPath " + PowerShellQuote(zipPath) +
      L" -DestinationPath " + PowerShellQuote(stagingDirectory) + L" -Force";
  if (!RunPowerShell(extractCommand)) {
    return Fail(executable, L"Unable to extract the update package.", 3);
  }

  const std::wstring copyCommand =
      L"Get-ChildItem -LiteralPath " + PowerShellQuote(stagingDirectory) +
      L" -Force | Where-Object { $_.Name -ne 'lbj_updater.exe' } | "
      L"Copy-Item -Destination " + PowerShellQuote(installDirectory) +
      L" -Recurse -Force";

  bool copied = false;
  for (int attempt = 0; attempt < 10 && !copied; ++attempt) {
    if (attempt > 0) Sleep(500);
    copied = RunPowerShell(copyCommand);
  }
  if (!copied) {
    return Fail(executable,
                L"Unable to replace program files. Check folder permissions.",
                4);
  }

  if (!StartApplication(executable, cleanupDirectory)) {
    return Fail(executable,
                L"The update completed, but the new program could not start.",
                5);
  }
  return 0;
}
