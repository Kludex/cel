//! Descriptor fixtures for public SDK integration tests; no runtime library dependency.

/// Original proto3 schema with scalar, collection, presence, and oneof fields.
pub const schema = @embedFile("protobuf/test-schema-descriptor.pb");
/// Pinned upstream proto2/proto3 conformance message descriptors.
pub const upstream = @embedFile("protobuf/cel-spec-test-descriptors.pb");
