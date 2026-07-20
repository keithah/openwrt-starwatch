module starwatch

go 1.25.0

require (
	github.com/clarkzjw/starlink-grpc-golang v0.0.0
	github.com/coder/websocket v1.8.13
	golang.org/x/net v0.55.0
	google.golang.org/grpc v1.79.3
	google.golang.org/protobuf v1.36.10
	modernc.org/sqlite v1.34.5
)

require (
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/ncruces/go-strftime v0.1.9 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	golang.org/x/sys v0.45.0 // indirect
	golang.org/x/text v0.37.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251202230838-ff82c1b0f217 // indirect
	modernc.org/libc v1.55.3 // indirect
	modernc.org/mathutil v1.6.0 // indirect
	modernc.org/memory v1.8.0 // indirect
)

replace github.com/clarkzjw/starlink-grpc-golang => ./third_party/starlink-grpc-golang
