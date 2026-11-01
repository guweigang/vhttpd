// WOFF2 is a package resource; decoded fonts live in a verified user cache.
// Keep decoding in a short lived process so its peak working memory is released.
#include <woff2/decode.h>
#include <woff2/output.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#ifdef _WIN32
int wmain(int argc, wchar_t **argv) {
#else
int main(int argc, char **argv) {
#endif
  if (argc != 3) return 2;
  const std::filesystem::path source(argv[1]), target(argv[2]);
  std::error_code error;
  const auto size = std::filesystem::file_size(source, error);
  if (error || size < 48 || size > 32 * 1024 * 1024) return 3;
  std::ifstream input(source, std::ios::binary);
  if (!input) return 3;
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
  if (bytes.size() != size) return 3;
  std::string decoded;
  woff2::WOFF2StringOut output(&decoded);
  output.SetMaxSize(64 * 1024 * 1024);
  if (!woff2::ConvertWOFF2ToTTF(bytes.data(), bytes.size(), &output)) return 4;
  std::ofstream file(target, std::ios::binary | std::ios::trunc);
  file.write(decoded.data(), decoded.size());
  file.close();
  return file ? 0 : 5;
}
