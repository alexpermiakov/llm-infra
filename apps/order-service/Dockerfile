FROM golang:1.24-bookworm AS builder

ARG VERSION=dev

WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w -X 'main.version=${VERSION}'" -o main .

FROM gcr.io/distroless/static-debian12:latest

COPY --from=builder /app/main /main
USER nonroot:nonroot
EXPOSE 8080

ENTRYPOINT ["/main"]
