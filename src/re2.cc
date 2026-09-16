#include <cstddef>
#include <cstdint>
#include <memory>
#include <new>
#include <string_view>

#include "re2/re2.h"

extern "C" void *cel_re2_compile(const std::uint8_t *pattern,
                                 std::size_t length, std::int64_t memory_limit,
                                 std::size_t program_limit, int *status,
                                 std::size_t *program_size) noexcept {
  try {
    re2::RE2::Options options;
    options.set_log_errors(false);
    options.set_max_mem(memory_limit);
    options.set_never_capture(true);
    auto compiled = std::make_unique<re2::RE2>(
        std::string_view(reinterpret_cast<const char *>(pattern), length),
        options);
    if (!compiled->ok()) {
      *status =
          compiled->error_code() == re2::RE2::ErrorPatternTooLarge ? 2 : 1;
      return nullptr;
    }
    const int size = compiled->ProgramSize();
    if (size < 0 || static_cast<std::size_t>(size) > program_limit) {
      *status = 2;
      return nullptr;
    }
    *program_size = static_cast<std::size_t>(size);
    *status = 0;
    return compiled.release();
  } catch (const std::bad_alloc &) {
    *status = 3;
    return nullptr;
  }
}

extern "C" int cel_re2_match(const void *handle, const std::uint8_t *text,
                             std::size_t length) noexcept {
  try {
    const auto *compiled = static_cast<const re2::RE2 *>(handle);
    return compiled->Match(
               std::string_view(reinterpret_cast<const char *>(text), length),
               0, length, re2::RE2::UNANCHORED, nullptr, 0)
               ? 1
               : 0;
  } catch (const std::bad_alloc &) {
    return -1;
  }
}

extern "C" void cel_re2_free(void *handle) noexcept {
  delete static_cast<re2::RE2 *>(handle);
}
