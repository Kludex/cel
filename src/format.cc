#include <charconv>
#include <cstddef>

extern "C" int cel_format_double(double value, int precision, int scientific,
                                 char *buffer, size_t size, size_t *written) {
  const auto mode =
      scientific ? std::chars_format::scientific : std::chars_format::fixed;
  const auto result =
      std::to_chars(buffer, buffer + size, value, mode, precision);
  if (result.ec != std::errc{})
    return 1;
  *written = static_cast<size_t>(result.ptr - buffer);
  return 0;
}
