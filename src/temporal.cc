#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <string_view>

#include "absl/time/time.h"
#include "google/protobuf/timestamp.pb.h"
#include "google/protobuf/util/time_util.h"

extern "C" int cel_timestamp_parse(const char *data, std::size_t size,
                                   std::int64_t *seconds,
                                   std::uint32_t *nanos) {
  try {
    google::protobuf::Timestamp result;
    if (!google::protobuf::util::TimeUtil::FromString(
            std::string_view(data, size), &result))
      return 1;
    *seconds = result.seconds();
    *nanos = static_cast<std::uint32_t>(result.nanos());
    return 0;
  } catch (const std::bad_alloc &) {
    return 2;
  }
}

extern "C" int cel_duration_parse(const char *data, std::size_t size,
                                  std::int64_t *nanos) {
  try {
    const auto input = std::string_view(data, size);
    if (input.empty() ||
        input.find_first_not_of("0123456789+-.hmsun") != std::string_view::npos)
      return 1;
    absl::Duration result;
    if (!absl::ParseDuration(input, &result)) {
      // Abseil's integer component cannot represent abs(INT64_MIN) nanoseconds.
      std::string normalized;
      std::size_t copied = 0;
      std::size_t position = 0;
      while ((position = input.find("ns", position)) !=
             std::string_view::npos) {
        auto start = position;
        while (start > copied &&
               ((input[start - 1] >= '0' && input[start - 1] <= '9') ||
                input[start - 1] == '.'))
          --start;
        const auto number = input.substr(start, position - start);
        const auto point = number.find('.');
        const auto integer_size =
            point == std::string_view::npos ? number.size() : point;
        if (integer_size > 18) {
          normalized.append(input.substr(copied, start - copied));
          normalized.append(number.substr(0, integer_size - 9));
          normalized += '.';
          normalized.append(number.substr(integer_size - 9, 9));
          if (point != std::string_view::npos)
            normalized.append(number.substr(point + 1));
          normalized += 's';
          copied = position + 2;
        }
        position += 2;
      }
      normalized.append(input.substr(copied));
      if (!absl::ParseDuration(normalized, &result))
        return 1;
    }
    const auto low =
        absl::Nanoseconds(std::numeric_limits<std::int64_t>::min());
    const auto high =
        absl::Nanoseconds(std::numeric_limits<std::int64_t>::max());
    if (result <= low - absl::Nanoseconds(1) ||
        result >= high + absl::Nanoseconds(1))
      return 3;
    *nanos = absl::ToInt64Nanoseconds(result);
    return 0;
  } catch (const std::bad_alloc &) {
    return 2;
  }
}

extern "C" int cel_timestamp_format(std::int64_t seconds, std::uint32_t nanos,
                                    char *buffer, std::size_t capacity,
                                    std::size_t *size) {
  try {
    const auto time = absl::FromUnixSeconds(seconds) + absl::Nanoseconds(nanos);
    const auto text =
        absl::FormatTime("%E4Y-%m-%dT%H:%M:%E*SZ", time, absl::UTCTimeZone());
    if (text.size() > capacity)
      return 1;
    std::memcpy(buffer, text.data(), text.size());
    *size = text.size();
    return 0;
  } catch (const std::bad_alloc &) {
    return 2;
  }
}

extern "C" int cel_timestamp_select(std::int64_t seconds, std::uint32_t nanos,
                                    const char *zone_data,
                                    std::size_t zone_size, int selector,
                                    std::int64_t *result) {
  try {
    const auto name = std::string_view(zone_data, zone_size);
    absl::TimeZone zone = absl::UTCTimeZone();
    if (!name.empty() && name != "UTC") {
      auto offset = name;
      int sign = 1;
      if (offset.front() == '+' || offset.front() == '-') {
        if (offset.front() == '-')
          sign = -1;
        offset.remove_prefix(1);
      }
      if (offset.size() == 5 && offset[2] == ':') {
        for (std::size_t i : {0, 1, 3, 4})
          if (offset[i] < '0' || offset[i] > '9')
            return 1;
        const int hours = (offset[0] - '0') * 10 + offset[1] - '0';
        const int minutes = (offset[3] - '0') * 10 + offset[4] - '0';
        if (hours > 23 || minutes > 59)
          return 1;
        zone = absl::FixedTimeZone(sign * (hours * 3600 + minutes * 60));
      } else {
        if (name.size() > 128 || name == "localtime" || name == "posixrules" ||
            name.substr(0, 6) == "posix/" || name.substr(0, 6) == "right/" ||
            name.front() == '/' || name.find("..") != std::string_view::npos ||
            name.find("//") != std::string_view::npos || name.back() == '/' ||
            name.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
                                   "rstuvwxyz0123456789_/-+") !=
                std::string_view::npos)
          return 1;
        if (!absl::LoadTimeZone(name, &zone))
          return 1;
      }
    }
    const auto time = absl::FromUnixSeconds(seconds) + absl::Nanoseconds(nanos);
    const auto civil = absl::ToCivilSecond(time, zone);
    switch (selector) {
    case 0:
      *result = civil.day();
      break;
    case 1:
      *result = civil.day() - 1;
      break;
    case 2: {
      switch (absl::GetWeekday(absl::CivilDay(civil))) {
      case absl::Weekday::sunday:
        *result = 0;
        break;
      case absl::Weekday::monday:
        *result = 1;
        break;
      case absl::Weekday::tuesday:
        *result = 2;
        break;
      case absl::Weekday::wednesday:
        *result = 3;
        break;
      case absl::Weekday::thursday:
        *result = 4;
        break;
      case absl::Weekday::friday:
        *result = 5;
        break;
      case absl::Weekday::saturday:
        *result = 6;
        break;
      }
      break;
    }
    case 3:
      *result = absl::CivilDay(civil) - absl::CivilDay(civil.year(), 1, 1);
      break;
    case 4:
      *result = civil.year();
      break;
    case 5:
      *result = civil.hour();
      break;
    case 6:
      *result = nanos / 1000000;
      break;
    case 7:
      *result = civil.minute();
      break;
    case 8:
      *result = civil.month() - 1;
      break;
    case 9:
      *result = civil.second();
      break;
    default:
      return 1;
    }
    return 0;
  } catch (const std::bad_alloc &) {
    return 2;
  }
}
