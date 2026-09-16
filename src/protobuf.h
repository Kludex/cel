#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CelProtoRegistry CelProtoRegistry;
typedef struct CelProtoScope CelProtoScope;
typedef struct CelProtoDescriptor CelProtoDescriptor;
typedef struct CelProtoField CelProtoField;
typedef struct CelProtoMessage CelProtoMessage;

enum CelProtoKind {
  CEL_P_NULL,
  CEL_P_BOOL,
  CEL_P_INT,
  CEL_P_UINT,
  CEL_P_DOUBLE,
  CEL_P_STRING,
  CEL_P_BYTES,
  CEL_P_LIST,
  CEL_P_MAP,
  CEL_P_MESSAGE,
  CEL_P_TIMESTAMP,
  CEL_P_DURATION,
  CEL_P_ENUM
};
enum CelProtoStatus {
  CEL_P_OK,
  CEL_P_UNKNOWN_TYPE,
  CEL_P_INVALID,
  CEL_P_FIELD,
  CEL_P_TYPE,
  CEL_P_OVERFLOW,
  CEL_P_OOM,
  CEL_P_LIMIT,
  CEL_P_COST
};

typedef struct CelProtoValue {
  int kind;
  union {
    int64_t integer;
    uint64_t unsigned_integer;
    double real;
  } number;
  const char *data;
  size_t size;
  const struct CelProtoValue *items;
  size_t count;
  const CelProtoMessage *message;
} CelProtoValue;

CelProtoRegistry *cel_proto_registry(const uint8_t *, size_t, size_t, int,
                                     int *);
void cel_proto_retain(CelProtoRegistry *);
void cel_proto_release(CelProtoRegistry *);
const CelProtoDescriptor *cel_proto_descriptor(CelProtoRegistry *, const char *,
                                               size_t, int *);
const char *cel_proto_enum_type(CelProtoRegistry *, const char *, size_t,
                                size_t *, int *);
const char *cel_proto_enum(CelProtoRegistry *, const char *, size_t, int32_t *,
                           size_t *, int *);
const char *cel_proto_enum_symbol(CelProtoRegistry *, const char *, size_t,
                                  const char *, size_t, int32_t *, size_t *,
                                  int *);
const char *cel_proto_name(const CelProtoDescriptor *, size_t *);
const CelProtoField *cel_proto_field(const CelProtoDescriptor *, const char *,
                                     size_t, int *);
int cel_proto_field_kind(const CelProtoField *);
int cel_proto_repeated(const CelProtoField *);
int cel_proto_map(const CelProtoField *);
const CelProtoDescriptor *cel_proto_field_message(const CelProtoField *);
const char *cel_proto_field_enum(const CelProtoField *, size_t *);
const CelProtoField *cel_proto_map_key(const CelProtoField *);
const CelProtoField *cel_proto_map_value(const CelProtoField *);

CelProtoScope *cel_proto_scope(CelProtoRegistry *, size_t, size_t, int, size_t,
                               int, int *);
void cel_proto_scope_free(CelProtoScope *);
const CelProtoMessage *cel_proto_parse(CelProtoScope *,
                                       const CelProtoDescriptor *,
                                       const uint8_t *, size_t, int *);
const CelProtoMessage *cel_proto_construct(CelProtoScope *,
                                           const CelProtoDescriptor *,
                                           const CelProtoField *const *,
                                           const CelProtoValue *, size_t,
                                           int *);
int cel_proto_adapt(CelProtoScope *, const CelProtoMessage *, CelProtoValue *);
int cel_proto_get(CelProtoScope *, const CelProtoMessage *,
                  const CelProtoField *, CelProtoValue *);
int cel_proto_has(const CelProtoMessage *, const CelProtoField *, int *);
int cel_proto_equal(CelProtoScope *, const CelProtoMessage *,
                    const CelProtoMessage *, size_t *, int *);
const CelProtoDescriptor *cel_proto_message_descriptor(const CelProtoMessage *);
const uint8_t *cel_proto_serialize(CelProtoScope *, const CelProtoMessage *,
                                   size_t *, int *);

#ifdef __cplusplus
}
#endif
