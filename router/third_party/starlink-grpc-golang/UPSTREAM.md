# Vendored Starlink protobufs

Generated Go protobuf sources in `pkg/` were copied from
`github.com/clarkzjw/starlink-grpc-golang` commit
`e8e6c29e4bf0b0f175ef0386550e11372c5791e6` (dish release
`2026.07.06.mr81950`). The local module pins Go 1.22-compatible runtime
dependencies while preserving the upstream import paths embedded by protoc.
