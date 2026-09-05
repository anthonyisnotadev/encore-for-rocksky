// Single-file launcher for encore for rocksky.
//
// Flutter's Windows output is a directory, not an executable: the .exe is a
// host stub that loads flutter_windows.dll and reads data\ beside itself. This
// wraps that whole directory, compressed into a .cab, inside one .exe that can
// be handed out on its own.
//
// At run time it unpacks the payload into a private temporary directory, starts
// the real application, waits for it to exit, then deletes everything it wrote.
// Nothing is installed and nothing is left behind.
//
// Built by tool\build_single_exe.ps1, which produces the .cab and links it in
// as resource IDR_PAYLOAD.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>

#include <string>
#include <vector>

#pragma comment(lib, "setupapi.lib")
// MessageBoxW, for the failure paths.
#pragma comment(lib, "user32.lib")

namespace {

// Must match the resource id in sfx.rc.
constexpr int kPayloadResourceId = 101;

// Started once the payload is unpacked, relative to the extraction directory.
// Must match BINARY_NAME in windows\CMakeLists.txt.
constexpr wchar_t kAppExe[] = L"encore_for_rocksky.exe";

// Tells the unpacked app where the distributed .exe actually lives, so
// PortableMode can still find a PortableData\ folder next to it. Without this
// the app would only ever see its temporary directory. Must match _hostDirEnv
// in lib\services\portable_mode.dart.
constexpr wchar_t kHostDirEnv[] = L"ENCORE_PORTABLE_HOST_DIR";

// Prefix for our directories under %TEMP%. Deliberately short: cabinet
// extraction fills a FullTargetName[MAX_PATH] buffer, so every character spent
// here comes off the budget for the paths inside the payload.
constexpr wchar_t kTempPrefix[] = L"efr-";

// Held open with no sharing for the lifetime of the process. Its only job is to
// let another instance tell a live extraction directory from one orphaned by a
// crash or a killed process.
constexpr wchar_t kLockFile[] = L".lock";

void Fail(const wchar_t* message) {
  MessageBoxW(nullptr, message, L"encore for rocksky", MB_ICONERROR | MB_OK);
}

std::wstring Join(const std::wstring& dir, const std::wstring& leaf) {
  return dir + L"\\" + leaf;
}

std::wstring DirectoryOf(const std::wstring& filePath) {
  const size_t cut = filePath.find_last_of(L'\\');
  return cut == std::wstring::npos ? std::wstring() : filePath.substr(0, cut);
}

// Creates every missing directory along the path to a file. Cabinet entries
// carry relative paths such as data\flutter_assets\..., and extraction fails if
// the parent does not already exist.
bool EnsureParentDirectory(const std::wstring& filePath) {
  const std::wstring dir = DirectoryOf(filePath);
  if (dir.empty()) return true;

  // Walk forwards so parents are created before their children. Starting the
  // search past the drive letter avoids trying to create "C:".
  for (size_t i = dir.find(L'\\', 3); i != std::wstring::npos;
       i = dir.find(L'\\', i + 1)) {
    const std::wstring part = dir.substr(0, i);
    if (!CreateDirectoryW(part.c_str(), nullptr) &&
        GetLastError() != ERROR_ALREADY_EXISTS) {
      return false;
    }
  }
  return CreateDirectoryW(dir.c_str(), nullptr) != 0 ||
         GetLastError() == ERROR_ALREADY_EXISTS;
}

bool DeleteTree(const std::wstring& dir) {
  WIN32_FIND_DATAW find = {};
  const HANDLE search = FindFirstFileW(Join(dir, L"*").c_str(), &find);
  if (search != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = find.cFileName;
      if (name == L"." || name == L"..") continue;

      const std::wstring path = Join(dir, name);
      if (find.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        DeleteTree(path);
      } else {
        // Clear read-only rather than fail on it; files arrive from a cabinet
        // carrying whatever attributes were captured at packaging time.
        SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(path.c_str());
      }
    } while (FindNextFileW(search, &find));
    FindClose(search);
  }
  return RemoveDirectoryW(dir.c_str()) != 0;
}

// Opens a directory's lock file with no sharing. Success means no other
// instance holds that directory, so it is safe to delete.
bool IsOrphaned(const std::wstring& dir) {
  const HANDLE lock =
      CreateFileW(Join(dir, kLockFile).c_str(), GENERIC_READ, 0, nullptr,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (lock == INVALID_HANDLE_VALUE) {
    // A missing lock file means an extraction that never got that far. A
    // sharing violation means a live instance, which must be left alone.
    return GetLastError() != ERROR_SHARING_VIOLATION;
  }
  CloseHandle(lock);
  return true;
}

// Removes extraction directories left by earlier runs that were killed before
// they could clean up. Skips any another instance is still using.
void SweepOrphans(const std::wstring& tempRoot, const std::wstring& keep) {
  const std::wstring pattern = Join(tempRoot, std::wstring(kTempPrefix) + L"*");
  WIN32_FIND_DATAW find = {};
  const HANDLE search = FindFirstFileW(pattern.c_str(), &find);
  if (search == INVALID_HANDLE_VALUE) return;

  do {
    if (!(find.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
    const std::wstring path = Join(tempRoot, find.cFileName);
    if (path == keep) continue;
    if (IsOrphaned(path)) DeleteTree(path);
  } while (FindNextFileW(search, &find));
  FindClose(search);
}

bool WriteResourceToFile(int resourceId, const std::wstring& path) {
  const HRSRC info =
      FindResourceW(nullptr, MAKEINTRESOURCEW(resourceId), RT_RCDATA);
  if (!info) return false;
  const HGLOBAL loaded = LoadResource(nullptr, info);
  if (!loaded) return false;
  const void* data = LockResource(loaded);
  const DWORD size = SizeofResource(nullptr, info);
  if (!data || size == 0) return false;

  const HANDLE file =
      CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                  FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  DWORD written = 0;
  const bool ok =
      WriteFile(file, data, size, &written, nullptr) != 0 && written == size;
  CloseHandle(file);
  return ok;
}

UINT CALLBACK CabinetCallback(PVOID context, UINT notification, UINT_PTR param1,
                              UINT_PTR param2) {
  UNREFERENCED_PARAMETER(param2);
  if (notification != SPFILENOTIFY_FILEINCABINET) return NO_ERROR;

  auto* const entry = reinterpret_cast<FILE_IN_CABINET_INFO_W*>(param1);
  const auto* const destination = static_cast<const std::wstring*>(context);
  const std::wstring target = Join(*destination, entry->NameInCabinet);
  if (target.size() >= MAX_PATH) return FILEOP_SKIP;
  if (!EnsureParentDirectory(target)) return FILEOP_ABORT;

  // The struct doubles as the output parameter: setupapi extracts to whatever
  // path is written into FullTargetName.
  wcscpy_s(entry->FullTargetName, MAX_PATH, target.c_str());
  return FILEOP_DOIT;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR commandLine, int) {
  wchar_t selfPath[MAX_PATH] = {};
  if (!GetModuleFileNameW(nullptr, selfPath, MAX_PATH)) {
    Fail(L"Could not determine the location of this program.");
    return 1;
  }
  const std::wstring hostDir = DirectoryOf(selfPath);

  wchar_t tempRoot[MAX_PATH] = {};
  if (!GetTempPathW(MAX_PATH, tempRoot)) {
    Fail(L"Could not find a temporary directory to unpack into.");
    return 1;
  }
  std::wstring temp = tempRoot;
  if (!temp.empty() && temp.back() == L'\\') temp.pop_back();

  // Process id and tick count together keep a concurrently starting second copy
  // out of the way; the lock file settles ownership after that.
  wchar_t suffix[64] = {};
  swprintf_s(suffix, L"%s%lu-%llu", kTempPrefix, GetCurrentProcessId(),
             GetTickCount64());
  const std::wstring extractDir = Join(temp, suffix);

  SweepOrphans(temp, extractDir);

  if (!CreateDirectoryW(extractDir.c_str(), nullptr)) {
    Fail(L"Could not create a temporary directory to unpack into.");
    return 1;
  }

  const HANDLE lock =
      CreateFileW(Join(extractDir, kLockFile).c_str(), GENERIC_WRITE, 0,
                  nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);

  int exitCode = 1;
  const std::wstring cabPath = Join(extractDir, L"p.cab");
  if (!WriteResourceToFile(kPayloadResourceId, cabPath)) {
    Fail(L"This program's payload is missing or damaged. Download it again.");
  } else if (!SetupIterateCabinetW(cabPath.c_str(), 0, CabinetCallback,
                                   const_cast<std::wstring*>(&extractDir))) {
    Fail(L"Could not unpack the application. Check for free disk space, and "
         L"for security software blocking writes to the temporary folder.");
  } else {
    // Dead weight once unpacked, and the largest single file involved.
    DeleteFileW(cabPath.c_str());

    SetEnvironmentVariableW(kHostDirEnv, hostDir.c_str());

    const std::wstring appPath = Join(extractDir, kAppExe);
    // CreateProcessW may write to its command line argument, so it cannot be a
    // string literal. Forwarding our own arguments keeps anything passed to the
    // wrapper working.
    std::wstring arguments = L"\"" + appPath + L"\"";
    if (commandLine && *commandLine) {
      arguments += L" ";
      arguments += commandLine;
    }
    std::vector<wchar_t> mutableArguments(arguments.begin(), arguments.end());
    mutableArguments.push_back(L'\0');

    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    if (!CreateProcessW(appPath.c_str(), mutableArguments.data(), nullptr,
                        nullptr, FALSE, 0, nullptr, extractDir.c_str(),
                        &startup, &process)) {
      Fail(L"Could not start the application after unpacking it.");
    } else {
      // Blocks for the whole session: the window closes to the notification
      // area and the process only exits on "End task" in the tray menu. That is
      // what makes deleting the unpacked copy afterwards safe.
      WaitForSingleObject(process.hProcess, INFINITE);
      DWORD childExit = 0;
      if (GetExitCodeProcess(process.hProcess, &childExit)) {
        exitCode = static_cast<int>(childExit);
      }
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
    }
  }

  if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
  // Windows can hold a just-exited image open for a moment; retrying avoids
  // leaving the directory for the next run's sweep to deal with.
  for (int attempt = 0; attempt < 20 && !DeleteTree(extractDir); ++attempt) {
    Sleep(100);
  }
  return exitCode;
}
