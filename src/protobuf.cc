#include "protobuf.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "absl/numeric/int128.h"
#include "absl/strings/escaping.h"
#include "google/protobuf/any.pb.h"
#include "google/protobuf/descriptor.pb.h"
#include "google/protobuf/duration.pb.h"
#include "google/protobuf/dynamic_message.h"
#include "google/protobuf/empty.pb.h"
#include "google/protobuf/io/coded_stream.h"
#include "google/protobuf/struct.pb.h"
#include "google/protobuf/timestamp.pb.h"
#include "google/protobuf/util/json_util.h"
#include "google/protobuf/util/message_differencer.h"
#include "google/protobuf/wrappers.pb.h"

namespace gpb = google::protobuf;
using Field = gpb::FieldDescriptor;
using Message = gpb::Message;
using Descriptor = gpb::Descriptor;

struct CelProtoRegistry {
  std::atomic<size_t> references{1};
  gpb::DescriptorPool pool;
  gpb::DynamicMessageFactory factory{&pool};
  CelProtoRegistry() { factory.SetDelegateToGeneratedFactory(true); }
};

struct EqualityCost {
  size_t bytes;
  size_t fields;
};

struct CelProtoScope {
  gpb::Arena arena;
  CelProtoRegistry *registry;
  size_t byte_limit;
  int depth_limit;
  size_t remaining;
  size_t remaining_bytes;
  bool strong_enums;
  std::unordered_map<const gpb::Message *, EqualityCost> equality_costs;
};

static const gpb::DescriptorPool *pool(CelProtoRegistry *registry) {
  (void)gpb::Any::descriptor();
  (void)gpb::DescriptorProto::descriptor();
  (void)gpb::Duration::descriptor();
  (void)gpb::Empty::descriptor();
  (void)gpb::Struct::descriptor();
  (void)gpb::Timestamp::descriptor();
  (void)gpb::BoolValue::descriptor();
  return registry ? &registry->pool : gpb::DescriptorPool::generated_pool();
}

static const Descriptor *descriptor(const CelProtoDescriptor *value) {
  return reinterpret_cast<const Descriptor *>(value);
}
static const Field *field(const CelProtoField *value) {
  return reinterpret_cast<const Field *>(value);
}
static const Message *message(const CelProtoMessage *value) {
  return reinterpret_cast<const Message *>(value);
}
static const CelProtoMessage *opaque(const Message *value) {
  return reinterpret_cast<const CelProtoMessage *>(value);
}

class DescriptorErrors final : public gpb::DescriptorPool::ErrorCollector {
public:
  void RecordError(absl::string_view, absl::string_view, const Message *,
                   ErrorLocation, absl::string_view) override {}
};

extern "C" CelProtoRegistry *cel_proto_registry(const uint8_t *data,
                                                size_t size, size_t max_files,
                                                int depth_limit, int *status) {
  try {
    if (size > static_cast<size_t>(std::numeric_limits<int>::max())) {
      *status = CEL_P_LIMIT;
      return nullptr;
    }
    gpb::FileDescriptorSet files;
    gpb::io::CodedInputStream stream(data, static_cast<int>(size));
    stream.SetRecursionLimit(depth_limit);
    stream.SetTotalBytesLimit(static_cast<int>(size));
    if (!files.ParseFromCodedStream(&stream) ||
        !stream.ConsumedEntireMessage()) {
      *status = CEL_P_INVALID;
      return nullptr;
    }
    if (static_cast<size_t>(files.file_size()) > max_files) {
      *status = CEL_P_LIMIT;
      return nullptr;
    }
    auto registry = std::make_unique<CelProtoRegistry>();
    DescriptorErrors errors;
    std::unordered_set<std::string> seen;
    for (const auto &file : files.file()) {
      if (!seen.insert(file.name()).second) {
        *status = CEL_P_INVALID;
        return nullptr;
      }
    }
    size_t left = seen.size();
    while (left) {
      bool progress = false;
      for (const auto &file : files.file()) {
        if (!seen.count(file.name()))
          continue;
        bool ready = true;
        for (const auto &dependency : file.dependency()) {
          if (!registry->pool.FindFileByName(dependency)) {
            ready = false;
            break;
          }
        }
        if (!ready)
          continue;
        if (!registry->pool.BuildFileCollectingErrors(file, &errors)) {
          *status = CEL_P_INVALID;
          return nullptr;
        }
        seen.erase(file.name());
        --left;
        progress = true;
      }
      if (!progress) {
        *status = CEL_P_INVALID;
        return nullptr;
      }
    }
    *status = CEL_P_OK;
    return registry.release();
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}

extern "C" void cel_proto_retain(CelProtoRegistry *value) {
  if (value)
    ++value->references;
}
extern "C" void cel_proto_release(CelProtoRegistry *value) {
  if (value && --value->references == 0)
    delete value;
}
extern "C" const CelProtoDescriptor *
cel_proto_descriptor(CelProtoRegistry *registry, const char *name, size_t size,
                     int *status) {
  try {
    *status = CEL_P_OK;
    const auto text = std::string_view(name, size);
    const auto *result = pool(registry)->FindMessageTypeByName(text);
    if (!result && registry)
      result = pool(nullptr)->FindMessageTypeByName(text);
    return reinterpret_cast<const CelProtoDescriptor *>(result);
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}
static const gpb::EnumDescriptor *enumType(CelProtoRegistry *registry,
                                           std::string_view name) {
  const auto *result = pool(registry)->FindEnumTypeByName(name);
  if (!result && registry)
    result = pool(nullptr)->FindEnumTypeByName(name);
  return result;
}

static const gpb::EnumValueDescriptor *
enumValueInPool(const gpb::DescriptorPool *type_pool, std::string_view full) {
  const auto *item = type_pool->FindEnumValueByName(full);
  if (item)
    return item;
  const auto split = full.rfind('.');
  if (split == std::string_view::npos)
    return nullptr;
  const auto *type = type_pool->FindEnumTypeByName(full.substr(0, split));
  return type ? type->FindValueByName(full.substr(split + 1)) : nullptr;
}

static const gpb::EnumValueDescriptor *enumValue(CelProtoRegistry *registry,
                                                 std::string_view full) {
  const auto *result = enumValueInPool(pool(registry), full);
  if (!result && registry)
    result = enumValueInPool(pool(nullptr), full);
  return result;
}

static const char *enumResult(const gpb::EnumValueDescriptor *item,
                              int32_t *value, size_t *type_size) {
  if (!item)
    return nullptr;
  *value = item->number();
  const auto &name = item->type()->full_name();
  *type_size = name.size();
  return name.data();
}

extern "C" const char *cel_proto_enum_type(CelProtoRegistry *registry,
                                           const char *name, size_t size,
                                           size_t *result_size, int *status) {
  try {
    *status = CEL_P_OK;
    const auto *result = enumType(registry, std::string_view(name, size));
    if (!result)
      return nullptr;
    const auto &full_name = result->full_name();
    *result_size = full_name.size();
    return full_name.data();
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}

extern "C" const char *cel_proto_enum(CelProtoRegistry *registry,
                                      const char *name, size_t size,
                                      int32_t *value, size_t *type_size,
                                      int *status) {
  try {
    *status = CEL_P_OK;
    return enumResult(enumValue(registry, std::string_view(name, size)), value,
                      type_size);
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}

extern "C" const char *
cel_proto_enum_symbol(CelProtoRegistry *registry, const char *type_name,
                      size_t type_size, const char *symbol, size_t symbol_size,
                      int32_t *value, size_t *name_size, int *status) {
  try {
    *status = CEL_P_OK;
    const auto *type =
        enumType(registry, std::string_view(type_name, type_size));
    return enumResult(
        type ? type->FindValueByName(std::string_view(symbol, symbol_size))
             : nullptr,
        value, name_size);
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}
extern "C" const char *cel_proto_name(const CelProtoDescriptor *type,
                                      size_t *size) {
  const auto &name = descriptor(type)->full_name();
  *size = name.size();
  return name.data();
}
extern "C" const CelProtoField *cel_proto_field(const CelProtoDescriptor *type,
                                                const char *name, size_t size,
                                                int *status) {
  try {
    *status = CEL_P_OK;
    const auto text = std::string_view(name, size);
    const auto *result = descriptor(type)->FindFieldByName(text);
    if (!result)
      result = descriptor(type)->file()->pool()->FindExtensionByName(text);
    if (result && result->containing_type() != descriptor(type))
      result = nullptr;
    return reinterpret_cast<const CelProtoField *>(result);
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}
extern "C" int cel_proto_field_kind(const CelProtoField *raw) {
  switch (field(raw)->cpp_type()) {
  case Field::CPPTYPE_BOOL:
    return CEL_P_BOOL;
  case Field::CPPTYPE_INT32:
  case Field::CPPTYPE_INT64:
    return CEL_P_INT;
  case Field::CPPTYPE_ENUM:
    return CEL_P_ENUM;
  case Field::CPPTYPE_UINT32:
  case Field::CPPTYPE_UINT64:
    return CEL_P_UINT;
  case Field::CPPTYPE_FLOAT:
  case Field::CPPTYPE_DOUBLE:
    return CEL_P_DOUBLE;
  case Field::CPPTYPE_STRING:
    return field(raw)->type() == Field::TYPE_BYTES ? CEL_P_BYTES : CEL_P_STRING;
  case Field::CPPTYPE_MESSAGE:
    return CEL_P_MESSAGE;
  }
  return -1;
}
extern "C" int cel_proto_repeated(const CelProtoField *raw) {
  return field(raw)->is_repeated();
}
extern "C" int cel_proto_map(const CelProtoField *raw) {
  return field(raw)->is_map();
}
extern "C" const CelProtoDescriptor *
cel_proto_field_message(const CelProtoField *raw) {
  return reinterpret_cast<const CelProtoDescriptor *>(
      field(raw)->message_type());
}
extern "C" const char *cel_proto_field_enum(const CelProtoField *raw,
                                            size_t *size) {
  const auto &name = field(raw)->enum_type()->full_name();
  *size = name.size();
  return name.data();
}
extern "C" const CelProtoField *cel_proto_map_key(const CelProtoField *raw) {
  return reinterpret_cast<const CelProtoField *>(
      field(raw)->message_type()->map_key());
}
extern "C" const CelProtoField *cel_proto_map_value(const CelProtoField *raw) {
  return reinterpret_cast<const CelProtoField *>(
      field(raw)->message_type()->map_value());
}

extern "C" CelProtoScope *cel_proto_scope(CelProtoRegistry *registry,
                                          size_t bytes, size_t total_bytes,
                                          int depth, size_t values,
                                          int strong_enums, int *status) {
  try {
    auto scope = std::make_unique<CelProtoScope>();
    scope->registry = registry;
    scope->byte_limit = bytes;
    scope->depth_limit = depth;
    scope->remaining = values;
    scope->remaining_bytes = total_bytes;
    scope->strong_enums = strong_enums != 0;
    *status = CEL_P_OK;
    return scope.release();
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}
extern "C" void cel_proto_scope_free(CelProtoScope *scope) { delete scope; }

static Message *create(CelProtoScope *scope, const Descriptor *type) {
  const Message *prototype =
      scope->registry
          ? scope->registry->factory.GetPrototype(type)
          : gpb::MessageFactory::generated_factory()->GetPrototype(type);
  return prototype ? prototype->New(&scope->arena) : nullptr;
}
extern "C" const CelProtoMessage *
cel_proto_parse(CelProtoScope *scope, const CelProtoDescriptor *type,
                const uint8_t *data, size_t size, int *status) {
  try {
    if (size > scope->byte_limit || size > scope->remaining_bytes ||
        scope->remaining == 0 ||
        size > static_cast<size_t>(std::numeric_limits<int>::max())) {
      *status = CEL_P_LIMIT;
      return nullptr;
    }
    scope->remaining_bytes -= size;
    --scope->remaining;
    auto *result = create(scope, descriptor(type));
    if (!result) {
      *status = CEL_P_UNKNOWN_TYPE;
      return nullptr;
    }
    gpb::io::CodedInputStream stream(data, static_cast<int>(size));
    stream.SetRecursionLimit(scope->depth_limit);
    stream.SetTotalBytesLimit(static_cast<int>(scope->byte_limit));
    if (!result->ParsePartialFromCodedStream(&stream) ||
        !stream.ConsumedEntireMessage()) {
      *status = CEL_P_INVALID;
      return nullptr;
    }
    *status = CEL_P_OK;
    return opaque(result);
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}

static int assign(CelProtoScope *, Message *, const Field *,
                  const CelProtoValue &, int, bool);
static int read(CelProtoScope *, const Message &, const Field *, int,
                CelProtoValue *, int);
static int adapt(CelProtoScope *, const Message &, CelProtoValue *, int);

static bool wrapper(const Descriptor *type) {
  const auto &name = type->full_name();
  return name == "google.protobuf.BoolValue" ||
         name == "google.protobuf.BytesValue" ||
         name == "google.protobuf.DoubleValue" ||
         name == "google.protobuf.FloatValue" ||
         name == "google.protobuf.Int32Value" ||
         name == "google.protobuf.Int64Value" ||
         name == "google.protobuf.StringValue" ||
         name == "google.protobuf.UInt32Value" ||
         name == "google.protobuf.UInt64Value";
}

static bool nullableScalar(const Descriptor *type) {
  return wrapper(type) || type->full_name() == "google.protobuf.Timestamp" ||
         type->full_name() == "google.protobuf.Duration";
}

static int box(CelProtoScope *scope, const Descriptor *type,
               const CelProtoValue &v, Message **result, int depth) {
  if (depth > scope->depth_limit || scope->remaining == 0)
    return CEL_P_LIMIT;
  --scope->remaining;
  *result = create(scope, type);
  if (!*result)
    return CEL_P_UNKNOWN_TYPE;
  if (v.kind == CEL_P_MESSAGE && message(v.message)->GetDescriptor() == type) {
    (*result)->CopyFrom(*message(v.message));
    return CEL_P_OK;
  }
  if (wrapper(type))
    return assign(scope, *result, type->FindFieldByName("value"), v, depth + 1,
                  false);
  const auto &name = type->full_name();
  if (name == "google.protobuf.Timestamp") {
    if (v.kind != CEL_P_TIMESTAMP)
      return CEL_P_TYPE;
    if (v.number.integer < -62135596800LL ||
        v.number.integer > 253402300799LL || v.size >= 1000000000)
      return CEL_P_OVERFLOW;
    const auto *r = (*result)->GetReflection();
    r->SetInt64(*result, type->FindFieldByName("seconds"), v.number.integer);
    r->SetInt32(*result, type->FindFieldByName("nanos"),
                static_cast<int>(v.size));
    return CEL_P_OK;
  }
  if (name == "google.protobuf.Duration") {
    if (v.kind != CEL_P_DURATION)
      return CEL_P_TYPE;
    const auto *r = (*result)->GetReflection();
    r->SetInt64(*result, type->FindFieldByName("seconds"),
                v.number.integer / 1000000000);
    r->SetInt32(*result, type->FindFieldByName("nanos"),
                static_cast<int>(v.number.integer % 1000000000));
    return CEL_P_OK;
  }
  if (name == "google.protobuf.Struct") {
    if (v.kind == CEL_P_NULL)
      return CEL_P_TYPE;
    return assign(scope, *result, type->FindFieldByName("fields"), v, depth + 1,
                  false);
  }
  if (name == "google.protobuf.ListValue") {
    if (v.kind == CEL_P_NULL)
      return CEL_P_TYPE;
    return assign(scope, *result, type->FindFieldByName("values"), v, depth + 1,
                  false);
  }
  if (name == "google.protobuf.Value") {
    const char *field_name = nullptr;
    CelProtoValue converted = v;
    std::string encoded;
    switch (v.kind) {
    case CEL_P_NULL: {
      const auto *f = type->FindFieldByName("null_value");
      (*result)->GetReflection()->SetEnumValue(*result, f, 0);
      return CEL_P_OK;
    }
    case CEL_P_BOOL:
      field_name = "bool_value";
      break;
    case CEL_P_INT:
      if (v.number.integer < -9007199254740991LL ||
          v.number.integer > 9007199254740991LL) {
        encoded = std::to_string(v.number.integer);
        field_name = "string_value";
        converted.kind = CEL_P_STRING;
        converted.data = encoded.data();
        converted.size = encoded.size();
      } else {
        field_name = "number_value";
        converted.kind = CEL_P_DOUBLE;
        converted.number.real = static_cast<double>(v.number.integer);
      }
      break;
    case CEL_P_UINT:
      if (v.number.unsigned_integer > 9007199254740991ULL) {
        encoded = std::to_string(v.number.unsigned_integer);
        field_name = "string_value";
        converted.kind = CEL_P_STRING;
        converted.data = encoded.data();
        converted.size = encoded.size();
      } else {
        field_name = "number_value";
        converted.kind = CEL_P_DOUBLE;
        converted.number.real = static_cast<double>(v.number.unsigned_integer);
      }
      break;
    case CEL_P_DOUBLE:
      field_name = "number_value";
      break;
    case CEL_P_STRING:
      field_name = "string_value";
      break;
    case CEL_P_LIST:
      field_name = "list_value";
      break;
    case CEL_P_MAP:
      field_name = "struct_value";
      break;
    case CEL_P_BYTES:
      absl::Base64Escape(std::string_view(v.data, v.size), &encoded);
      field_name = "string_value";
      converted.kind = CEL_P_STRING;
      converted.data = encoded.data();
      converted.size = encoded.size();
      break;
    case CEL_P_TIMESTAMP:
    case CEL_P_DURATION: {
      const char *type_name = v.kind == CEL_P_TIMESTAMP
                                  ? "google.protobuf.Timestamp"
                                  : "google.protobuf.Duration";
      const auto *time_type =
          pool(scope->registry)->FindMessageTypeByName(type_name);
      if (!time_type)
        time_type = pool(nullptr)->FindMessageTypeByName(type_name);
      Message *time = nullptr;
      const int result_status = box(scope, time_type, v, &time, depth + 1);
      if (result_status)
        return result_status;
      const auto json_status = gpb::util::MessageToJsonString(*time, &encoded);
      if (!json_status.ok() || encoded.size() > scope->remaining_bytes)
        return CEL_P_TYPE;
      scope->remaining_bytes -= encoded.size();
      return gpb::util::JsonStringToMessage(encoded, *result).ok() ? CEL_P_OK
                                                                   : CEL_P_TYPE;
    }
    case CEL_P_MESSAGE: {
      const auto status =
          gpb::util::MessageToJsonString(*message(v.message), &encoded);
      if (!status.ok() || encoded.size() > scope->remaining_bytes)
        return CEL_P_TYPE;
      scope->remaining_bytes -= encoded.size();
      return gpb::util::JsonStringToMessage(encoded, *result).ok() ? CEL_P_OK
                                                                   : CEL_P_TYPE;
    }
    default:
      return CEL_P_TYPE;
    }
    return assign(scope, *result, type->FindFieldByName(field_name), converted,
                  depth + 1, false);
  }
  if (name == "google.protobuf.Any") {
    const Message *payload = nullptr;
    if (v.kind == CEL_P_MESSAGE)
      payload = message(v.message);
    else {
      const char *boxed_name = nullptr;
      switch (v.kind) {
      case CEL_P_NULL:
        boxed_name = "google.protobuf.Value";
        break;
      case CEL_P_BOOL:
        boxed_name = "google.protobuf.BoolValue";
        break;
      case CEL_P_INT:
        boxed_name = "google.protobuf.Int64Value";
        break;
      case CEL_P_UINT:
        boxed_name = "google.protobuf.UInt64Value";
        break;
      case CEL_P_DOUBLE:
        boxed_name = "google.protobuf.DoubleValue";
        break;
      case CEL_P_STRING:
        boxed_name = "google.protobuf.StringValue";
        break;
      case CEL_P_BYTES:
        boxed_name = "google.protobuf.BytesValue";
        break;
      case CEL_P_LIST:
        boxed_name = "google.protobuf.ListValue";
        break;
      case CEL_P_MAP:
        boxed_name = "google.protobuf.Struct";
        break;
      case CEL_P_TIMESTAMP:
        boxed_name = "google.protobuf.Timestamp";
        break;
      case CEL_P_DURATION:
        boxed_name = "google.protobuf.Duration";
        break;
      default:
        return CEL_P_TYPE;
      }
      const auto *boxed_type =
          pool(scope->registry)->FindMessageTypeByName(boxed_name);
      if (!boxed_type)
        boxed_type = pool(nullptr)->FindMessageTypeByName(boxed_name);
      Message *boxed = nullptr;
      const int status = box(scope, boxed_type, v, &boxed, depth + 1);
      if (status)
        return status;
      payload = boxed;
    }
    const size_t size = payload->ByteSizeLong();
    if (size > scope->byte_limit || size > scope->remaining_bytes)
      return CEL_P_LIMIT;
    scope->remaining_bytes -= size;
    std::string bytes;
    if (!payload->SerializePartialToString(&bytes))
      return CEL_P_INVALID;
    const auto *r = (*result)->GetReflection();
    r->SetString(*result, type->FindFieldByName("type_url"),
                 "type.googleapis.com/" +
                     std::string(payload->GetDescriptor()->full_name()));
    r->SetString(*result, type->FindFieldByName("value"), bytes);
    return CEL_P_OK;
  }
  return CEL_P_TYPE;
}

static int assign(CelProtoScope *scope, Message *target, const Field *f,
                  const CelProtoValue &v, int depth, bool append) {
  if (depth > scope->depth_limit || scope->remaining == 0)
    return CEL_P_LIMIT;
  --scope->remaining;
  const auto *r = target->GetReflection();
  if (f->is_map() && !append) {
    if (v.kind != CEL_P_MAP || v.count > scope->remaining / 2)
      return CEL_P_TYPE;
    for (size_t i = 0; i < v.count; ++i) {
      const auto *mapped = f->message_type()->map_value();
      if (mapped->cpp_type() == Field::CPPTYPE_MESSAGE &&
          nullableScalar(mapped->message_type()) &&
          v.items[i * 2 + 1].kind == CEL_P_NULL)
        continue;
      auto *entry = r->AddMessage(target, f);
      int status = assign(scope, entry, f->message_type()->map_key(),
                          v.items[i * 2], depth + 1, false);
      if (status)
        return status;
      status = assign(scope, entry, f->message_type()->map_value(),
                      v.items[i * 2 + 1], depth + 1, false);
      if (status)
        return status;
    }
    return CEL_P_OK;
  }
  if (f->is_repeated() && !append) {
    if (v.kind != CEL_P_LIST)
      return CEL_P_TYPE;
    if (v.count > scope->remaining)
      return CEL_P_LIMIT;
    for (size_t i = 0; i < v.count; ++i) {
      if (f->cpp_type() == Field::CPPTYPE_MESSAGE &&
          nullableScalar(f->message_type()) && v.items[i].kind == CEL_P_NULL)
        continue;
      const int status = assign(scope, target, f, v.items[i], depth + 1, true);
      if (status)
        return status;
    }
    return CEL_P_OK;
  }
  if (f->cpp_type() == Field::CPPTYPE_MESSAGE) {
    const auto *type = f->message_type();
    const auto &name = type->full_name();
    const bool dynamic =
        name == "google.protobuf.Any" || name == "google.protobuf.Value" ||
        name == "google.protobuf.Struct" || name == "google.protobuf.ListValue";
    if (v.kind == CEL_P_NULL && !dynamic && !append) {
      r->ClearField(target, f);
      return CEL_P_OK;
    }
    Message *converted = nullptr;
    const int status = box(scope, type, v, &converted, depth + 1);
    if (status)
      return status;
    if (append)
      r->AddMessage(target, f)->CopyFrom(*converted);
    else
      r->MutableMessage(target, f)->CopyFrom(*converted);
    return CEL_P_OK;
  }
  if (f->cpp_type() == Field::CPPTYPE_ENUM) {
    if (scope->strong_enums) {
      const auto &name = f->enum_type()->full_name();
      if (v.kind != CEL_P_ENUM || v.size != name.size() ||
          std::memcmp(v.data, name.data(), name.size()) != 0)
        return CEL_P_TYPE;
    } else if (v.kind != CEL_P_INT) {
      return CEL_P_TYPE;
    }
  } else if (v.kind !=
             cel_proto_field_kind(reinterpret_cast<const CelProtoField *>(f))) {
    return CEL_P_TYPE;
  }
  switch (f->cpp_type()) {
  case Field::CPPTYPE_BOOL:
    if (append)
      r->AddBool(target, f, v.number.integer != 0);
    else
      r->SetBool(target, f, v.number.integer != 0);
    break;
  case Field::CPPTYPE_INT32:
    if (v.number.integer < INT32_MIN || v.number.integer > INT32_MAX)
      return CEL_P_OVERFLOW;
    if (append)
      r->AddInt32(target, f, static_cast<int32_t>(v.number.integer));
    else
      r->SetInt32(target, f, static_cast<int32_t>(v.number.integer));
    break;
  case Field::CPPTYPE_INT64:
    if (append)
      r->AddInt64(target, f, v.number.integer);
    else
      r->SetInt64(target, f, v.number.integer);
    break;
  case Field::CPPTYPE_UINT32:
    if (v.number.unsigned_integer > UINT32_MAX)
      return CEL_P_OVERFLOW;
    if (append)
      r->AddUInt32(target, f, static_cast<uint32_t>(v.number.unsigned_integer));
    else
      r->SetUInt32(target, f, static_cast<uint32_t>(v.number.unsigned_integer));
    break;
  case Field::CPPTYPE_UINT64:
    if (append)
      r->AddUInt64(target, f, v.number.unsigned_integer);
    else
      r->SetUInt64(target, f, v.number.unsigned_integer);
    break;
  case Field::CPPTYPE_FLOAT: {
    const auto narrowed =
        std::isfinite(v.number.real) &&
                std::abs(v.number.real) > std::numeric_limits<float>::max()
            ? std::copysign(std::numeric_limits<float>::infinity(),
                            v.number.real)
            : static_cast<float>(v.number.real);
    if (append)
      r->AddFloat(target, f, static_cast<float>(narrowed));
    else
      r->SetFloat(target, f, static_cast<float>(narrowed));
    break;
  }
  case Field::CPPTYPE_DOUBLE:
    if (append)
      r->AddDouble(target, f, v.number.real);
    else
      r->SetDouble(target, f, v.number.real);
    break;
  case Field::CPPTYPE_STRING:
    if (v.size > scope->byte_limit || v.size > scope->remaining_bytes)
      return CEL_P_LIMIT;
    scope->remaining_bytes -= v.size;
    if (append)
      r->AddString(target, f, std::string(v.data, v.size));
    else
      r->SetString(target, f, std::string(v.data, v.size));
    break;
  case Field::CPPTYPE_ENUM:
    if (v.number.integer < INT32_MIN || v.number.integer > INT32_MAX)
      return CEL_P_OVERFLOW;
    if (f->enum_type()->is_closed() &&
        !f->enum_type()->FindValueByNumber(static_cast<int>(v.number.integer)))
      return CEL_P_TYPE;
    if (append)
      r->AddEnumValue(target, f, static_cast<int>(v.number.integer));
    else
      r->SetEnumValue(target, f, static_cast<int>(v.number.integer));
    break;
  case Field::CPPTYPE_MESSAGE:
    if (!v.message || message(v.message)->GetDescriptor() != f->message_type())
      return CEL_P_TYPE;
    if (append)
      r->AddMessage(target, f)->CopyFrom(*message(v.message));
    else
      r->MutableMessage(target, f)->CopyFrom(*message(v.message));
    break;
  }
  return CEL_P_OK;
}

extern "C" const CelProtoMessage *
cel_proto_construct(CelProtoScope *scope, const CelProtoDescriptor *raw,
                    const CelProtoField *const *fields,
                    const CelProtoValue *values, size_t count, int *status) {
  try {
    if (count > scope->remaining) {
      *status = CEL_P_LIMIT;
      return nullptr;
    }
    const auto *type = descriptor(raw);
    auto *result = create(scope, type);
    if (!result) {
      *status = CEL_P_UNKNOWN_TYPE;
      return nullptr;
    }
    std::unordered_set<const Field *> assigned;
    std::unordered_set<const gpb::OneofDescriptor *> oneofs;
    for (size_t i = 0; i < count; ++i) {
      const auto *f = field(fields[i]);
      if (f->containing_type() != type) {
        *status = CEL_P_FIELD;
        return nullptr;
      }
      if (!assigned.insert(f).second ||
          (f->containing_oneof() &&
           !oneofs.insert(f->containing_oneof()).second)) {
        *status = CEL_P_INVALID;
        return nullptr;
      }
      *status = assign(scope, result, f, values[i], 0, false);
      if (*status)
        return nullptr;
    }
    *status = CEL_P_OK;
    return opaque(result);
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}

static int read(CelProtoScope *scope, const Message &source, const Field *f,
                int index, CelProtoValue *out, int depth) {
  if (depth > scope->depth_limit || scope->remaining == 0)
    return CEL_P_LIMIT;
  --scope->remaining;
  *out = {};
  const auto *r = source.GetReflection();
  if (f->is_repeated() && index < 0) {
    const size_t count = static_cast<size_t>(r->FieldSize(source, f));
    const size_t width = f->is_map() ? 2 : 1;
    if (count > scope->remaining / width)
      return CEL_P_LIMIT;
    auto *items =
        gpb::Arena::CreateArray<CelProtoValue>(&scope->arena, count * width);
    out->kind = f->is_map() ? CEL_P_MAP : CEL_P_LIST;
    out->items = items;
    out->count = count;
    for (size_t i = 0; i < count; ++i) {
      if (f->is_map()) {
        const auto &entry =
            r->GetRepeatedMessage(source, f, static_cast<int>(i));
        int status = read(scope, entry, f->message_type()->map_key(), -1,
                          &items[i * 2], depth + 1);
        if (status)
          return status;
        status = read(scope, entry, f->message_type()->map_value(), -1,
                      &items[i * 2 + 1], depth + 1);
        if (status)
          return status;
      } else {
        const int status =
            read(scope, source, f, static_cast<int>(i), &items[i], depth + 1);
        if (status)
          return status;
      }
    }
    return CEL_P_OK;
  }
  out->kind = cel_proto_field_kind(reinterpret_cast<const CelProtoField *>(f));
  switch (f->cpp_type()) {
  case Field::CPPTYPE_BOOL:
    out->number.integer = index < 0 ? r->GetBool(source, f)
                                    : r->GetRepeatedBool(source, f, index);
    break;
  case Field::CPPTYPE_INT32:
    out->number.integer = index < 0 ? r->GetInt32(source, f)
                                    : r->GetRepeatedInt32(source, f, index);
    break;
  case Field::CPPTYPE_INT64:
    out->number.integer = index < 0 ? r->GetInt64(source, f)
                                    : r->GetRepeatedInt64(source, f, index);
    break;
  case Field::CPPTYPE_UINT32:
    out->number.unsigned_integer = index < 0
                                       ? r->GetUInt32(source, f)
                                       : r->GetRepeatedUInt32(source, f, index);
    break;
  case Field::CPPTYPE_UINT64:
    out->number.unsigned_integer = index < 0
                                       ? r->GetUInt64(source, f)
                                       : r->GetRepeatedUInt64(source, f, index);
    break;
  case Field::CPPTYPE_FLOAT:
    out->number.real = index < 0 ? r->GetFloat(source, f)
                                 : r->GetRepeatedFloat(source, f, index);
    break;
  case Field::CPPTYPE_DOUBLE:
    out->number.real = index < 0 ? r->GetDouble(source, f)
                                 : r->GetRepeatedDouble(source, f, index);
    break;
  case Field::CPPTYPE_ENUM: {
    out->number.integer = index < 0 ? r->GetEnumValue(source, f)
                                    : r->GetRepeatedEnumValue(source, f, index);
    const auto &name = f->enum_type()->full_name();
    out->data = name.data();
    out->size = name.size();
    break;
  }
  case Field::CPPTYPE_STRING: {
    std::string scratch;
    const auto &text =
        index < 0 ? r->GetStringReference(source, f, &scratch)
                  : r->GetRepeatedStringReference(source, f, index, &scratch);
    if (text.size() > scope->byte_limit || text.size() > scope->remaining_bytes)
      return CEL_P_LIMIT;
    scope->remaining_bytes -= text.size();
    auto *copy = gpb::Arena::CreateArray<char>(&scope->arena, text.size());
    std::copy(text.begin(), text.end(), copy);
    out->data = copy;
    out->size = text.size();
    break;
  }
  case Field::CPPTYPE_MESSAGE:
    if (index < 0 &&
        (wrapper(f->message_type()) ||
         f->message_type()->full_name() == "google.protobuf.Any") &&
        !r->HasField(source, f)) {
      out->kind = CEL_P_NULL;
      return CEL_P_OK;
    }
    return adapt(scope,
                 index < 0 ? r->GetMessage(source, f)
                           : r->GetRepeatedMessage(source, f, index),
                 out, depth + 1);
  }
  return CEL_P_OK;
}

static int adapt(CelProtoScope *scope, const Message &source,
                 CelProtoValue *out, int depth) {
  if (depth > scope->depth_limit)
    return CEL_P_LIMIT;
  const auto *type = source.GetDescriptor();
  if (wrapper(type))
    return read(scope, source, type->FindFieldByName("value"), -1, out,
                depth + 1);
  const auto &name = type->full_name();
  if (name == "google.protobuf.Timestamp" ||
      name == "google.protobuf.Duration") {
    const auto *r = source.GetReflection();
    const auto seconds = r->GetInt64(source, type->FindFieldByName("seconds"));
    const auto nanos = r->GetInt32(source, type->FindFieldByName("nanos"));
    *out = {};
    if (name == "google.protobuf.Timestamp") {
      if (seconds < -62135596800LL || seconds > 253402300799LL || nanos < 0 ||
          nanos >= 1000000000)
        return CEL_P_OVERFLOW;
      out->kind = CEL_P_TIMESTAMP;
      out->number.integer = seconds;
      out->size = static_cast<size_t>(nanos);
    } else {
      if (nanos <= -1000000000 || nanos >= 1000000000 ||
          (seconds > 0 && nanos < 0) || (seconds < 0 && nanos > 0))
        return CEL_P_INVALID;
      const absl::int128 total = absl::int128(seconds) * 1000000000 + nanos;
      if (total < std::numeric_limits<int64_t>::min() ||
          total > std::numeric_limits<int64_t>::max())
        return CEL_P_OVERFLOW;
      out->kind = CEL_P_DURATION;
      out->number.integer = static_cast<int64_t>(total);
    }
    return CEL_P_OK;
  }
  if (name == "google.protobuf.Struct")
    return read(scope, source, type->FindFieldByName("fields"), -1, out,
                depth + 1);
  if (name == "google.protobuf.ListValue")
    return read(scope, source, type->FindFieldByName("values"), -1, out,
                depth + 1);
  if (name == "google.protobuf.Value") {
    const auto *active = source.GetReflection()->GetOneofFieldDescriptor(
        source, type->FindOneofByName("kind"));
    if (!active || active->name() == "null_value") {
      *out = {};
      out->kind = CEL_P_NULL;
      return CEL_P_OK;
    }
    return read(scope, source, active, -1, out, depth + 1);
  }
  if (name == "google.protobuf.Any") {
    const auto *r = source.GetReflection();
    const auto url = r->GetString(source, type->FindFieldByName("type_url"));
    if (url.empty())
      return CEL_P_INVALID;
    const auto split = url.rfind('/');
    if (split == std::string::npos)
      return CEL_P_INVALID;
    const auto payload_type = url.substr(split + 1);
    int status = CEL_P_OK;
    const auto *desc = cel_proto_descriptor(
        scope->registry, payload_type.data(), payload_type.size(), &status);
    if (status)
      return status;
    if (!desc)
      return CEL_P_UNKNOWN_TYPE;
    const auto bytes = r->GetString(source, type->FindFieldByName("value"));
    const auto *parsed = cel_proto_parse(
        scope, desc, reinterpret_cast<const uint8_t *>(bytes.data()),
        bytes.size(), &status);
    if (status)
      return status;
    return adapt(scope, *message(parsed), out, depth + 1);
  }
  *out = {};
  out->kind = CEL_P_MESSAGE;
  out->message = opaque(&source);
  return CEL_P_OK;
}

extern "C" int cel_proto_adapt(CelProtoScope *scope,
                               const CelProtoMessage *source,
                               CelProtoValue *out) {
  try {
    return adapt(scope, *message(source), out, 0);
  } catch (const std::bad_alloc &) {
    return CEL_P_OOM;
  }
}

extern "C" int cel_proto_get(CelProtoScope *scope, const CelProtoMessage *raw,
                             const CelProtoField *raw_field,
                             CelProtoValue *out) {
  try {
    const auto &source = *message(raw);
    const auto *f = field(raw_field);
    if (source.GetDescriptor() != f->containing_type())
      return CEL_P_TYPE;
    return read(scope, source, f, -1, out, 0);
  } catch (const std::bad_alloc &) {
    return CEL_P_OOM;
  }
}
extern "C" int cel_proto_has(const CelProtoMessage *raw,
                             const CelProtoField *raw_field, int *present) {
  try {
    const auto &source = *message(raw);
    const auto *f = field(raw_field);
    if (source.GetDescriptor() != f->containing_type())
      return CEL_P_TYPE;
    const auto *reflection = source.GetReflection();
    *present = f->is_repeated() ? reflection->FieldSize(source, f) > 0
                                : reflection->HasField(source, f);
    return CEL_P_OK;
  } catch (const std::bad_alloc &) {
    return CEL_P_OOM;
  }
}
static size_t addCost(size_t a, size_t b) {
  return b > std::numeric_limits<size_t>::max() - a
             ? std::numeric_limits<size_t>::max()
             : a + b;
}

static EqualityCost equalityCost(CelProtoScope *scope, const Message &source) {
  const auto cached = scope->equality_costs.find(&source);
  if (cached != scope->equality_costs.end())
    return cached->second;

  EqualityCost cost{source.ByteSizeLong(),
                    static_cast<size_t>(source.GetDescriptor()->field_count()) +
                        1};
  const auto *reflection = source.GetReflection();
  std::vector<const Field *> fields;
  reflection->ListFields(source, &fields);
  for (const auto *f : fields) {
    if (f->cpp_type() != Field::CPPTYPE_MESSAGE)
      continue;
    const int count = f->is_repeated() ? reflection->FieldSize(source, f) : 1;
    for (int i = 0; i < count; ++i) {
      const auto &nested = f->is_repeated()
                               ? reflection->GetRepeatedMessage(source, f, i)
                               : reflection->GetMessage(source, f);
      cost.fields = addCost(cost.fields, equalityCost(scope, nested).fields);
    }
  }
  scope->equality_costs.emplace(&source, cost);
  return cost;
}

extern "C" int cel_proto_equal(CelProtoScope *scope, const CelProtoMessage *a,
                               const CelProtoMessage *b, size_t *remaining,
                               int *equal) {
  try {
    if (*remaining == 0)
      return CEL_P_COST;
    const auto a_cost = equalityCost(scope, *message(a));
    const auto b_cost = equalityCost(scope, *message(b));
    const size_t cost = std::max(addCost(a_cost.bytes, a_cost.fields),
                                 addCost(b_cost.bytes, b_cost.fields));
    if (cost > *remaining)
      return CEL_P_COST;
    *remaining -= cost;
    *equal = gpb::util::MessageDifferencer::Equals(*message(a), *message(b));
    return CEL_P_OK;
  } catch (const std::bad_alloc &) {
    return CEL_P_OOM;
  }
}
extern "C" const CelProtoDescriptor *
cel_proto_message_descriptor(const CelProtoMessage *raw) {
  return reinterpret_cast<const CelProtoDescriptor *>(
      message(raw)->GetDescriptor());
}
extern "C" const uint8_t *cel_proto_serialize(CelProtoScope *scope,
                                              const CelProtoMessage *raw,
                                              size_t *size, int *status) {
  try {
    const auto &source = *message(raw);
    *size = source.ByteSizeLong();
    if (*size > scope->byte_limit || *size > scope->remaining_bytes ||
        *size > static_cast<size_t>(std::numeric_limits<int>::max())) {
      *status = CEL_P_LIMIT;
      return nullptr;
    }
    scope->remaining_bytes -= *size;
    auto *data = gpb::Arena::CreateArray<uint8_t>(&scope->arena, *size);
    if (!source.SerializePartialToArray(data, static_cast<int>(*size))) {
      *status = CEL_P_INVALID;
      return nullptr;
    }
    *status = CEL_P_OK;
    return data;
  } catch (const std::bad_alloc &) {
    *status = CEL_P_OOM;
    return nullptr;
  }
}
