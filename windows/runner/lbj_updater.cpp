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

std::wstring FullPath(const std::wstring& path) {
  wchar_t buffer[MAX_PATH]{};
  const DWORD length = GetFullPathNameW(path.c_str(), MAX_PATH, buffer, nullptr);
  return length == 0 || length >= MAX_PATH ? L"" : std::wstring(buffer, length);
}

bool IsWithin(const std::wstring& parent, const std::wstring& child) {
  if (parent.empty() || child.size() <= parent.size()) return false;
  if (_wcsnicmp(parent.c_str(), child.c_str(), parent.size()) != 0) return false;
  return child[parent.size()] == L'\\';
}

bool IsRegularFile(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

bool IsSafeUpdateDirectory(const std::wstring& directory,
                           const std::wstring& zipPath) {
  wchar_t tempPath[MAX_PATH]{};
  const DWORD length = GetTempPathW(MAX_PATH, tempPath);
  if (length == 0 || length >= MAX_PATH) return false;

  const std::wstring root = FullPath(std::wstring(tempPath) + L"LBJConsole");
  const std::wstring target = FullPath(directory);
  const std::wstring zip = FullPath(zipPath);
  if (!IsWithin(root, target) || !IsWithin(target, zip)) return false;
  if (zip.substr(zip.find_last_of(L"\\/") + 1) != L"update.zip") return false;
  const auto separator = target.find_last_of(L"\\/");
  if (separator == std::wstring::npos ||
      target.substr(separator + 1).rfind(L"update_", 0) != 0) {
    return false;
  }

  const DWORD targetAttributes = GetFileAttributesW(target.c_str());
  if (targetAttributes == INVALID_FILE_ATTRIBUTES ||
      (targetAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (targetAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  return IsRegularFile(zip) &&
         IsRegularFile(target + L"\\.lbj-update-marker");
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

  if (!IsSafeUpdateDirectory(cleanupDirectory, zipPath)) {
    Log(L"Rejected unsafe update directory or archive.");
    MessageBoxW(nullptr, L"Invalid update staging directory.",
                L"LBJ Console Update Failed", MB_OK | MB_ICONERROR);
    return 2;
  }

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
